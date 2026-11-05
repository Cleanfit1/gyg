import Foundation
import llama

// 每次生成独立上下文，结束即释放显存，后台不常驻大模型。
actor LlamaContext {
    enum Failure: LocalizedError {
        case load, context, tokenize, length, decode
        var errorDescription: String? {
            switch self {
            case .load: return "模型加载失败，请确认文件完整且为Qwen2.5 GGUF"
            case .context: return "手机可用内存不足，无法创建推理上下文"
            case .tokenize: return "模型分词失败"
            case .length: return "本次消息过长，请分成几条发送"
            case .decode: return "本机推理失败，请稍后重试"
            }
        }
    }
    static let shared = LlamaContext()
    private var initialized = false

    func generate(path: String, prompt: String, maxTokens: Int = 160) throws -> String {
        if !initialized { llama_backend_init(); initialized = true }
        try Task.checkCancellation()
        var mp = llama_model_default_params()
        #if targetEnvironment(simulator)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = 99
        #endif
        guard let model = llama_model_load_from_file(path, mp) else { throw Failure.load }
        defer { llama_model_free(model) }
        guard let vocab = llama_model_get_vocab(model) else { throw Failure.tokenize }
        let needed = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), nil, 0, false, true)
        guard needed < 0 else { throw Failure.tokenize }
        var tokens = [llama_token](repeating: 0, count: Int(-needed))
        let count = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), false, true)
        guard count > 0 else { throw Failure.tokenize }
        guard Int(count) + maxTokens <= 2048 else { throw Failure.length }
        var cp = llama_context_default_params()
        cp.n_ctx = 2048
        cp.n_batch = 128
        cp.n_ubatch = 128
        cp.n_threads = 4
        cp.n_threads_batch = 4
        guard let context = llama_init_from_model(model, cp) else { throw Failure.context }
        defer { llama_free(context) }
        var batch = llama_batch_init(128, 0, 1)
        defer { llama_batch_free(batch) }
        func evaluate(_ values: ArraySlice<llama_token>, at position: Int) throws {
            batch.n_tokens = Int32(values.count)
            for (i, token) in values.enumerated() {
                batch.token[i] = token
                batch.pos[i] = Int32(position + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = i == values.count - 1 ? 1 : 0
            }
            guard llama_decode(context, batch) == 0 else { throw Failure.decode }
        }
        let start = Date()
        for offset in stride(from: 0, to: Int(count), by: 128) {
            try Task.checkCancellation()
            try evaluate(tokens[offset..<min(offset + 128, Int(count))], at: offset)
            if Date().timeIntervalSince(start) > 120 { throw Failure.decode }
        }
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw Failure.context }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.75))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        var bytes = [UInt8]()
        for index in 0..<maxTokens {
            try Task.checkCancellation()
            if Date().timeIntervalSince(start) > 120 { throw Failure.decode }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var piece = [CChar](repeating: 0, count: 128)
            var length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length < 0 {
                piece = [CChar](repeating: 0, count: Int(-length))
                length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            }
            guard length >= 0 else { throw Failure.decode }
            bytes.append(contentsOf: piece.prefix(Int(length)).map { UInt8(bitPattern: $0) })
            try evaluate([token][...], at: Int(count) + index)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
