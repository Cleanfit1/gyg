import Foundation

struct MemoryItem: Codable, Identifiable {
    var id: UUID = UUID()
    var category: String
    var content: String
    var importance: Int = 3
    var source: String = "用户补充"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct ChatMessage: Codable, Identifiable {
    var id: UUID = UUID()
    var role: String
    var content: String
    var kind: String = "text"
    var createdAt: Date = Date()
}

struct CharacterSettings: Codable {
    var relationship: String = "分手后"
    var proactivity: Double = 0.55
    var emotionalVariation: Double = 0.55
    var intimacy: Double = 0.35
    var notifications: Bool = false
}

struct ScheduledMessage: Codable, Identifiable {
    var id: UUID = UUID()
    var content: String
    var fireAt: Date
    var preparedAt: Date = Date()
}

struct ModelRecord: Codable {
    var filename: String
    var displayName: String
    var bytes: Int64
    var importedAt: Date = Date()
}

struct LocalArchive: Codable {
    var schemaVersion: Int = 2
    var memories: [MemoryItem] = []
    var messages: [ChatMessage] = []
    var settings: CharacterSettings = CharacterSettings()
    var scheduledMessages: [ScheduledMessage] = []
    var model: ModelRecord?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, memories, messages, settings, scheduledMessages, model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "档案版本高于此应用支持的版本")
        }
        memories = try container.decode([MemoryItem].self, forKey: .memories)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        settings = try container.decode(CharacterSettings.self, forKey: .settings)
        scheduledMessages = try container.decodeIfPresent([ScheduledMessage].self, forKey: .scheduledMessages) ?? []
        model = try container.decodeIfPresent(ModelRecord.self, forKey: .model)
        schemaVersion = 2
    }
}

enum LocalFiles {
    static func archiveURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return directory.appendingPathComponent("archive.json")
    }

    static func save(_ archive: LocalArchive) throws {
        let data = try JSONEncoder().encode(archive)
        try data.write(to: archiveURL(), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func load() throws -> LocalArchive? {
        let url = try archiveURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(LocalArchive.self, from: Data(contentsOf: url))
    }
}
