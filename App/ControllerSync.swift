import Foundation
import UIKit

struct ControllerConfig: Codable {
    var schemaVersion: Int = 1
    var revision: UUID = UUID()
    var memories: [MemoryItem]
    var deletedMemoryIDs: [UUID]
    var owner: UserProfile
    var character: UserProfile
    var settings: CharacterSettings

    func applying(to current: LocalArchive) throws -> LocalArchive {
        guard schemaVersion == 1, memories.count <= 10000,
              Set(memories.map(\.id)).count == memories.count,
              Set(memories.map(\.id)).isDisjoint(with: Set(deletedMemoryIDs)) else {
            throw SyncError.invalid
        }
        for profile in [owner, character] {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.name.count <= 60, profile.account.count <= 80,
                  profile.region.count <= 120, profile.signature.count <= 300 else { throw SyncError.invalid }
            if let data = profile.avatar {
                guard data.count <= 2_000_000, let image = UIImage(data: data),
                      image.size.width <= 4096, image.size.height <= 4096 else { throw SyncError.invalid }
            }
        }
        guard (0...1).contains(settings.proactivity), (0...1).contains(settings.intimacy),
              (0...1).contains(settings.emotionalVariation) else { throw SyncError.invalid }
        for item in memories {
            guard !item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.content.count <= 2000, (1...5).contains(item.importance),
                  ["事实", "关系", "习惯", "计划", "事件", "设定"].contains(item.category) else { throw SyncError.invalid }
        }
        var result = current
        let deleted = Set(deletedMemoryIDs)
        result.memories.removeAll { deleted.contains($0.id) }
        for incoming in memories {
            if let index = result.memories.firstIndex(where: { $0.id == incoming.id }) {
                // 手机新增/更新的记忆优先保留，防止旧电脑快照覆盖后续学习。
                if incoming.updatedAt >= result.memories[index].updatedAt { result.memories[index] = incoming }
            } else { result.memories.append(incoming) }
        }
        result.owner = owner
        result.character = character
        result.settings = settings
        result.controllerRevision = revision
        return result
    }

    enum SyncError: LocalizedError {
        case invalid
        var errorDescription: String? { "电脑配置校验失败，已保留手机原有数据" }
    }
}

enum ControllerSync {
    static func documents() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
    static func readConfig() throws -> ControllerConfig? {
        let url = try documents().appendingPathComponent("controller-config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 12_000_000 else { throw ControllerConfig.SyncError.invalid }
        return try JSONDecoder().decode(ControllerConfig.self, from: Data(contentsOf: url))
    }
    static func writeSnapshot(_ archive: LocalArchive, error: String?) throws {
        let root = try documents()
        try JSONEncoder().encode(archive).write(to: root.appendingPathComponent("phone-state.json"), options: .atomic)
        try (error ?? "同步正常").write(to: root.appendingPathComponent("sync-status.txt"), atomically: true, encoding: .utf8)
    }
}

enum VoiceFiles {
    static func directory() throws -> URL {
        let root = try LocalFiles.archiveURL().deletingLastPathComponent().appendingPathComponent("Voice", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func url(for filename: String) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".m4a"), !filename.contains(".."), !filename.contains("\\") else {
            throw ControllerConfig.SyncError.invalid
        }
        return try directory().appendingPathComponent(filename)
    }
}
