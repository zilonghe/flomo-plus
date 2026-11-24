import Foundation
import os
import XCTest
@testable import Weiji

final class StubProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: String
        var headers: [String: String]? = nil
        var failure: URLError.Code? = nil
    }
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> Reply] = [:]

    static func make(handler: @escaping (URLRequest) -> Reply) throws -> (ServerConfiguration, URLSession) {
        let host = UUID().uuidString.lowercased() + ".example"
        lock.lock()
        handlers[host] = handler
        lock.unlock()
        return (try ServerConfiguration(address: "http://" + host + ":5173", token: "test-token-123"),
                transport())
    }

    static func transport() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return URLSession(configuration: config)
    }

    static func remove(_ configuration: ServerConfiguration) {
        guard let host = URL(string: configuration.origin)?.host else { return }
        lock.lock()
        handlers[host] = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let handler = Self.handlers[url.host ?? ""]
        Self.lock.unlock()
        let reply = handler?(request) ?? .init(status: 500, body: "Unexpected request")
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    func testObsidianStatusAndManualSyncUseAdminRoutes() async throws {
        XCTAssertEqual(ServerConfiguration.defaultOrigin, "https://weiji.18818888.xyz")
        let stats = #"{"scanned":12,"fetched":5,"created":2,"updated":1,"skipped":7,"excluded":1,"conflicts":1}"#
        let status = #"{"configured":true,"running":false,"intervalMs":3600000,"prefixes":["memo/","永久笔记/"],"lastRun":{"at":"2026-11-24T00:00:00.000Z","trigger":"manual","ok":true,"error":null,"indexWarning":"Index pending","stats":\#(stats)}}"#
        let statusRequests = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Journal-Account"), "admin")
            switch request.url?.path {
            case "/api/admin/obsidian/status":
                XCTAssertEqual(request.httpMethod, "GET")
                let configured = statusRequests.withLock { $0 += 1; return $0 > 1 }
                return .init(status: 200, body: configured ? status : #"{"configured":false}"#)
            case "/api/admin/obsidian/sync":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(jsonBody(request)?.isEmpty, true)
                return .init(status: 200, body: #"{"ok":true,"stats":\#(stats),"status":\#(status)}"#)
            default:
                XCTFail("Unexpected endpoint")
                return .init(status: 404, body: "")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let client = WeijiAPIClient(configuration: config, account: "admin", transport: transport)
        let unavailable = try await client.obsidianStatus()
        XCTAssertEqual(unavailable, .init(configured: false, running: nil, intervalMs: nil, prefixes: nil, lastRun: nil))
        let available = try await client.obsidianStatus()
        XCTAssertTrue(available.configured)
        XCTAssertEqual(available.running, false)
        XCTAssertEqual(available.intervalMs, 3_600_000)
        XCTAssertEqual(available.prefixes, ["memo/", "永久笔记/"])
        let sync = try await client.triggerObsidianSync()
        XCTAssertTrue(sync.ok)
        XCTAssertEqual(sync.stats, .init(scanned: 12, fetched: 5, created: 2, updated: 1, skipped: 7, excluded: 1, conflicts: 1))
        XCTAssertEqual(available.lastRun, .init(at: "2026-11-24T00:00:00.000Z", trigger: "manual", ok: true,
                                                error: nil, indexWarning: "Index pending", stats: sync.stats))
        XCTAssertEqual(sync.status, available)
    }

    func testSetsBearerAndExactOriginAndDefaultsCodexProvider() async throws {
        let config = try ServerConfiguration(address: "HTTP://EXAMPLE.COM:5173/", token: "test-token-123")
        let client = WeijiAPIClient(configuration: config, account: "tester")
        let get = try await client.request("/api/session")
        XCTAssertNil(get.value(forHTTPHeaderField: "Origin"))
        for method in ["POST", "DELETE"] {
            let request = try await client.request("/api/notes", method: method)
            XCTAssertEqual(request.url?.absoluteString, "http://example.com:5173/api/notes")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://example.com:5173")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Journal-Account"), "tester")
        }
        XCTAssertEqual(try ServerConfiguration(address: "https://example.com:443/", token: "x").origin, "https://example.com")
        let first = Data(#"{"user":{"id":"a","name":"试用"},"codexAvailable":true,"codexMode":"gateway"}"#.utf8)
        let second = Data(#"{"user":{"id":"a","name":"试用"},"codexAvailable":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: first).defaultProvider, .codex)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: second).defaultProvider, .openai)
    }

    func testHandlesPlainText401And403AndHTTP409() async throws {
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.lastPathComponent {
            case "session": .init(status: 401, body: "Unauthorized")
            case "profile": .init(status: 403, body: "Forbidden")
            default: .init(status: 409, body: #"{"error":"云端版本已更新","current":{"deleted":{"id":"n","revision":3}}}"#)
            }
        }
        defer { StubProtocol.remove(config) }
        let client = WeijiAPIClient(configuration: config, transport: transport)
        for (path, status, message) in [("session", 401, "Unauthorized"), ("profile", 403, "Forbidden"), ("notes", 409, "云端版本已更新")] {
            do {
                let _: NoteRecord = try await client.get("/api/" + path)
                XCTFail("Expected HTTP \(status)")
            } catch let error as WeijiAPIError {
                XCTAssertEqual(error.status, status)
                XCTAssertEqual(error.message, message)
                if status == 409 { XCTAssertEqual(error.current(NoteRecord.self)?.deleted?.revision, 3) }
            }
        }
    }

    func testHandlesStream409And429AndLocalCancel() async throws {
        for status in [409, 429] {
            let wire = "event: delta\ndata: {}\n\nevent: error\ndata: {\"error\":\"请求失败\",\"status\":\(status)}\n\nevent: done\ndata: {}\n\n"
            var events: [String] = []
            do {
                let _: NoteRecord = try await WeijiAPIClient.readStream(bytes(wire)) { events.append($0.event) }
                XCTFail("Stream error should terminate the response")
            } catch let error as WeijiAPIError {
                XCTAssertEqual(error.status, status)
                XCTAssertEqual(error.message, "请求失败")
                XCTAssertEqual(events, ["delta"])
            }
        }
        let (suspended, continuation) = AsyncStream<UInt8>.makeStream()
        let task = Task { () throws -> NoteRecord in try await WeijiAPIClient.readStream(suspended) { _ in } }
        task.cancel()
        continuation.finish()
        do {
            _ = try await task.value
            XCTFail("Expected local cancellation")
        } catch is CancellationError {}
    }

    func testDecodesReadOnlyRelatedNoteSummaryWithoutRevision() async throws {
        let wire = """
        {"focus":{"id":"a","body":"焦点","createdAt":"2025-03-01T00:00:00.000Z","reading":null},
        "mode":"lexical","indexed":0,"total":2,
        "related":[{"id":"b","score":0.47,"relevancePercent":47,"sharedTags":["工作"],
        "note":{"id":"b","body":"关联","createdAt":"2025-02-01T00:00:00.000Z"}}]}
        """
        let (config, transport) = try StubProtocol.make { request in
            XCTAssertEqual(request.url?.path, "/api/notes/a/related")
            XCTAssertEqual(request.url?.query, "limit=10")
            return .init(status: 200, body: wire)
        }
        defer { StubProtocol.remove(config) }
        let client = WeijiAPIClient(configuration: config, transport: transport)
        let related: RelatedNotes = try await client.get("/api/notes/a/related?limit=10")
        XCTAssertEqual(related.focus.body, "焦点")
        XCTAssertEqual(related.related.first?.note.id, "b")
        XCTAssertEqual(related.related.first?.relevancePercent, 47)
        let readOnly = Data(#"{"id":"x","body":"x","createdAt":"2025-02-01T00:00:00.000Z","turns":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Note.self, from: readOnly))
    }

    func testProbeRequestsUse10SecondTimeoutWhileDefaultIs90() async throws {
        let config = try ServerConfiguration(address: "https://weiji.example", token: "")
        let client = WeijiAPIClient(configuration: config)
        for (path, timeout) in [("/api/session", 10.0), ("/api/auth/providers", 10.0), ("/api/notes", 90.0)] {
            let request = try await client.request(path)
            XCTAssertEqual(request.timeoutInterval, timeout, path)
        }
        await client.cancel()
    }

    @MainActor
    func testOAuthPKCEChallengeMatchesRFC7636AndExchangesCode() async throws {
        let pkce = OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "expected-state")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            requests.withLock { $0 += 1 }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/auth/exchange")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = jsonBody(request)
            XCTAssertEqual(body?["code"] as? String, "app-code")
            XCTAssertEqual(body?["codeVerifier"] as? String, pkce.verifier)
            XCTAssertEqual(body?["deviceLabel"] as? String, "iPhone")
            return .init(status: 200, body: #"{"token":"issued-token","sessionId":"new-session","expiresAt":"2026-11-24T08:51:00Z"}"#)
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let start = try pkce.startURL(origin: config.origin, provider: "github")
        let query = URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "code_challenge" }?.value, pkce.challenge)
        XCTAssertEqual(query?.first { $0.name == "redirect_uri" }?.value, OAuthPKCE.callback)

        var credentialWrites = 0
        let credentials = KeychainStore(read: { _, _ in nil }, write: { _, _, _ in credentialWrites += 1 })
        let store = AppStore(reset: true, credentials: credentials, makeTransport: StubProtocol.transport)
        let wrong = try XCTUnwrap(URL(string: "weiji://auth/callback?code=app-code&state=wrong"))
        do {
            try await store.finishOAuth(origin: config.origin, callback: wrong, pkce: pkce, deviceLabel: "iPhone")
            XCTFail("Mismatched state must stop login")
        } catch let error as WeijiAPIError {
            XCTAssertEqual(error.status, 0)
        }
        XCTAssertEqual(requests.withLock { $0 }, 0)
        XCTAssertNil(store.configuration)
        XCTAssertEqual(credentialWrites, 0)

        let right = try XCTUnwrap(URL(string: "weiji://auth/callback?code=app-code&state=expected-state"))
        let anonymous = try ServerConfiguration(address: config.origin, token: "")
        let exchange = try await WeijiAPIClient(configuration: anonymous, transport: transport)
            .exchangeOAuthCallback(right, pkce: pkce, deviceLabel: "iPhone")
        XCTAssertEqual(exchange.token, "issued-token")
        XCTAssertEqual(exchange.sessionId, "new-session")
        XCTAssertEqual(requests.withLock { $0 }, 1)
    }

    func testAuthProvidersDecodingAndLogoutRevocationRequest() async throws {
        let revocations = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            if request.url?.path == "/api/auth/providers" {
                XCTAssertEqual(request.httpMethod, "GET")
                return .init(status: 200, body: #"{"authMode":"oauth","publicOrigin":"https://weiji.example","inviteRequired":true,"providers":[{"id":"github","name":"GitHub"},{"id":"google","name":"Google"}]}"#)
            }
            XCTAssertEqual(request.url?.path, "/api/auth/logout")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")
            let server = request.url.flatMap { URL(string: "/", relativeTo: $0)?.absoluteURL }
            let expectedOrigin = server.flatMap { try? ServerConfiguration(address: $0.absoluteString, token: "").origin }
            XCTAssertNotNil(expectedOrigin)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), expectedOrigin)
            revocations.withLock { $0 += 1 }
            return .init(status: 200, body: #"{"ok":true}"#)
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let client = WeijiAPIClient(configuration: config, transport: transport)
        let result = try await client.authProviders()
        XCTAssertEqual(result.authMode, "oauth")
        XCTAssertEqual(result.publicOrigin, "https://weiji.example")
        XCTAssertTrue(result.inviteRequired)
        XCTAssertEqual(result.providers.map(\.id), ["github", "google"])
        try await client.logout()
        XCTAssertEqual(revocations.withLock { $0 }, 1)
    }

    private func bytes(_ value: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in value.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
    }
}
