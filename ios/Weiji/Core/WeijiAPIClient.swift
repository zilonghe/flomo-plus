import CommonCrypto
import Foundation
import Security

struct ServerConfiguration: Equatable, Sendable {
    static let defaultOrigin = "https://weiji.18818888.xyz"

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
    var rejectsAuthentication: Bool { status == 401 || status == 403 }
    static let interrupted = Self(status: 0, message: "连接中断，未收到完整回复。")

    static func network(_ error: URLError) -> Self {
        let code = error.code.rawValue
        switch error.code {
        case .timedOut:
            return Self(status: 0, message: "AI 响应超时（\(code)），请重试或切换更快的模型。")
        case .notConnectedToInternet, .dataNotAllowed:
            return Self(status: 0, message: "当前无网络连接（\(code)），请检查网络后重试。")
        case .networkConnectionLost:
            return Self(status: 0, message: "网络连接中途断开（\(code)），请重试。")
        default:
            return Self(status: 0, message: "网络连接中断（\(code)），未收到完整回复。")
        }
    }

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

struct OAuthProviders: Decodable, Sendable {
    struct Provider: Decodable, Identifiable, Sendable { let id: String; let name: String }
    let authMode: String
    let inviteRequired: Bool
    let publicOrigin: String
    let providers: [Provider]
}

struct OAuthExchange: Decodable, Sendable {
    let token: String
    let sessionId: String
    let expiresAt: String
}

struct OAuthPKCE: Sendable {
    static let callback = "weiji://auth/callback"
    let verifier: String
    let state: String

    static func generate() throws -> Self {
        Self(verifier: try randomValue(), state: try randomValue())
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw WeijiAPIError.interrupted }
        return base64URL(bytes)
    }

    private static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var challenge: String {
        let data = Data(verifier.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &digest) }
        return Self.base64URL(digest)
    }

    func startURL(origin: String, provider: String) throws -> URL {
        guard ["github", "google"].contains(provider),
              var url = URLComponents(string: origin + "/auth/" + provider + "/start") else {
            throw WeijiAPIError.interrupted
        }
        url.queryItems = [
            .init(name: "client", value: "ios"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "redirect_uri", value: Self.callback)
        ]
        guard let target = url.url else { throw WeijiAPIError.interrupted }
        return target
    }

    func code(from callbackURL: URL) throws -> String {
        guard var parts = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              parts.fragment == nil else { throw WeijiAPIError.interrupted }
        let query = parts.queryItems ?? []
        parts.query = nil
        let states = query.filter { $0.name == "state" }
        guard parts.string == Self.callback, states.count == 1, states[0].value == state else {
            throw WeijiAPIError(status: 0, message: "登录回调与当前请求不匹配，请重新登录。")
        }
        if query.contains(where: { $0.name == "error" && $0.value == "account_disabled" }) {
            throw WeijiAPIError(status: 403, message: "该账号已停用。")
        }
        let codes = query.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { throw WeijiAPIError.interrupted }
        return code
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum NotesFetchResult: Sendable {
    case notModified
    case updated([Note], etag: String?)
}

actor WeijiAPIClient {
    nonisolated let configuration: ServerConfiguration
    private let session: URLSession
    private let account: String?
    private let onObsidianNotesChanged: (@Sendable () async -> Void)?
    private let onAuthenticationRejected: (@Sendable (WeijiAPIError) async -> Void)?

    init(configuration: ServerConfiguration, account: String? = nil, transport: URLSession? = nil,
         onObsidianNotesChanged: (@Sendable () async -> Void)? = nil,
         onAuthenticationRejected: (@Sendable (WeijiAPIError) async -> Void)? = nil) {
        self.configuration = configuration
        self.account = account
        self.onObsidianNotesChanged = onObsidianNotesChanged
        self.onAuthenticationRejected = onAuthenticationRejected
        if let transport {
            session = transport
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 180
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
        let timeout: TimeInterval = ["/api/session", "/api/auth/providers"].contains(path) ? 10 : (stream ? 180 : 90)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        if !configuration.token.isEmpty {
            request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        }
        request.setValue(account, forHTTPHeaderField: "X-Journal-Account")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if stream {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
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

    func fetchNotes(ifNoneMatch: String? = nil) async throws -> NotesFetchResult {
        var request = try request("/api/notes")
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 304: return .notModified
        case 200:
            let result = try JSONDecoder().decode(NotesResponse.self, from: data)
            return .updated(result.notes, etag: http?.value(forHTTPHeaderField: "ETag"))
        default: throw await responseError(http?.statusCode ?? 0, data)
        }
    }

    func post<Result: Decodable & Sendable>(_ path: String, _ body: some Encodable & Sendable) async throws -> Result {
        try await send(request(path, method: "POST", body: JSONEncoder().encode(body)))
    }

    func delete<Result: Decodable & Sendable>(_ path: String) async throws -> Result {
        try await send(request(path, method: "DELETE"))
    }

    func authProviders() async throws -> OAuthProviders {
        try await get("/api/auth/providers")
    }

    func obsidianStatus() async throws -> ObsidianSyncStatus {
        try await get("/api/admin/obsidian/status")
    }

    func triggerObsidianSync() async throws -> ObsidianSyncResponse {
        let result: ObsidianSyncResponse = try await post("/api/admin/obsidian/sync", [String: String]())
        if result.stats.created > 0 || result.stats.updated > 0 { await onObsidianNotesChanged?() }
        return result
    }

    func exchangeOAuthCallback(_ callback: URL, pkce: OAuthPKCE, deviceLabel: String) async throws -> OAuthExchange {
        let code = try pkce.code(from: callback)
        return try await post("/api/auth/exchange", [
            "code": code, "codeVerifier": pkce.verifier, "deviceLabel": deviceLabel
        ])
    }

    func logout() async throws {
        struct Result: Decodable { let ok: Bool }
        let result: Result = try await send(request("/api/auth/logout", method: "POST"))
        if !result.ok { throw WeijiAPIError.interrupted }
    }

    private func send<Result: Decodable>(_ request: URLRequest) async throws -> Result {
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw await responseError(code, data) }
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func stream<Result: Decodable & Sendable>(_ path: String, _ fields: [String: JSONValue],
                   beforeDispatch: (@Sendable () -> Bool)? = nil,
                   onFrame: @Sendable (SSEParser.Frame) async -> Void) async throws -> Result {
        do {
            try Task.checkCancellation()
            let request = try request(path, method: "POST", body: JSONEncoder().encode(fields), stream: true)
            try Task.checkCancellation()
            if let beforeDispatch, !beforeDispatch() { throw CancellationError() }
            let (bytes, response) = try await session.bytes(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 1_048_576 { break }
                }
                try Task.checkCancellation()
                throw await responseError(code, data)
            }
            return try await Self.readStream(bytes, onFrame: onFrame)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let urlError = error as? URLError { throw WeijiAPIError.network(urlError) }
            throw error
        }
    }

    private func responseError(_ status: Int, _ data: Data) async -> WeijiAPIError {
        let failure = WeijiAPIError.response(status, data)
        if failure.rejectsAuthentication { await onAuthenticationRejected?(failure) }
        return failure
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
            case "done":
                result = try JSONDecoder().decode(Result.self, from: data)
                await onFrame(frame)
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
