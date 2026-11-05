import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    @Published var archive = LocalArchive()
    @Published var status = "本地模型尚未接入"
    @Published var storageError: String?
    @Published var selectedTab = 0
    @Published var showChat = false
    @Published var importingModel = false
    private var canWrite = true

    init() {
        do {
            if let saved = try LocalFiles.load() {
                archive = saved
            } else if let url = Bundle.main.url(forResource: "seed_memories", withExtension: "json") {
                archive.memories = try JSONDecoder().decode([MemoryItem].self, from: Data(contentsOf: url))
                save()
            }
        } catch {
            // 读取失败时禁止覆盖旧档案，先保留原始数据用于恢复。
            canWrite = false
            storageError = "读取本机档案失败，已停止写入以保护原文件：\(error.localizedDescription)"
        }
        let bridge = NotificationBridge.shared
        bridge.onOpen = { [weak self] in
            self?.deliverDueMessages()
            self?.selectedTab = 0
            self?.showChat = true
        }
        if bridge.pendingOpen {
            bridge.pendingOpen = false
            bridge.onOpen?()
        }
        bridge.onForeground = { [weak self] in self?.deliverDueMessages() }
        UNUserNotificationCenter.current().delegate = bridge
    }

    @discardableResult
    func save() -> Bool {
        guard canWrite else { return false }
        do { try LocalFiles.save(archive); storageError = nil; return true }
        catch { storageError = "保存失败：\(error.localizedDescription)"; return false }
    }

    func send(_ text: String, kind: String = "text") {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, canWrite else { return }
        deliverDueMessages()
        let previous = archive
        let obsolete = archive.scheduledMessages.map { $0.id.uuidString }
        // 新消息让旧候选内容可能过时，撤销旧通知，等待模型根据新上下文重新生成。
        archive.scheduledMessages = []
        archive.messages.append(ChatMessage(role: "me", content: value, kind: kind))
        guard save() else { archive = previous; return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: obsolete)
        // 不用固定套话冒充模型；待真机评估后接入本地推理引擎。
        status = "消息已保存在手机；本地推理引擎尚未接入，暂不能生成回复"
    }

    func addMemory(category: String, content: String, importance: Int) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canWrite else { return }
        guard !archive.memories.contains(where: { $0.content == text }) else { return }
        archive.memories.append(MemoryItem(category: category, content: text, importance: importance))
        save()
    }

    func exportArchive() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xiaopihai-backup.json")
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
        return url
    }

    func enableNotifications() async {
        do {
            let enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            archive.settings.notifications = enabled
            save()
            status = enabled ? "通知权限已开启；尚未生成主动消息计划" : "通知未获允许"
            if enabled { await syncNotifications() }
        } catch { status = "通知设置失败：\(error.localizedDescription)" }
    }

    func activate() {
        deliverDueMessages()
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            await syncNotifications()
        }
    }

    func pauseNotifications() {
        let previous = archive
        let ids = archive.scheduledMessages.map { $0.id.uuidString }
        archive.settings.notifications = false
        archive.scheduledMessages = []
        guard save() else { archive = previous; return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        status = "主动消息已暂停"
    }

    func deliverDueMessages(now: Date = Date()) {
        guard canWrite else { return }
        let due = archive.scheduledMessages.filter { $0.fireAt <= now }.sorted { $0.fireAt < $1.fireAt }
        guard !due.isEmpty else { return }
        let previous = archive
        var seen = Set(archive.messages.map(\.id))
        for item in due where seen.insert(item.id).inserted {
            archive.messages.append(ChatMessage(id: item.id, role: "her", content: item.content, createdAt: item.fireAt))
        }
        archive.messages.sort { $0.createdAt < $1.createdAt }
        let dueIDs = Set(due.map(\.id))
        archive.scheduledMessages.removeAll { dueIDs.contains($0.id) }
        if !save() { archive = previous }
    }

    func queuePreparedReplies(_ texts: [String]) async {
        guard canWrite, archive.settings.notifications else { return }
        let plan = ProactivePlanner.plan(texts: texts)
        guard !plan.isEmpty else { return }
        let previous = archive
        let oldIDs = archive.scheduledMessages.map { $0.id.uuidString }
        archive.scheduledMessages = plan
        guard save() else { archive = previous; return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: oldIDs)
        await syncNotifications()
    }

    private func syncNotifications() async {
        guard canWrite, archive.settings.notifications else { return }
        let center = UNUserNotificationCenter.current()
        let permission = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(permission.authorizationStatus) else { return }
        for item in archive.scheduledMessages {
            guard let request = ProactivePlanner.notification(for: item) else { continue }
            do {
                try await center.add(request)
                // add等待期间用户可能已发新消息，清除这次竞争产生的过期通知。
                if !archive.scheduledMessages.contains(where: { $0.id == item.id }) {
                    center.removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
                }
            }
            catch { status = "消息计划已保存在本机，但通知安排失败：\(error.localizedDescription)" }
        }
    }

    func importModel(from source: URL) async {
        guard canWrite, !importingModel, archive.model == nil else { return }
        importingModel = true
        defer { importingModel = false }
        do {
            let imported = try await Task.detached(priority: .utility) {
                try ModelStorage.importModel(from: source)
            }.value
            archive.model = imported
            if save() { status = "模型文件已导入；推理引擎尚未接入，格式检查不保证可运行" }
        } catch { status = "导入失败：\(error.localizedDescription)" }
    }
}
