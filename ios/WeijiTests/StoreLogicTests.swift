import XCTest
import os
@testable import Weiji

@MainActor
final class StoreLogicTests: XCTestCase {
    func test409ConflictPreservesDraftWithoutOverwritingServer() async throws {
        let conflicts = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            if request.url?.path == "/api/session" { return .init(status: 200, body: sessionFixture) }
            XCTAssertEqual(request.url?.path, "/api/notes")
            if request.httpMethod == "GET" { return .init(status: 200, body: notesFixture) }
            XCTAssertEqual(request.httpMethod, "POST")
            let body = jsonBody(request)
            let attempt = conflicts.withLock { $0 += 1; return $0 }
            XCTAssertEqual(body?["id"] as? String, "note")
            XCTAssertEqual(body?["expectedRevision"] as? Int, attempt + 1)
            XCTAssertEqual((body?["note"] as? [String: Any])?["body"] as? String, "我的未保存草稿")
            let payload = attempt == 1
                ? #"{"error":"云端版本已更新","current":{"note":{"id":"note","body":"云端版本","createdAt":"2025-02-01T00:00:00.000Z","turns":[],"revision":3}}}"#
                : #"{"error":"这条笔记已被删除","current":null}"#
            return .init(status: 409, body: payload)
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let store = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        store.start()
        try await waitUntil("同步原始笔记") { !store.syncing }
        var draft = NoteDraft(note: try XCTUnwrap(store.notesById["note"]))
        draft.body = "我的未保存草稿"

        do {
            try await store.update(draft.base, body: draft.body)
            XCTFail("Expected an updated-record conflict")
        } catch let error as WeijiAPIError {
            XCTAssertEqual(error.status, 409)
            draft.failed(error)
        }
        XCTAssertEqual(store.notesById["note"]?.body, "云端版本")
        XCTAssertEqual(store.notesById["note"]?.revision, 3)
        XCTAssertTrue(draft.conflict)
        XCTAssertEqual(draft.body, "我的未保存草稿")
        XCTAssertEqual(draft.base.revision, 2)
        draft.review(try XCTUnwrap(store.notesById["note"]))
        XCTAssertFalse(draft.conflict)
        XCTAssertEqual(draft.base.revision, 3)
        XCTAssertEqual(draft.body, "我的未保存草稿")

        do {
            try await store.update(draft.base, body: draft.body)
            XCTFail("Expected a deleted-record conflict")
        } catch let error as WeijiAPIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertNil(error.current(NoteRecord.self))
            draft.failed(error)
        }
        XCTAssertNil(store.notesById["note"])
        XCTAssertTrue(draft.conflict)
        XCTAssertEqual(draft.body, "我的未保存草稿")
        XCTAssertEqual(conflicts.withLock { $0 }, 2)
    }

    func testClientRequestIdReusesOnRetryAndChangesOnVersionOrFieldEdit() async throws {
        struct Sent {
            let id: String
            let version: Int
            let message: String
            let pins: [String]
            let model: String
            let otherFields: Data
        }
        let wire = OSAllocatedUnfairLock(initialState: [Sent]())
        let persisted = OSAllocatedUnfairLock(initialState: [String]())
        let (config, transport) = try StubProtocol.make { request in
            func session(version: Int) -> String {
                let turns = persisted.withLock { messages in
                    messages.flatMap { [["role": "user", "text": $0], ["role": "assistant", "text": "回复"]] }
                }
                let data = try! JSONSerialization.data(withJSONObject: turns)
                return """
                {"id":"session","title":"会话","version":\(version),"updatedAt":"2025-02-01T00:00:00Z","origin":"chat","turns":\(String(decoding: data, as: UTF8.self))}
                """
            }
            if request.url?.path == "/api/ai/sessions/session", request.httpMethod == "GET" {
                let version = persisted.withLock { $0.isEmpty ? 1 : 2 }
                return .init(status: 200, body: "{\"session\":\(session(version: version))}")
            }
            XCTAssertEqual(request.url?.path, "/api/ai/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            guard var body = jsonBody(request),
                  let id = body.removeValue(forKey: "clientRequestId") as? String,
                  let model = body.removeValue(forKey: "model") as? String,
                  let version = body["expectedVersion"] as? Int,
                  let message = body["message"] as? String,
                  let pins = body["referencedNoteIds"] as? [String],
                  let otherFields = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else {
                XCTFail("Missing fields in the chat POST")
                return .init(status: 500, body: "{}")
            }
            XCTAssertEqual(body["sessionId"] as? String, "session")
            let (attempt, duplicate) = wire.withLock { sent in
                let duplicate = sent.contains { $0.id == id }
                sent.append(Sent(id: id, version: version, message: message, pins: pins, model: model, otherFields: otherFields))
                return (sent.count, duplicate)
            }
            if attempt <= 2, !duplicate { persisted.withLock { $0.append(message) } }
            let headers = ["Content-Type": "text/event-stream"]
            if attempt == 2 {
                return .init(status: 200, body: "event: done\ndata: {\"session\":\(session(version: 2))}\n\n", headers: headers)
            }
            if attempt == 5 {
                return .init(status: 409, body: "{\"error\":\"版本已更新\",\"current\":\(session(version: 3))}")
            }
            return .init(status: 200, body: "event: delta\ndata: {\"text\":\"部分回复\"}\n\n", headers: headers)
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let client = WeijiAPIClient(configuration: config, transport: transport)
        let chat = AIChatStore()
        let profile = InsightsStore()
        chat.select("session", api: client)
        try await waitUntil("读取会话") { !chat.loadingSession }
        XCTAssertEqual(chat.session?.version, 1)
        chat.togglePin("ref")
        chat.draft = "原始问题"

        func send(model: String = "model-a") async throws {
            chat.send(api: client, options: AIOptions(provider: .codex, model: model), profile: profile)
            XCTAssertTrue(chat.sending)
            try await waitUntil("聊天请求完成") { !chat.sending }
        }
        try await send()
        XCTAssertEqual(chat.error, WeijiAPIError.interrupted.message)
        XCTAssertEqual(chat.draft, "原始问题")
        try await send()
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.session?.turns?.map(\.role), ["user", "assistant"])
        let reloaded: ChatResponse = try await client.get("/api/ai/sessions/session")
        XCTAssertEqual(reloaded.session?.turns?.map(\.text), ["原始问题", "回复"])

        chat.draft = "下一问"
        try await send()
        chat.draft = "修改后的问题"
        try await send()
        chat.togglePin("second")
        try await send()
        XCTAssertEqual(chat.session?.version, 3)
        try await send()
        try await send(model: "model-b")

        let requests = wire.withLock { $0 }
        XCTAssertEqual(requests.map(\.version), [1, 1, 2, 2, 2, 3, 3])
        XCTAssertEqual(requests.map(\.message), ["原始问题", "原始问题", "下一问", "修改后的问题", "修改后的问题", "修改后的问题", "修改后的问题"])
        XCTAssertEqual(requests.map(\.pins), [["ref"], ["ref"], ["ref"], ["ref"], ["ref", "second"], ["ref", "second"], ["ref", "second"]])
        if requests.count == 7 {
            XCTAssertTrue(requests.allSatisfy { UUID(uuidString: $0.id) != nil })
            XCTAssertEqual(requests[0].id, requests[1].id)
            XCTAssertEqual(Set(requests.dropFirst().map(\.id)).count, 6)
            XCTAssertEqual(requests[5].model, "model-a")
            XCTAssertEqual(requests[6].model, "model-b")
            XCTAssertEqual(requests[5].otherFields, requests[6].otherFields)
            XCTAssertNotEqual(requests[5].id, requests[6].id, "Changing only the POST model must change its request ID")
        }

        let typed = "问题"
        let insight = InsightReport(id: "report", title: "洞察", lensName: "回顾", content: "报告正文", excerpt: nil,
                                    citations: nil, createdAt: "2025-02-01T00:00:00Z")
        let base = ChatSignature(sessionId: "session", expectedVersion: 1, sourceNoteId: "note", message: typed,
                                 referencedNoteIds: ["ref"], model: "model-a", provider: .codex, useProfile: true)
        let changes: [(String, (inout ChatSignature) -> Void)] = [
            ("sessionId", { $0.sessionId = nil }),
            ("expectedVersion", { $0.expectedVersion = 2 }),
            ("sourceNoteId", { $0.sourceNoteId = nil }),
            ("message", { $0.message += "?" }),
            ("referencedNoteIds", { $0.referencedNoteIds.append("second") }),
            ("model", { $0.model = "model-b" }),
            ("provider", { $0.provider = .openai }),
            ("useProfile", { $0.useProfile = false }),
            // Insight context is sent as part of the message, even when the typed question stays the same.
            ("insightContext", { $0.message = AIChatStore.message(typed, insight: insight) }),
        ]
        var ids = ChatRequestID()
        let first = ids.resolve(base)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, ids.resolve(base))
        for (field, edit) in changes {
            var changed = base
            let oldID = ids.resolve(base)
            edit(&changed)
            let newID = ids.resolve(changed)
            XCTAssertNotNil(UUID(uuidString: newID), field)
            XCTAssertNotEqual(newID, oldID, field)
            XCTAssertEqual(newID, ids.resolve(changed), field)
        }
        let last = ids.resolve(base)
        ids.clear()
        let afterClear = ids.resolve(base)
        XCTAssertNotNil(UUID(uuidString: afterClear))
        XCTAssertNotEqual(afterClear, last)
    }

    func testSameAccountReauthRecoversChatDraftAndIsolatesOtherAccount() async throws {
        let draft = "same-account-unsent-draft"
        let otherCredential = UUID().uuidString
        let otherSession = #"{"user":{"id":"other-account","name":"另一个账户"},"codexAvailable":false}"#
        let emptyNotes = #"{"notes":[],"deleted":[]}"#
        let oldSessions = #"{"sessions":[{"id":"old-session","title":"旧会话","version":1,"updatedAt":"2025-02-01T00:00:00Z","origin":"chat"}]}"#
        let statuses = [401, 401, 403]
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/session"):
                let isOther = request.value(forHTTPHeaderField: "Authorization") == "Bearer " + otherCredential
                return .init(status: 200, body: isOther ? otherSession : sessionFixture)
            case ("GET", "/api/notes"):
                let isOld = request.value(forHTTPHeaderField: "X-Journal-Account") == "account"
                return .init(status: 200, body: isOld ? notesFixture : emptyNotes)
            case ("GET", "/api/ai/sessions"):
                return .init(status: 200, body: oldSessions)
            case ("POST", "/api/ai/chat"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Journal-Account"), "account")
                XCTAssertEqual(jsonBody(request)?["message"] as? String, draft)
                let attempt = posts.withLock { $0 += 1; return $0 }
                let status = statuses.indices.contains(attempt - 1) ? statuses[attempt - 1] : 500
                return .init(status: status, body: "HTTP \(status)")
            default:
                XCTFail("Unexpected request to the original origin")
                return .init(status: 404, body: "")
            }
        }
        let (otherOrigin, otherTransport) = try StubProtocol.make { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/session"): return .init(status: 200, body: sessionFixture)
            case ("GET", "/api/notes"): return .init(status: 200, body: emptyNotes)
            default:
                XCTFail("Unexpected request to the other origin")
                return .init(status: 404, body: "")
            }
        }
        defer {
            transport.invalidateAndCancel(); StubProtocol.remove(config)
            otherTransport.invalidateAndCancel(); StubProtocol.remove(otherOrigin)
        }
        let renewed = try ServerConfiguration(address: config.origin.uppercased() + "/", token: UUID().uuidString)
        let otherAccount = try ServerConfiguration(address: config.origin, token: otherCredential)

        func authenticate(_ store: AppStore, with config: ServerConfiguration, userId: String) async throws {
            store.connect(config, save: false)
            try await waitUntil("完成认证与笔记同步") { !store.syncing }
            XCTAssertEqual(store.identity?.user.id, userId)
            XCTAssertNotNil(store.api)
            XCTAssertFalse(store.showSettings)
        }

        for (next, userId, status, expectedDraft) in [(renewed, "account", 401, draft),
                                                       (otherAccount, "other-account", 401, ""),
                                                       (otherOrigin, "account", 403, "")] {
            let store = AppStore(temporary: true, reset: true, makeTransport: StubProtocol.transport)
            try await authenticate(store, with: config, userId: "account")
            try await waitUntil("旧账户笔记可见") { store.results.map(\.id) == ["note"] }
            let api = try XCTUnwrap(store.api)
            store.chat.refreshSessions(api: api)
            try await waitUntil("旧账户会话可见") { store.chat.sessions.map(\.id) == ["old-session"] }

            store.chat.draft = draft
            store.chat.send(api: api, options: store.options, profile: store.insights)
            XCTAssertTrue(store.chat.sending)
            try await waitUntil("认证失效并显示登录页") { store.authScreenState == .needsLogin && !store.syncing }
            XCTAssertFalse(store.showSettings)
            XCTAssertEqual(store.error, "HTTP \(status)")
            XCTAssertNil(store.api)
            XCTAssertNil(store.identity)
            XCTAssertFalse(store.isOffline)
            XCTAssertTrue(store.notesById.isEmpty)
            XCTAssertTrue(store.results.isEmpty)
            XCTAssertTrue(store.chat.sessions.isEmpty)
            XCTAssertEqual(store.chat.draft, "")

            try await authenticate(store, with: next, userId: userId)
            XCTAssertEqual(store.chat.draft, expectedDraft, "Reauth as \(userId) at \(next.origin)")
            if next != renewed { XCTAssertTrue(store.notesById.isEmpty) }

            try await authenticate(store, with: renewed, userId: "account")
            XCTAssertEqual(store.chat.draft, "", "A consumed or discarded draft must not reappear")
        }
        XCTAssertEqual(posts.withLock { $0 }, statuses.count)
    }

    func testOfflineColdStartLoadsCachedNotesAndIsolatesChangedCredentials() async throws {
        // 0 = online, -1 = offline, otherwise an HTTP status.
        let mode = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            let state = mode.withLock { $0 }
            if state == -1 { return .init(status: 0, body: "", failure: .notConnectedToInternet) }
            if state != 0 { return .init(status: state, body: "Session rejected") }
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Journal-Account"), "account")
                return .init(status: 200, body: notesFixture)
            default:
                XCTFail("Unexpected endpoint")
                return .init(status: 404, body: "")
            }
        }
        let (otherOrigin, otherTransport) = try StubProtocol.make { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return .init(status: 0, body: "", failure: .timedOut)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            transport.invalidateAndCancel(); StubProtocol.remove(config)
            otherTransport.invalidateAndCancel(); StubProtocol.remove(otherOrigin)
            try? FileManager.default.removeItem(at: directory)
        }

        func launch(_ config: ServerConfiguration) async throws -> AppStore {
            let store = AppStore(initial: config, temporary: true, cache: NoteCacheStore(directory: directory),
                                 makeTransport: StubProtocol.transport)
            store.start()
            try await waitUntil("连接结束") { !store.syncing }
            return store
        }
        var online = try await launch(config)
        XCTAssertEqual(online.identity?.user.id, "account")
        XCTAssertEqual(online.notesById["note"]?.body, "原始版本")

        mode.withLock { $0 = -1 }
        let normalized = try ServerConfiguration(address: config.origin.uppercased() + "/", token: " \(config.token) ")
        let offline = try await launch(normalized)
        XCTAssertTrue(offline.isOffline)
        XCTAssertFalse(offline.showSettings)
        XCTAssertNil(offline.api)
        XCTAssertNil(offline.identity)
        XCTAssertEqual(offline.notesById["note"]?.body, "原始版本")
        try await waitUntil("离线列表可浏览") { offline.results.map(\.id) == ["note"] }

        let changed = try ServerConfiguration(address: config.origin, token: "different-token")
        func assertIsolated(_ store: AppStore) {
            XCTAssertEqual(store.authScreenState, .needsLogin)
            XCTAssertFalse(store.showSettings)
            XCTAssertFalse(store.isOffline)
            XCTAssertNil(store.identity)
            XCTAssertNil(store.api)
            XCTAssertTrue(store.notesById.isEmpty)
            XCTAssertTrue(store.results.isEmpty)
        }
        assertIsolated(try await launch(changed))
        let switched = try ServerConfiguration(address: otherOrigin.origin, token: config.token)
        assertIsolated(try await launch(switched))
        offline.connect(changed, save: false)
        try await waitUntil("更换凭据后离线缓存不可见") { !offline.syncing }
        assertIsolated(offline)
        offline.connect(config, save: false)
        try await waitUntil("切回旧凭据仍需重新认证") { !offline.syncing }
        assertIsolated(offline)

        mode.withLock { $0 = 500 }
        assertIsolated(try await launch(config))
        for status in [401, 403] {
            mode.withLock { $0 = status }
            assertIsolated(try await launch(config))
            mode.withLock { $0 = -1 }
            assertIsolated(try await launch(config))
            mode.withLock { $0 = 0 }
            online = try await launch(config)
        }
        // Rejection after successful authentication must also drop the currently visible notes.
        mode.withLock { $0 = 403 }
        online.refresh()
        try await waitUntil("同步拒绝后清除账号") { !online.syncing }
        assertIsolated(online)
        mode.withLock { $0 = -1 }
        assertIsolated(try await launch(config))
    }

    func testPreloadsBoundCacheWhileSessionRequestIsPending() async throws {
        let cachedNote = Note(id: "cached", body: "本地预载笔记", createdAt: "2025-02-01T00:00:00Z", revision: 1)
        for status in [200, 500, 401] {
            let requested = OSAllocatedUnfairLock(initialState: false)
            let release = DispatchSemaphore(value: 0)
            let (config, transport) = try StubProtocol.make { request in
                switch request.url?.path {
                case "/api/session":
                    requested.withLock { $0 = true }
                    if release.wait(timeout: .now() + 8) == .timedOut {
                        XCTFail("Session response was never released")
                    }
                    return .init(status: status, body: status == 200 ? sessionFixture : "HTTP \(status)")
                case "/api/notes":
                    XCTAssertEqual(status, 200)
                    return .init(status: 200, body: notesFixture)
                default:
                    XCTFail("Unexpected endpoint")
                    return .init(status: 404, body: "")
                }
            }
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer {
                release.signal()
                transport.invalidateAndCancel()
                StubProtocol.remove(config)
                try? FileManager.default.removeItem(at: directory)
            }
            let cache = NoteCacheStore(directory: directory)
            let key = NoteCacheStore.Key(origin: config.origin, userId: "account")
            try await cache.save([cachedNote], for: key)
            try await cache.bind(config, userId: key.userId)
            let store = AppStore(initial: config, temporary: true, cache: NoteCacheStore(directory: directory),
                                 makeTransport: StubProtocol.transport)
            XCTAssertEqual(store.authScreenState, .needsLogin)
            store.start()
            XCTAssertEqual(store.authScreenState, .restoring)
            try await waitUntil("会话挂起期间展示已绑定缓存") {
                requested.withLock { $0 } && store.results.map(\.id) == [cachedNote.id]
            }
            XCTAssertTrue(store.syncing)
            XCTAssertTrue(store.isOffline)
            XCTAssertEqual(store.authScreenState, .offline)
            XCTAssertNil(store.api)
            XCTAssertNil(store.identity)
            XCTAssertEqual(store.notesById[cachedNote.id]?.body, cachedNote.body)

            if status != 200 { store.query = "预载" }
            release.signal()
            try await waitUntil("会话完成 HTTP \(status)") { !store.syncing }

            if status == 200 {
                XCTAssertEqual(store.authScreenState, .online)
                XCTAssertFalse(store.isOffline)
                XCTAssertNotNil(store.api)
                try await waitUntil("认证后同步服务器笔记") { store.results.map(\.id) == ["note"] }
            } else {
                XCTAssertEqual(store.authScreenState, .needsLogin)
                XCTAssertFalse(store.showSettings)
                XCTAssertNil(store.api)
                XCTAssertTrue(store.results.isEmpty)
                XCTAssertTrue(store.notesById.isEmpty)
                if status == 500 {
                    // Let detached search callbacks return; a prior result must never reappear.
                    for _ in 0..<20 {
                        try await Task.sleep(for: .milliseconds(10))
                        XCTAssertTrue(store.results.isEmpty)
                        XCTAssertTrue(store.notesById.isEmpty)
                    }
                }
                let bound = try await cache.loadOffline(config)
                XCTAssertEqual(bound?.map(\.id), status == 500 ? [cachedNote.id] : nil)
            }
        }
    }

    func testInsightReportDeleteRemovesOnSuccessAndPreservesOnFailure() async throws {
        let deletes = OSAllocatedUnfairLock(initialState: 0)
        let row = #"{"id":"report","title":"历史洞察","lensName":"回顾","content":"报告正文","createdAt":"2025-02-01T00:00:00Z"}"#
        let (config, transport) = try StubProtocol.make { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/insights/lenses"): return .init(status: 200, body: #"{"lenses":[]}"#)
            case ("GET", "/api/insights/reports"):
                let gone = deletes.withLock { $0 == 2 }
                return .init(status: 200, body: "{\"reports\":[\(gone ? "" : row)]}")
            case ("GET", "/api/insights/reports/report"): return .init(status: 200, body: "{\"report\":\(row)}")
            case ("DELETE", "/api/insights/reports/report"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")
                var origin = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                origin?.path = ""
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), origin?.string)
                return deletes.withLock { attempts in
                    attempts += 1
                    if attempts == 1 { return .init(status: 500, body: #"{"error":"删除失败"}"#) }
                    return .init(status: 200, body: #"{"deleted":"report"}"#)
                }
            default:
                XCTFail("Unexpected report request")
                return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let store = InsightsStore()
        await store.loadLibrary(api: api)
        let report = try XCTUnwrap(store.reports.first)
        store.openReport(report, api: api)
        try await waitUntil("读取报告详情") { !store.running }

        await store.deleteReport(report.id, api: api)
        XCTAssertEqual(store.reports.map(\.id), [report.id])
        XCTAssertTrue(store.showReport)
        XCTAssertEqual(store.reportText, "报告正文")
        XCTAssertEqual(store.reportError, "删除失败")

        await store.deleteReport(report.id, api: api)
        XCTAssertTrue(store.reports.isEmpty)
        XCTAssertFalse(store.showReport)
        XCTAssertNil(store.report)
        XCTAssertNil(store.reportError)
        let reloaded: ReportList = try await api.get("/api/insights/reports")
        XCTAssertTrue(reloaded.reports.isEmpty)
        XCTAssertEqual(deletes.withLock { $0 }, 2)
    }

    func testCustomLensEditPreservesSuggestedRange() async throws {
        let lens = #"{"id":"lens","name":"旧名称","description":"描述","prompt":"分析笔记","category":"自定义","builtin":false,"suggestedRange":"week"}"#
        let (config, transport) = try StubProtocol.make { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/insights/lenses"): return .init(status: 200, body: "{\"lenses\":[\(lens)]}")
            case ("GET", "/api/insights/reports"): return .init(status: 200, body: #"{"reports":[]}"#)
            case ("POST", "/api/insights/lenses"):
                let body = jsonBody(request)
                XCTAssertEqual(body?["id"] as? String, "lens")
                XCTAssertEqual(body?["name"] as? String, "新名称")
                XCTAssertEqual(body?["suggestedRange"] as? String, "week")
                return .init(status: 200, body: "{\"lens\":\(lens.replacingOccurrences(of: "旧名称", with: "新名称"))}")
            default:
                XCTFail("Unexpected lens request")
                return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let insights = InsightsStore()
        await insights.loadLibrary(api: api)
        var input = LensEdit(lens: try XCTUnwrap(insights.lenses.first))
        input.name = "新名称"
        try await insights.saveLens(input, api: api)
        XCTAssertEqual(insights.selectedLens?.name, "新名称")
        XCTAssertEqual(insights.selectedLens?.suggestedRange, "week")
    }

    func testOriginSwitchDoesNotLeakPreviousTokenInSettings() async throws {
        XCTAssertEqual(ConnectionSettingsDraft(configuration: nil).address, ServerConfiguration.defaultOrigin)
        let a = try ServerConfiguration(address: "https://origin-a.example", token: "origin-a-token")
        let seen = OSAllocatedUnfairLock(initialState: [String?]())
        let (b, transport) = try StubProtocol.make { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            seen.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
            return .init(status: 401, body: "Unauthorized")
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(b) }
        let store = AppStore(temporary: true, reset: true, makeTransport: StubProtocol.transport)
        var form = ConnectionSettingsDraft(configuration: a)
        var savedTokens = [a.origin: a.token]
        func savedToken(for origin: String) -> String? { savedTokens[origin] }
        form.setAddress("HTTPS://ORIGIN-A.EXAMPLE:443/", savedToken: savedToken(for:))
        XCTAssertEqual(try form.configuration().token, a.token)

        form.setAddress(b.origin, savedToken: savedToken(for:))
        XCTAssertEqual(form.token, "")
        store.connect(try form.configuration(), save: true)
        try await waitUntil("新服务器未收到旧令牌") { !store.syncing }
        XCTAssertEqual(seen.withLock { $0 }, [nil])

        savedTokens[b.origin] = "origin-b-token"
        form.setAddress(a.origin, savedToken: savedToken(for:))
        form.setAddress(b.origin, savedToken: savedToken(for:))
        XCTAssertEqual(form.token, "origin-b-token")
        store.connect(try form.configuration(), save: true)
        try await waitUntil("新服务器收到自己的令牌") { !store.syncing }
        XCTAssertEqual(seen.withLock { $0 }, [nil, "Bearer origin-b-token"])
    }

    func testLogoutRevokesSessionClearsStateAndBlocksOfflineFallback() async throws {
        let revoked = OSAllocatedUnfairLock(initialState: false)
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/auth/logout":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")
                revoked.withLock { $0 = true }
                return .init(status: 200, body: #"{"ok":true}"#)
            case "/api/session":
                if revoked.withLock({ $0 }) { return .init(status: 0, body: "", failure: .notConnectedToInternet) }
                return .init(status: 200, body: #"{"user":{"id":"account","name":"测试账户","role":"user"},"codexAvailable":false,"authMode":"oauth"}"#)
            case "/api/notes": return .init(status: 200, body: notesFixture)
            default: return .init(status: 500, body: "Unexpected request")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = NoteCacheStore(directory: directory)
        let previousOrigin = UserDefaults.standard.string(forKey: "weiji.origin")
        defer {
            transport.invalidateAndCancel()
            StubProtocol.remove(config)
            UserDefaults.standard.set(previousOrigin, forKey: "weiji.origin")
            try? FileManager.default.removeItem(at: directory)
        }
        var credentials: [String: String] = [:]
        let keychain = KeychainStore(
            read: { origin, _ in credentials[origin] },
            write: { token, origin, _ in credentials[origin] = token.isEmpty ? nil : token }
        )
        let store = AppStore(cache: cache, credentials: keychain, makeTransport: StubProtocol.transport)
        store.connect(config, save: true)
        try await waitUntil("初次同步") { !store.syncing }
        XCTAssertNotNil(store.notesById["note"], store.error ?? "Missing synced note")
        XCTAssertEqual(keychain.serverToken(for: config.origin), config.token)
        let account = NoteCacheStore.Key(origin: config.origin, userId: "account")
        let cached = try await cache.loadOffline(config)
        XCTAssertNotNil(cached?.first)
        store.chat.draft = "退出后清理草稿"

        await store.logout()
        XCTAssertEqual(store.authScreenState, .needsLogin)
        XCTAssertFalse(store.showSettings)
        XCTAssertTrue(revoked.withLock { $0 })
        XCTAssertNil(keychain.serverToken(for: config.origin))
        XCTAssertNil(UserDefaults.standard.string(forKey: "weiji.origin"))
        XCTAssertNil(store.configuration)
        XCTAssertNil(store.identity)
        XCTAssertNil(store.api)
        XCTAssertTrue(store.results.isEmpty && store.notesById.isEmpty)
        XCTAssertTrue(store.chat.draft.isEmpty)
        let cachedAfter = try await cache.load(account)
        let offlineAfter = try await cache.loadOffline(config)
        XCTAssertNil(cachedAfter)
        XCTAssertNil(offlineAfter)

        let restarted = AppStore(initial: config, temporary: true, cache: cache, makeTransport: StubProtocol.transport)
        restarted.start()
        try await waitUntil("退出后离线重启") { !restarted.syncing }
        XCTAssertFalse(restarted.isOffline)
        XCTAssertTrue(restarted.notesById.isEmpty)
        XCTAssertEqual(restarted.authScreenState, .needsLogin)
        XCTAssertFalse(restarted.showSettings)
    }

    func testOriginSwitchAccountIsolatesPersonalOpenAIKey() async throws {
        let (a, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session":
                let userId: String
                switch request.value(forHTTPHeaderField: "Authorization") {
                case "Bearer test-token-123", "Bearer renewed-a-token": userId = "account-a"
                case "Bearer account-b-token": userId = "account-b"
                default: return .init(status: 401, body: "Invalid token")
                }
                return .init(status: 200, body: #"{"user":{"id":"\#(userId)","name":"Test"},"codexAvailable":false,"authMode":"oauth"}"#)
            case "/api/notes": return .init(status: 200, body: notesFixture)
            case "/api/auth/logout": return .init(status: 200, body: #"{"ok":true}"#)
            default: return .init(status: 500, body: "Unexpected request")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            transport.invalidateAndCancel()
            StubProtocol.remove(a)
            try? FileManager.default.removeItem(at: directory)
        }
        let b = try ServerConfiguration(address: a.origin, token: "account-b-token")
        let renewedA = try ServerConfiguration(address: a.origin, token: "renewed-a-token")
        var entries = [a.origin: ["openai": "legacy-origin-only-key"]]
        let keychain = KeychainStore(
            read: { origin, kind in entries[origin]?[kind] },
            write: { secret, origin, kind in entries[origin, default: [:]][kind] = secret.isEmpty ? nil : secret }
        )
        let store = AppStore(cache: NoteCacheStore(directory: directory), credentials: keychain, makeTransport: StubProtocol.transport)
        XCTAssertThrowsError(try store.setAPIKey("unverified-key"))

        store.connect(a, save: false)
        try await waitUntil("账号 A 已验证") { !store.syncing }
        XCTAssertEqual(store.identity?.user.id, "account-a")
        XCTAssertEqual(store.options.apiKey, "")
        try store.setAPIKey("a-personal-key")
        XCTAssertEqual(store.options.apiKey, "a-personal-key")

        await store.logout()
        XCTAssertEqual(store.options.apiKey, "")

        store.connect(b, save: false)
        try await waitUntil("同源账号 B 已验证") { !store.syncing }
        XCTAssertEqual(store.identity?.user.id, "account-b")
        XCTAssertEqual(store.options.apiKey, "")
        try store.setAPIKey("b-personal-key")

        store.connect(renewedA, save: false)
        XCTAssertEqual(store.options.apiKey, "")
        try await waitUntil("账号 A 以新令牌重新登录") { !store.syncing }
        XCTAssertEqual(store.identity?.user.id, "account-a")
        XCTAssertEqual(store.options.apiKey, "a-personal-key")
    }

    private func waitUntil(_ reason: String, _ ready: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !ready(), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(ready(), reason)
    }

    func testProfileSaveFailureBlocksChatSendAndPreservesDraft() async throws {
        let (config, transport) = try StubProtocol.make { request in
            XCTAssertEqual(request.url?.path, "/api/ai/profile", "A failed profile save must prevent a chat POST")
            return .init(status: 500, body: #"{"error":"画像保存失败"}"#)
        }
        defer { StubProtocol.remove(config) }
        let client = WeijiAPIClient(configuration: config, transport: transport)
        let profile = InsightsStore()
        let chat = AIChatStore()
        chat.draft = "应保留的问题"
        let save = try XCTUnwrap(profile.saveProfile(.init(content: "新画像", enabled: true), api: client))
        chat.send(api: client, options: .init(), profile: profile)
        XCTAssertTrue(chat.sending)
        let saved = await save.value
        XCTAssertFalse(saved)
        for _ in 0..<100 where chat.sending { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(chat.sending)
        XCTAssertEqual(chat.draft, "应保留的问题")
        XCTAssertTrue(chat.error?.contains("画像保存失败") == true)
        XCTAssertNil(chat.session)
    }

    func testLateSearchAndStreamResponsesDoNotOverwriteNewerState() async throws {
        let store = AppStore(temporary: true, reset: true)
        let latest = Note(id: "new", body: "only newest", createdAt: "2025-02-01T00:00:00.000Z", revision: 1)
        let stale = Note(id: "old", body: "stale", createdAt: "2025-02-01T00:00:00.000Z", revision: 1)
        await store.applyRecord(.init(note: latest, deleted: nil), id: latest.id)
        store.query = "stale"
        store.query = "newest"
        for _ in 0..<100 where store.results.first?.id != latest.id { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.results.map(\.id), [latest.id])
        store.applySearch([stale], generation: 2)
        XCTAssertEqual(store.results.map(\.id), [latest.id])

        let config = try ServerConfiguration(address: "http://localhost:5173", token: "test-token-123")
        let client = WeijiAPIClient(configuration: config)
        let profile = InsightsStore()
        let chat = AIChatStore()
        chat.draft = "第一个问题"
        chat.send(api: client, options: .init(), profile: profile)
        chat.start()
        chat.draft = "第二个问题"
        chat.send(api: client, options: .init(), profile: profile)
        XCTAssertTrue(chat.sending)
        chat.receive(.init(event: "delta", data: #"{"text":"第二轮"}"#), generation: 3)
        chat.receive(.init(event: "delta", data: #"{"text":"迟到的第一轮"}"#), generation: 1)
        XCTAssertEqual(chat.streamedText, "第二轮")
        chat.stop()
        chat.receive(.init(event: "delta", data: #"{"text":"停止后迟到"}"#), generation: 3)
        XCTAssertEqual(chat.streamedText, "")
        XCTAssertEqual(chat.draft, "第二个问题")
    }
}

private let sessionFixture = #"{"user":{"id":"account","name":"测试账户"},"codexAvailable":false}"#
private let notesFixture = #"{"notes":[{"id":"note","body":"原始版本","createdAt":"2025-02-01T00:00:00.000Z","turns":[],"revision":2}],"deleted":[]}"#

func jsonBody(_ request: URLRequest) -> [String: Any]? {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 2_048)
        var body = Data()
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        data = body
    } else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
