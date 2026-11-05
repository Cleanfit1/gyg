import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    @Published var archive = LocalArchive()
    @Published var status = "尚未安装离线模型"
    @Published var storageError: String?
    @Published var selectedTab = 0
    @Published var showChat = false
    @Published var importingModel = false
    private var canWrite = true
    private var syncingController = false

    init() {
        do {
            if let saved = try LocalFiles.load() {
                archive = saved
                if archive.model != nil { status = "已安装离线模型" }
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
        do {
            try LocalFiles.save(archive)
            storageError = nil
            try? ControllerSync.writeSnapshot(archive, error: nil)
            return true
        }
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
        requestReply()
    }

    func setInferenceError(_ message: String) {
        inferenceError = message
    }

    @Published var generating = false
    @Published var inferenceError: String?
    private var replyTask: Task<Void, Never>?
    private var replyRevision = UUID()

    func cancelReply() {
        replyRevision = UUID()
        replyTask?.cancel()
        replyTask = nil
        generating = false
    }

    func requestReply() {
        cancelReply()
        guard canWrite else { return }
        inferenceError = nil
        guard archive.model != nil else {
            inferenceError = "请先在设置中完成离线模型安装"
            return
        }
        let revision = replyRevision
        let snapshot = archive
        generating = true
        replyTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.replyRevision == revision { self.generating = false } }
            do {
                let reply = try await LocalInference.shared.reply(archive: snapshot)
                try Task.checkCancellation()
                guard self.replyRevision == revision else { return }
                guard !reply.isEmpty else { throw LocalInference.InferenceError.empty }
                let previous = self.archive
                self.archive.messages.append(ChatMessage(role: "her", content: reply))
                if !self.save() { self.archive = previous }
            } catch is CancellationError {
                // 新消息或切到后台取消推理，不把旧回复追加到新对话。
            } catch {
                if self.replyRevision == revision {
                    self.inferenceError = error.localizedDescription
                    try? ControllerSync.writeSnapshot(self.archive, error: error.localizedDescription)
                }
            }
        }
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
        importControllerConfig()
        deliverDueMessages()
        try? ControllerSync.writeSnapshot(archive, error: storageError)
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            await syncController()
            await syncNotifications()
        }
    }

    func pairController(_ url: URL) {
        guard let pairing = LocalController.parse(url) else { return }
        Task {
            do {
                // 先验证访问令牌，再替换原配对，避免错误链接破坏现有连接。
                _ = try await pairing.request("/health")
                try pairing.save()
                await syncController()
            } catch { status = "电脑配对失败：\(error.localizedDescription)" }
        }
    }

    func syncController() async {
        guard canWrite, !syncingController else { return }
        syncingController = true
        defer { syncingController = false }
        do {
            guard let controller = try LocalController.load() else { return }
            _ = try await controller.request("/state", body: JSONEncoder().encode(archive))
            let data = try await controller.request("/config")
            let config = try JSONDecoder().decode(ControllerConfig.self, from: data)
            if config.revision != archive.controllerRevision {
                cancelReply()
                let previous = archive
                let obsolete = archive.scheduledMessages.map { $0.id.uuidString }
                archive = try config.applying(to: archive)
                if !archive.settings.notifications { archive.scheduledMessages = [] }
                guard save() else { archive = previous; return }
                if !archive.settings.notifications {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: obsolete)
                }
            }
            _ = try await controller.request("/state", body: JSONEncoder().encode(archive))
        } catch {
            // 电脑不在线不打断聊天，诊断仅写电脑同步快照。
            status = "局域网控制端未同步：\(error.localizedDescription)"
            try? ControllerSync.writeSnapshot(archive, error: status)
        }
    }

    private func importControllerConfig() {
        guard canWrite else { return }
        do {
            guard let config = try ControllerSync.readConfig(), config.revision != archive.controllerRevision else { return }
            cancelReply()
            let previous = archive
            let obsolete = archive.scheduledMessages.map { $0.id.uuidString }
            archive = try config.applying(to: archive)
            if !archive.settings.notifications { archive.scheduledMessages = [] }
            guard save() else { archive = previous; return }
            if !archive.settings.notifications {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: obsolete)
            }
        } catch {
            storageError = error.localizedDescription
            try? ControllerSync.writeSnapshot(archive, error: storageError)
        }
    }

    func sendVoiceFile(_ source: URL, seconds: Double) throws -> UUID {
        guard canWrite else { throw ControllerConfig.SyncError.invalid }
        cancelReply()
        let filename = UUID().uuidString + ".m4a"
        let destination = try VoiceFiles.url(for: filename)
        try FileManager.default.copyItem(at: source, to: destination)
        let previous = archive
        let obsolete = archive.scheduledMessages.map { $0.id.uuidString }
        archive.scheduledMessages = []
        let message = ChatMessage(role: "me", content: "", kind: "voice", audioFilename: filename,
                                  audioDuration: seconds, transcriptionState: "pending")
        archive.messages.append(message)
        guard save() else {
            archive = previous
            try? FileManager.default.removeItem(at: destination)
            throw ControllerConfig.SyncError.invalid
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: obsolete)
        return message.id
    }

    func updateTranscript(id: UUID, text: String?, failure: String? = nil) {
        guard let index = archive.messages.firstIndex(where: { $0.id == id }), canWrite else { return }
        cancelReply()
        archive.messages[index].content = text ?? ""
        archive.messages[index].transcriptionState = text == nil ? "failed" : "done"
        if let failure { status = failure }
        if save(), let text, !text.isEmpty { requestReply() }
    }

    func updateOwner(_ profile: UserProfile) {
        let previous = archive.owner
        archive.owner = profile
        if !save() { archive.owner = previous }
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
        status = "正在复制并校验离线模型，请保持应用在前台"
        defer { importingModel = false }
        do {
            let imported = try await Task.detached(priority: .utility) {
                try ModelStorage.importModel(from: source)
            }.value
            let previous = archive.model
            archive.model = imported
            if save() { status = "离线模型已安装，可以返回聊天测试回复" }
            else { archive.model = previous; status = "模型记录保存失败，请检查存储空间" }
        } catch { status = "导入失败：\(error.localizedDescription)" }
    }
}
