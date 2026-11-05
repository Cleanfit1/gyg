import Foundation
import CryptoKit

enum ModelStorage {
    // 用户仅剩10GB存储，先以单模型3GB、总占用7GB和至少3GB余量为保护边界。
    static let maximumModelBytes: Int64 = 3_000_000_000
    static let maximumAppDataBytes: Int64 = 7_000_000_000
    static let reservedFreeBytes: Int64 = 3_000_000_000
    static let expectedModelBytes: Int64 = 2_104_932_768
    static let expectedSHA256 = "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d"

    static func directory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resource = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
        return directory
    }

    static func managedBytes() throws -> Int64 {
        let base = try LocalFiles.archiveURL().deletingLastPathComponent()
        guard let files = FileManager.default.enumerator(at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }

    static func importModel(from source: URL) throws -> ModelRecord {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, source.pathExtension.lowercased() == "gguf" else {
            throw StorageError.invalidFile
        }
        let size = Int64(values.fileSize ?? 0)
        guard size >= 24, size <= maximumModelBytes else { throw StorageError.tooLarge }
        guard size == expectedModelBytes else { throw StorageError.wrongModel }
        let input = try FileHandle(forReadingFrom: source)
        let header = try input.read(upToCount: 8) ?? Data()
        try input.close()
        guard header.count == 8, Array(header.prefix(4)) == [0x47, 0x47, 0x55, 0x46],
              [UInt8(2), UInt8(3)].contains(header[4]), header[5...7].allSatisfy({ $0 == 0 }) else {
            throw StorageError.invalidFile
        }
        let root = try directory()
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = capacity.volumeAvailableCapacityForImportantUsage,
              free - size >= reservedFreeBytes else { throw StorageError.noSpace }
        guard try managedBytes() + size <= maximumAppDataBytes else { throw StorageError.budget }
        let destination = root.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let copied = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard Int64(copied ?? 0) == size else { throw StorageError.incomplete }
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { hasher.update(data: block) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expectedSHA256 else { throw StorageError.wrongModel }
            return ModelRecord(filename: destination.lastPathComponent, displayName: source.lastPathComponent, bytes: size)
        } catch {
            // 只清理本次新建且失败的拷贝，不删除原模型或用户选择的源文件。
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    enum StorageError: LocalizedError {
        case invalidFile, tooLarge, noSpace, budget, incomplete, wrongModel
        var errorDescription: String? {
            switch self {
            case .wrongModel: return "请选择完整的官方Qwen2.5-3B-Instruct Q4_K_M模型，大小约2.10GB；校验不符不会导入"
            case .invalidFile: return "请选择有效的GGUF v2/v3模型文件；格式检查不等于模型兼容性验证"
            case .tooLarge: return "初期只接受3GB以内模型，优先测试1～2GB量化模型"
            case .noSpace: return "导入后必须保留至少3GB系统空间；无法确认余量时也会停止导入"
            case .budget: return "导入会超过7GB应用数据预算；不会自动删除已有模型"
            case .incomplete: return "模型复制不完整，已保留原文件"
            }
        }
    }
}
