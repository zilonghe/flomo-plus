import Foundation

struct ServerConfiguration: Sendable {
    let origin: String
    let token: String

    init(address: String, token: String) throws {
        guard var url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["", "/"].contains(url.path) else {
            throw WeijiAPIError(status: 0, message: "请输入完整的 HTTP 或 HTTPS 服务地址。")
        }
        url.scheme = scheme
        url.host = host
        if (scheme == "http" && url.port == 80) || (scheme == "https" && url.port == 443) { url.port = nil }
        url.path = ""
        guard let origin = url.url?.absoluteString, !origin.isEmpty else { throw WeijiAPIError.interrupted }
        self.origin = origin
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WeijiAPIError: LocalizedError {
    let status: Int
    let message: String
    var body: Data? = nil
    var errorDescription: String? { message }
    static let interrupted = Self(status: 0, message: "连接中断，未收到完整回复。")

    private struct Envelope: Decodable { let error: String; let status: Int? }

    static func response(_ status: Int, _ data: Data) -> Self {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let plain = String(data: data.prefix(400), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let readable = plain.flatMap { $0.isEmpty || $0.hasPrefix("<") ? nil : $0 }
        return Self(status: status, message: envelope?.error ?? readable ?? "请求失败（HTTP \(status)）。", body: data)
    }

    static func stream(_ data: Data) -> Self {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        return Self(status: envelope?.status ?? 500, message: envelope?.error ?? "服务暂时无法完成生成。", body: data)
    }

    func current<Value: Decodable>(_ type: Value.Type) -> Value? {
        guard let body else { return nil }
        return try? JSONDecoder().decode(Conflict<Value>.self, from: body).current
    }

    private struct Conflict<Value: Decodable>: Decodable { let current: Value? }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor WeijiAPIClient {
    nonisolated let configuration: ServerConfiguration
    private let session: URLSession
    private let account: String?

    init(configuration: ServerConfiguration, account: String? = nil, transport: URLSession? = nil) {
        self.configuration = configuration
        self.account = account
        if let transport {
            session = transport
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 600
            config.httpShouldSetCookies = false
            session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        }
    }

    func cancel() { session.invalidateAndCancel() }

    func request(_ path: String, method: String = "GET", body: Data? = nil, stream: Bool = false) throws -> URLRequest {
        guard path.hasPrefix("/api/"), let url = URL(string: configuration.origin + path) else {
            throw WeijiAPIError(status: 0, message: "无效的服务路径。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        request.setValue(account, forHTTPHeaderField: "X-Journal-Account")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if method == "POST" || method == "DELETE" {
            request.setValue(configuration.origin, forHTTPHeaderField: "Origin")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func get<Result: Decodable & Sendable>(_ path: String) async throws -> Result {
        try await send(request(path))
    }

    func post<Result: Decodable & Sendable>(_ path: String, _ body: some Encodable & Sendable) async throws -> Result {
        try await send(request(path, method: "POST", body: JSONEncoder().encode(body)))
    }

    func delete<Result: Decodable & Sendable>(_ path: String) async throws -> Result {
        try await send(request(path, method: "DELETE"))
    }

    private func send<Result: Decodable>(_ request: URLRequest) async throws -> Result {
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw WeijiAPIError.response(code, data) }
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func stream<Result: Decodable & Sendable>(_ path: String, _ fields: [String: JSONValue],
                   onFrame: @Sendable (SSEParser.Frame) async -> Void) async throws -> Result {
        do {
            let request = try request(path, method: "POST", body: JSONEncoder().encode(fields), stream: true)
            let (bytes, response) = try await session.bytes(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 1_048_576 { break }
                }
                throw WeijiAPIError.response(code, data)
            }
            return try await Self.readStream(bytes, onFrame: onFrame)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is URLError { throw WeijiAPIError.interrupted }
            throw error
        }
    }

    static func readStream<Bytes: AsyncSequence, Result: Decodable>(
        _ bytes: Bytes, onFrame: (SSEParser.Frame) async -> Void
    ) async throws -> Result where Bytes.Element == UInt8 {
        var parser = SSEParser()
        var result: Result?
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let frame = try parser.push(byte) else { continue }
            let data = Data(frame.data.utf8)
            switch frame.event {
            case "error": throw WeijiAPIError.stream(data)
            case "done": result = try JSONDecoder().decode(Result.self, from: data)
            default: await onFrame(frame)
            }
        }
        try parser.finish()
        guard let result else { throw WeijiAPIError.interrupted }
        return result
    }

    static func withQuery(_ path: String, _ items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = items.isEmpty ? nil : items
        return components.string ?? path
    }
}
