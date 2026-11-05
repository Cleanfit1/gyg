import Foundation

/// 手机本地的 llama.cpp 推理入口。模型文件由用户导入，运行时不联网。
actor LocalInference {
    static let shared = LocalInference()
    private var context: LlamaContext?
    private var loadedFilename: String?

    func reply(archive: LocalArchive) async throws -> String {
        guard let model = archive.model else { throw InferenceError.modelMissing }
        let modelURL = try ModelStorage.directory().appendingPathComponent(model.filename)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw InferenceError.modelMissing }
        if context == nil || loadedFilename != model.filename {
            context = try LlamaContext.create_context(path: modelURL.path)
            loadedFilename = model.filename
        }
        guard let context else { throw InferenceError.loadFailed }
        let prompt = PromptBuilder.make(archive: archive)
        return await context.generate(prompt: prompt, maxTokens: 160)
    }

    enum InferenceError: LocalizedError {
        case modelMissing, loadFailed, empty
        var errorDescription: String? {
            switch self {
            case .modelMissing: return "请先在电脑导入Qwen2.5-3B Q4模型，再同步到手机"
            case .loadFailed: return "本地模型加载失败，模型文件可能不兼容"
            case .empty: return "本地模型没有生成有效回复"
            }
        }
    }
}

enum PromptBuilder {
    static func make(archive: LocalArchive) -> String {
        let memories = archive.memories.sorted { $0.importance > $1.importance }.prefix(24)
            .map { "- [\($0.category)] \($0.content)" }.joined(separator: "\n")
        let recent = archive.messages.suffix(12).map { message in
            let who = message.role == "me" ? archive.owner.name : archive.character.name
            return "\(who)：\(message.content.isEmpty ? "[语音]" : message.content)"
        }.joined(separator: "\n")
        return """
        你正在手机本地离线扮演“\(archive.character.name)”，只和\(archive.owner.name)聊天。
        人物资料：\(archive.character.name)，地区\(archive.character.region)，签名：\(archive.character.signature)。
        说话要求：像真实微信聊天，短句、自然口语、偶尔分成两三条；根据上下文表达情绪，不要解释自己是模型，不要编造没有依据的事实。她爱吃麻辣烫，常用“嗯呢”“我去”“好好好”等口头语，但不要每句都重复。
        已知记忆：
        \(memories)
        最近对话：
        \(recent)
        请只输出下一条要发给对方的中文消息，不要加姓名、引号或分析：
        """
    }
}
