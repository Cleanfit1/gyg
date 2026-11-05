import Foundation

struct LocalController: Codable {
    let host: String
    let port: Int
    let token: String

    static func parse(_ url: URL) -> LocalController? {
        guard url.scheme == "xiaopihai", url.host == "pair",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard let host = value("host"), isPrivateIPv4(host), let rawPort = value("port"),
              let port = Int(rawPort), (1024...65535).contains(port),
              let token = value("token"), token.count == 64,
              token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return LocalController(host: host, port: port, token: token)
    }

    static func isPrivateIPv4(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }),
              zip(pieces, numbers).allSatisfy({ String($0.1) == String($0.0) }) else { return false }
        return numbers[0] == 10 || (numbers[0] == 192 && numbers[1] == 168) ||
            (numbers[0] == 172 && (16...31).contains(numbers[1]))
    }

    static func file() throws -> URL {
        try LocalFiles.archiveURL().deletingLastPathComponent().appendingPathComponent("controller-pairing.json")
    }
    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.file(), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    static func load() throws -> LocalController? {
        let file = try file()
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func request(_ path: String, body: Data? = nil) async throws -> Data {
        guard Self.isPrivateIPv4(host), (1024...65535).contains(port) else { throw ControllerConfig.SyncError.invalid }
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = port; components.path = path
        guard let url = components.url else { throw ControllerConfig.SyncError.invalid }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 控制端仅直连局域网，不经系统HTTP代理转发私人资料。
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 12_000_000 else {
            throw ControllerConfig.SyncError.invalid
        }
        return data
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
