import XCTest
@testable import Weiji

@MainActor
final class StoreLogicTests: XCTestCase {
    func test409ConflictPreservesDraftWithoutOverwritingServer() async throws {
        let initial = Note(id: "note", body: "原始版本", createdAt: "2025-02-01T00:00:00.000Z", revision: 2)
        let payload = #"{"error":"云端版本已更新","current":{"note":{"id":"note","body":"云端版本","createdAt":"2025-02-01T00:00:00.000Z","turns":[],"revision":3}}}"#
        let (config, transport) = try StubProtocol.make { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return .init(status: 409, body: payload)
        }
        defer { StubProtocol.remove(config) }
        let client = WeijiAPIClient(configuration: config, transport: transport)
        let store = AppStore(temporary: true, reset: true)
        await store.applyRecord(.init(note: initial, deleted: nil), id: initial.id)
        var draft = NoteDraft(note: initial)
        draft.body = "我的未保存草稿"
        do {
            let _: NoteRecord = try await client.post("/api/notes", NoteMutation(id: initial.id, expectedRevision: draft.base.revision,
                                                                                 note: initial.writePayload))
            XCTFail("Expected conflict")
        } catch let error as WeijiAPIError {
            await store.applyRecord(error.current(NoteRecord.self), id: initial.id)
            draft.failed(error)
        }
        XCTAssertEqual(store.notesById[initial.id]?.body, "云端版本")
        XCTAssertEqual(store.notesById[initial.id]?.revision, 3)
        XCTAssertTrue(draft.conflict)
        XCTAssertEqual(draft.body, "我的未保存草稿")
        XCTAssertEqual(draft.base.revision, 2)
        draft.review(try XCTUnwrap(store.notesById[initial.id]))
        XCTAssertFalse(draft.conflict)
        XCTAssertEqual(draft.base.revision, 3)
        XCTAssertEqual(draft.body, "我的未保存草稿")
    }

    func testClientRequestIdReusesOnRetryAndChangesOnVersionOrFieldEdit() {
        let base = ChatSignature(sessionId: "session", expectedVersion: 1, sourceNoteId: "note", message: "问题",
                                 referencedNoteIds: ["ref"], model: "model", provider: .codex, useProfile: true)
        var ids = ChatRequestID()
        let first = ids.resolve(base)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, ids.resolve(base))
        let changes: [(inout ChatSignature) -> Void] = [
            { $0.sessionId = nil }, { $0.expectedVersion = 2 }, { $0.sourceNoteId = nil },
            { $0.message += "?" }, { $0.referencedNoteIds.append("second") }, { $0.model = "new" },
            { $0.provider = .openai }, { $0.useProfile = false },
        ]
        for edit in changes {
            var changed = base
            let oldID = ids.resolve(base)
            edit(&changed)
            let fresh = ids.resolve(changed)
            XCTAssertNotEqual(fresh, oldID)
            XCTAssertEqual(fresh, ids.resolve(changed))
        }
        let last = ids.resolve(base)
        ids.clear()
        XCTAssertNotEqual(ids.resolve(base), last)
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
