import Foundation
import UserNotifications

enum ProactivePlanner {
    // 只给已有候选内容排时间，不拿固定模板冒充模型生成。
    static func plan(texts: [String], now: Date = Date()) -> [ScheduledMessage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var seen = Set<String>()
        let candidates = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 120 && seen.insert($0).inserted }.prefix(3)
        var slots: [Date] = []
        // 未来24小时内在9点至21点半选时间，至少留出30分钟准备窗口。
        for offset in stride(from: 30, through: 24 * 60, by: 30) {
            guard let date = calendar.date(byAdding: .minute, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if (9 * 60 ... 21 * 60 + 30).contains(minute) { slots.append(date) }
        }
        slots.shuffle()
        var chosen: [Date] = []
        for slot in slots where chosen.count < candidates.count {
            if chosen.allSatisfy({ abs($0.timeIntervalSince(slot)) >= 90 * 60 }) { chosen.append(slot) }
        }
        return zip(candidates, chosen.sorted()).map { ScheduledMessage(content: $0.0, fireAt: $0.1, preparedAt: now) }
    }

    static func notification(for item: ScheduledMessage, now: Date = Date()) -> UNNotificationRequest? {
        guard item.fireAt > now else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "小屁孩"
        content.body = item.content
        content.sound = .default
        content.badge = 1
        content.userInfo = ["messageID": item.id.uuidString]
        return UNNotificationRequest(identifier: item.id.uuidString, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, item.fireAt.timeIntervalSince(now)), repeats: false))
    }
}

@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()
    var onOpen: (() -> Void)?
    var onForeground: (() -> Void)?
    var pendingOpen = false

    func handleOpen() {
        if let onOpen { onOpen() } else { pendingOpen = true }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in NotificationBridge.shared.handleOpen() }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in NotificationBridge.shared.onForeground?() }
        // 前台直接更新聊天，不额外弹横幅打断当前操作。
        completionHandler([])
    }
}
