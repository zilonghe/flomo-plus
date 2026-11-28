import XCTest
import os
@testable import Weiji

@MainActor
final class StoreLogicTests: XCTestCase {
    func testRandomReadOpensUnifiedReaderAndLoadsRelatedNotes() async throws {
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes": return .init(status: 200, body: notesFixture)
            case "/api/notes/note/related":
                return .init(status: 200, body: #"{"focus":{"id":"note","body":"原始版本","createdAt":"2025-02-01"},"mode":"lexical","indexed":0,"total":1,"related":[]}"#)
            default:
                XCTFail("Unexpected random-read endpoint: \(request.url?.path ?? "")")
                return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let app = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        app.openRandomRead()
        XCTAssertNil(app.detail)
        app.start()
        try await waitUntil("已加载随机读候选笔记") { !app.syncing && app.notesById["note"] != nil }
        app.openRandomRead()
        XCTAssertEqual(app.detail?.id, "note")
        XCTAssertEqual(app.detail?.source, .walk)
        XCTAssertEqual(app.tab, .notes)
        try await waitUntil("相关笔记已加载") { !app.walk.loading }
        XCTAssertEqual(app.walk.result?.focus.id, app.detail?.id)
        XCTAssertNil(app.walk.randomNote(in: app.index, excluding: app.detail?.id))
    }

    func testUndoDeleteRecreatesOriginalPayloadWithoutTombstonedID() async throws {
        let fixture = #"{"notes":[{"id":"note","body":"原始版本","createdAt":"2025-02-01T00:00:00.000Z","reading":{"bookTitle":"书名","chapter":"第一章"},"turns":[{"role":"user","text":"问题"}],"revision":2}],"deleted":[]}"#
        let restoredID = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        let (config, transport) = try StubProtocol.make { request in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/api/session"): return .init(status: 200, body: sessionFixture)
            case ("GET", "/api/notes"): return .init(status: 200, body: fixture)
            case ("POST", "/api/notes"):
                guard let input = jsonBody(request), let id = input["id"] as? String else {
                    return .init(status: 400, body: "missing payload")
                }
                if input["delete"] as? Bool == true {
                    XCTAssertEqual(id, "note")
                    XCTAssertEqual(input["expectedRevision"] as? Int, 2)
                    return .init(status: 200, body: #"{"deleted":{"id":"note","revision":3}}"#)
                }
                XCTAssertNotEqual(id, "note")
                XCTAssertNotNil(UUID(uuidString: id))
                XCTAssertEqual(input["expectedRevision"] as? Int, 0)
                guard var note = input["note"] as? [String: Any] else {
                    return .init(status: 400, body: "missing note")
                }
                XCTAssertEqual(note["id"] as? String, id)
                XCTAssertEqual(note["body"] as? String, "原始版本")
                XCTAssertEqual(note["createdAt"] as? String, "2025-02-01T00:00:00.000Z")
                XCTAssertEqual((note["reading"] as? [String: String])?["chapter"], "第一章")
                XCTAssertEqual((note["turns"] as? [[String: String]])?.first?["text"], "问题")
                restoredID.withLock { $0 = id }
                note["revision"] = 1
                let data = try! JSONSerialization.data(withJSONObject: ["note": note])
                return .init(status: 200, body: String(decoding: data, as: UTF8.self))
            default: return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let app = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        app.start()
        try await waitUntil("初始笔记已加载") { !app.syncing && app.notesById["note"] != nil }
        try await app.delete(XCTUnwrap(app.notesById["note"]))
        XCTAssertNil(app.notesById["note"])
        XCTAssertEqual(app.deletedUndoNote?.id, "note")
        await app.undoDelete()
        XCTAssertNil(app.deletedUndoNote)
        let newID = try XCTUnwrap(restoredID.withLock { $0 })
        XCTAssertEqual(app.notesById[newID]?.reading?.bookTitle, "书名")
        XCTAssertNil(app.notesById["note"])
    }

    func testReportHistoryRoutesFollowUpsAndRetainsOriginalRecipe() async throws {
        let summary = InsightReport(id: "report-1", title: "回顾", lensName: "同名视角", content: nil,
                                    excerpt: nil, citations: nil, createdAt: "2025-02-01")
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes": return .init(status: 200, body: notesFixture)
            case "/api/insights/reports/report-1":
                return .init(status: 200, body: #"{"report":{"id":"report-1","title":"回顾","lensId":"exact-lens","lensName":"同名视角","scope":{"range":"custom","tzOffsetMinutes":-480,"tags":["work"],"tagMode":"all","startDate":"2025-02-01","endDate":"2025-02-03"},"useProfile":false,"content":"报告正文","createdAt":"2025-02-01","citations":[]}}"#)
            default: return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let app = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        app.start()
        try await waitUntil("连接完成") { !app.syncing && app.api != nil }
        app.chat.draft = "新会话草稿"
        app.requestViewReport(summary)
        XCTAssertEqual(app.tab, .ai)
        XCTAssertEqual(app.reportRoute, .history(summary.id))
        try await waitUntil("报告详情加载完成") { !app.insights.loadingReport }
        XCTAssertEqual(app.presentedReport?.content, "报告正文")
        let recipe = try XCTUnwrap(app.presentedReportRecipe)
        XCTAssertEqual(recipe.lensId, "exact-lens")
        XCTAssertEqual(recipe.scope.range, "custom")
        XCTAssertEqual(recipe.scope.tags, ["work"])
        XCTAssertEqual(recipe.scope.endDate, "2025-02-03")
        XCTAssertEqual(recipe.useProfile, false)

        app.prepareReportFollowUp()
        XCTAssertEqual(app.chat.insight?.id, summary.id)
        XCTAssertTrue(app.chat.draft.isEmpty)
        app.chat.draft = "报告追问草稿"
        app.requestNewChat()
        XCTAssertNil(app.reportRoute)
        XCTAssertEqual(app.chat.draft, "新会话草稿")
        app.requestViewReport(summary)
        try await waitUntil("重新载入报告") { !app.insights.loadingReport }
        app.prepareReportFollowUp()
        XCTAssertEqual(app.chat.draft, "报告追问草稿")
    }

    func testOpenNoteCapturesSourceBeforeAsyncFetch() async throws {
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/ai/sessions/reader-session": return .init(status: 200, body: readerSessionFixture)
            case "/api/notes":
                let count = fetches.withLock { $0 += 1; return $0 }
                return .init(status: 200, body: count == 1 ? #"{"notes":[],"deleted":[]}"# : notesFixture)
            default: return .init(status: 404, body: "")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let store = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        store.start()
        try await waitUntil("完成初始同步") { !store.syncing }
        try await loadReaderSession(in: store, api: XCTUnwrap(store.api))
        XCTAssertNil(store.notesById["note"])
        store.tab = .notes
        await store.openNote("note", from: .ai)

        let detail = try XCTUnwrap(store.detail)
        XCTAssertEqual(fetches.withLock { $0 }, 2)
        XCTAssertEqual(detail.id, "note")
        XCTAssertEqual(detail.source, .ai)
        store.performReaderPrimaryAction(for: detail.note, source: detail.source)
        XCTAssertEqual(store.chat.pins, ["note"])
        XCTAssertEqual(store.chat.session?.id, "reader-session")
        XCTAssertEqual(store.tab, .notes)
        XCTAssertEqual(store.detail?.id, detail.id)
    }

    func testOpenTagClearsQueryAndSwitchesToNotesFilter() throws {
        let store = AppStore(temporary: true, reset: true)
        let note = Note(id: "note", body: "#Work/职场", createdAt: "2026-11-25", revision: 1)
        store.tab = .ai
        store.detail = .init(note: note, source: .ai)
        store.query = "旧搜索"
        store.filter = NoteFilter(day: "2026-11-25")

        store.openTag("Work/职场")

        XCTAssertNil(store.detail)
        XCTAssertEqual(store.tab, .notes)
        XCTAssertEqual(store.filter, NoteFilter(tag: "work/职场"))
        XCTAssertEqual(store.query, "")
    }

    func testReaderPrimaryActionFromAIPinsWithoutResettingSessionAndRespectsLimit() async throws {
        let (config, transport) = try StubProtocol.make { request in
            XCTAssertEqual(request.url?.path, "/api/ai/sessions/reader-session")
            return .init(status: 200, body: readerSessionFixture)
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let store = AppStore(temporary: true, reset: true)
        // AI references also work without a live AppStore connection.
        try await loadReaderSession(in: store, api: WeijiAPIClient(configuration: config, transport: transport))
        store.tab = .ai
        store.chat.draft = "继续追问"
        let note = Note(id: "note", body: "正文", createdAt: "2026-11-25", revision: 1)
        func toggleReaderPin() {
            store.detail = .init(note: note, source: .ai)
            store.performReaderPrimaryAction(for: note, source: .ai)
            XCTAssertEqual(store.chat.session?.id, "reader-session")
            XCTAssertEqual(store.chat.session?.version, 7)
            XCTAssertEqual(store.chat.draft, "继续追问")
            XCTAssertEqual(store.tab, .ai)
            XCTAssertEqual(store.detail?.id, note.id)
        }

        XCTAssertTrue(store.canPerformReaderPrimaryAction(for: note.id, source: .ai))
        toggleReaderPin()
        XCTAssertEqual(store.chat.pins, [note.id])
        toggleReaderPin()
        XCTAssertTrue(store.chat.pins.isEmpty)
        toggleReaderPin()
        for index in 1...9 { store.chat.togglePin("pin-\(index)") }
        XCTAssertEqual(store.chat.pins.count, 10)
        XCTAssertFalse(store.canPerformReaderPrimaryAction(for: "overflow", source: .ai))
        XCTAssertTrue(store.canPerformReaderPrimaryAction(for: note.id, source: .ai))
        toggleReaderPin()
        XCTAssertEqual(store.chat.pins.count, 9)
        XCTAssertFalse(store.chat.pins.contains(note.id))
        XCTAssertTrue(store.canPerformReaderPrimaryAction(for: "overflow", source: .ai))

        store.tab = .notes
        store.detail = .init(note: note, source: .notes)
        XCTAssertFalse(store.canPerformReaderPrimaryAction(for: note.id, source: .notes))
        store.performReaderPrimaryAction(for: note, source: .notes)
        XCTAssertEqual(store.tab, .ai)
        XCTAssertNil(store.detail)
        XCTAssertNil(store.chat.session)
        XCTAssertTrue(store.chat.draft.isEmpty)
        XCTAssertEqual(store.chat.pins, [note.id])
    }

    func testAskAboutNotePinsImmediatelySendsSourceAndPreservesLegacyTurns() async throws {
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let legacyNotes = #"{"notes":[{"id":"note","body":"  1234567890\n  1234567890\t  12345  ","createdAt":"2025-02-01","turns":[{"role":"assistant","text":"旧回答"}],"revision":1}],"deleted":[]}"#
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes": return .init(status: 200, body: legacyNotes)
            case "/api/ai/sessions":
                XCTAssertEqual(request.url?.query, "sourceNoteId=note")
                let first = lookups.withLock { $0 += 1; return $0 == 1 }
                return .init(status: 200, body: first ? #"{"session":null}"# : sourceSessionFixture)
            case "/api/ai/chat":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = jsonBody(request)
                XCTAssertEqual(body?["sourceNoteId"] as? String, "note")
                XCTAssertEqual(body?["referencedNoteIds"] as? [String], ["note"])
                return .init(status: 200, body: "event: done\ndata: \(sourceSessionFixture)\n\n",
                             headers: ["Content-Type": "text/event-stream"])
            default: return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let store = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        store.start()
        try await waitUntil("同步旧笔记") { !store.syncing && store.notesById["note"] != nil }
        let api = try XCTUnwrap(store.api)
        let note = try XCTUnwrap(store.notesById["note"])
        let chat = store.chat
        func displayed() -> [String]? {
            AIChatView.displayedTurns(session: chat.session, loadingSession: chat.loadingSession,
                                      sourceNoteId: chat.sourceNoteId, notesById: store.notesById)?.map(\.text)
        }
        store.askAbout(note)
        XCTAssertEqual(chat.pins, [note.id])
        XCTAssertEqual(chat.sourceNoteId, note.id)
        XCTAssertTrue(chat.loadingSession)
        XCTAssertNil(displayed())
        try await waitUntil("旧笔记无正式会话") { !chat.loadingSession }
        XCTAssertNil(chat.session)
        XCTAssertEqual(displayed(), ["旧回答"])
        XCTAssertEqual(AIChatView.pinChipTitle(for: note), "1234567890 1234567890 12")
        let book = Note(id: "book", body: " \n ", createdAt: "2025-02-01", reading: .init(bookTitle: " Silo \n"), revision: 1)
        XCTAssertEqual(AIChatView.pinChipTitle(for: book), "Silo")
        XCTAssertEqual(AIChatView.pinChipTitle(for: nil), "引用笔记")

        chat.draft = "第一问"
        chat.send(api: api, options: store.options, profile: store.insights)
        try await waitUntil("完成首轮对话") { !chat.sending }
        XCTAssertEqual(chat.session?.id, "s1")
        XCTAssertNil(chat.error)
        XCTAssertEqual(displayed(), ["会话回答"])

        store.askAbout(note)
        XCTAssertTrue(chat.loadingSession)
        chat.togglePin(note.id)
        try await waitUntil("来源会话加载完成") { !chat.loadingSession }
        XCTAssertEqual(chat.session?.id, "s1")
        XCTAssertEqual(chat.sourceNoteId, note.id)
        XCTAssertTrue(chat.pins.isEmpty)
    }

    func testHistoryReferenceRestoresUnlessEditedOrDeleted() async throws {
        let sends = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes": return .init(status: 200, body: notesFixture)
            case "/api/ai/sessions/s1": return .init(status: 200, body: sourceSessionFixture)
            case "/api/ai/chat":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = jsonBody(request)
                XCTAssertEqual(body?["sessionId"] as? String, "s1")
                XCTAssertEqual(body?["expectedVersion"] as? Int, 1)
                XCTAssertNil(body?["sourceNoteId"])
                XCTAssertEqual(body?["referencedNoteIds"] as? [String], [])
                if sends.withLock({ $0 += 1; return $0 == 1 }) {
                    return .init(status: 409, body: #"{"error":"版本已更新","current":\#(sourceSessionJSON)}"#)
                }
                return .init(status: 200, body: "event: done\ndata: \(sourceSessionFixture)\n\n",
                             headers: ["Content-Type": "text/event-stream"])
            default: return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let store = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        store.start()
        try await waitUntil("同步可引用笔记") { !store.syncing && store.notesById["note"] != nil }
        await store.openNote("note", from: .notes)
        let note = try XCTUnwrap(store.detail?.note)
        XCTAssertTrue(store.canPerformReaderPrimaryAction(for: note.id, source: .notes))
        XCTAssertTrue(store.canPerformReaderPrimaryAction(for: note.id, source: .ai))
        let api = try XCTUnwrap(store.api)
        let chat = store.chat
        let other = Note(id: "other", body: "另一个引用", createdAt: "2025-02-01", revision: 1)
        await store.applyRecord(.init(note: other, deleted: nil), id: other.id)

        chat.select("s1", api: api)
        XCTAssertTrue(chat.loadingSession)
        chat.togglePin(other.id)
        try await waitUntil("保留手动引用") { !chat.loadingSession }
        XCTAssertEqual(chat.pins, [other.id])
        XCTAssertEqual(chat.sourceNoteId, "note")

        chat.select("s1", api: api)
        try await waitUntil("恢复来源引用") { !chat.loadingSession }
        XCTAssertEqual(chat.pins, ["note"])
        XCTAssertEqual(chat.sourceNoteId, "note")
        await store.applyRecord(nil, id: note.id)
        XCTAssertEqual(store.detail?.id, note.id)
        XCTAssertTrue(chat.pins.isEmpty)
        XCTAssertFalse(store.canPerformReaderPrimaryAction(for: note.id, source: .notes))
        XCTAssertFalse(store.canPerformReaderPrimaryAction(for: note.id, source: .ai))
        XCTAssertNil(chat.sourceNoteId)
        XCTAssertEqual(chat.session?.id, "s1")

        chat.draft = "删除后继续提问"
        chat.send(api: api, options: store.options, profile: store.insights)
        try await waitUntil("收到版本冲突") { !chat.sending }
        XCTAssertEqual(chat.error, "版本已更新")
        XCTAssertNil(chat.sourceNoteId)
        chat.send(api: api, options: store.options, profile: store.insights)
        try await waitUntil("继续原历史对话") { !chat.sending }
        XCTAssertNil(chat.error)
        XCTAssertNil(chat.sourceNoteId)
        XCTAssertEqual(sends.withLock { $0 }, 2)

        chat.select("s1", api: api)
        try await waitUntil("重新打开已删除来源的会话") { !chat.loadingSession }
        XCTAssertEqual(chat.session?.id, "s1")
        XCTAssertTrue(chat.pins.isEmpty)
        XCTAssertNil(chat.sourceNoteId)
    }

    func testHistorySelectionIgnoresSupersededResponseAndChecksSyncState() async throws {
        let (config, fast) = try StubProtocol.make { _ in .init(status: 200, body: sourceSessionFixture) }
        let slowConfig = URLSessionConfiguration.ephemeral
        slowConfig.protocolClasses = [DelayedResponseProtocol.self]
        let slow = URLSession(configuration: slowConfig)
        defer {
            slow.invalidateAndCancel(); fast.invalidateAndCancel(); StubProtocol.remove(config)
            DelayedResponseProtocol.pending.withLock { $0 = nil }
        }
        let fastAPI = WeijiAPIClient(configuration: config, transport: fast)
        let chat = AIChatStore()
        let old = chat.select("s0", api: WeijiAPIClient(configuration: config, transport: slow))
        try await waitUntil("旧会话请求已在途") { DelayedResponseProtocol.pending.withLock { $0 != nil } }
        let finishOld = try XCTUnwrap(DelayedResponseProtocol.pending.withLock { $0 })
        await chat.select("s1", api: fastAPI).value
        finishOld(sourceSessionFixture.replacingOccurrences(of: "s1", with: "s0").replacingOccurrences(of: "note", with: "stale"))
        await old.value
        XCTAssertEqual(chat.session?.id, "s1")
        XCTAssertEqual(chat.sourceNoteId, "note")
        XCTAssertEqual(chat.pins, ["note"], "尚未同步时可引用来源")

        chat.syncValidIds([])
        XCTAssertNil(chat.sourceNoteId)
        XCTAssertTrue(chat.pins.isEmpty)
        chat.start(source: "note", pins: ["note"])
        chat.togglePin("note")
        XCTAssertNil(chat.sourceNoteId)
        XCTAssertTrue(chat.pins.isEmpty)
        chat.select("s1", api: fastAPI)
        try await waitUntil("已同步空集合拦截来源") { !chat.loadingSession }
        XCTAssertNil(chat.sourceNoteId)
        XCTAssertTrue(chat.pins.isEmpty)
        chat.reset()
        chat.start(source: "note", pins: ["note", "another", "another"])
        XCTAssertEqual(chat.sourceNoteId, "note")
        XCTAssertEqual(chat.pins, ["note", "another"])
    }

    private func loadReaderSession(in store: AppStore, api: WeijiAPIClient) async throws {
        store.chat.select("reader-session", api: api)
        try await waitUntil("读取阅读页引用测试会话") { !store.chat.loadingSession }
        XCTAssertEqual(store.chat.session?.id, "reader-session")
    }

    func testFilterDimensionsClearIndependentlyAndSetTitle() {
        var filter = NoteFilter(kind: .reading, tag: "工作", day: "2026-11-25")
        XCTAssertEqual(NoteFilter.Dimension.allCases.compactMap { $0.label(in: filter) },
                       ["读书", "#工作", "2026-11-25"])
        XCTAssertEqual(filter.navigationTitle, "筛选结果")
        filter.clear(.tag)
        XCTAssertEqual(filter, NoteFilter(kind: .reading, day: "2026-11-25"))
        XCTAssertEqual(filter.navigationTitle, "筛选结果")
        filter.clear(.day)
        XCTAssertEqual(filter.navigationTitle, "读书")
        filter.clear(.kind)
        XCTAssertEqual(filter.navigationTitle, "笔记")
        XCTAssertEqual(NoteFilter(tag: "工作").navigationTitle, "#工作")
        XCTAssertEqual(NoteFilter(day: "2026-11-25").navigationTitle, "2026-11-25")
    }

    func testNewAndWalkDraftsStayIsolatedAfterRemovingAllPins() {
        let store = AppStore(temporary: true, reset: true)
        let walk = RelatedNotes(focus: .init(id: "focus", body: "正文", createdAt: "2026-11-25", reading: nil),
                                mode: "test", indexed: 1, total: 1, related: [])
        let note = Note(id: "note", body: "正文", createdAt: "2026-11-25", revision: 1)
        let report = InsightReport(id: "report", title: "洞察", lensName: "回顾", content: "正文",
                                   excerpt: nil, citations: nil, createdAt: "2026-11-25")
        store.chat.draft = "新会话草稿"
        store.askAbout(walk)
        XCTAssertEqual(store.chat.draft, "")
        store.chat.draft = "漫步草稿"
        store.chat.togglePin("focus")
        XCTAssertTrue(store.chat.pins.isEmpty)
        store.requestNewChat()
        XCTAssertEqual(store.chat.draft, "新会话草稿")
        store.askAbout(walk)
        XCTAssertEqual(store.chat.draft, "漫步草稿")
        store.chat.draft = "  \n"
        store.askAbout(note)
        XCTAssertEqual(store.chat.draft, "")
        store.chat.draft = "笔记草稿"
        store.askAbout(report)
        XCTAssertEqual(store.chat.draft, "")
        store.chat.draft = "洞察草稿"
        store.askAbout(walk)
        XCTAssertEqual(store.chat.draft, "")
        store.askAbout(note)
        XCTAssertEqual(store.chat.draft, "笔记草稿")
        store.askAbout(report)
        XCTAssertEqual(store.chat.draft, "洞察草稿")
        store.requestNewChat()
        XCTAssertEqual(store.chat.draft, "新会话草稿")
        store.requestNewChat()
        XCTAssertEqual(store.chat.draft, "")

        store.chat.reset()
        store.askAbout(note)
        XCTAssertEqual(store.chat.draft, "")
        store.askAbout(report)
        XCTAssertEqual(store.chat.draft, "")
    }

    func testSelectRestoresSessionDraftAndLoadDoesNotOverwriteIt() async throws {
        let (config, transport) = try StubProtocol.make { request in
            let id = request.url?.lastPathComponent ?? ""
            return .init(status: 200, body: readerSessionFixture.replacingOccurrences(of: "reader-session", with: id))
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let chat = AIChatStore()
        chat.select("a", api: api)
        chat.draft = "会话 A 草稿"
        chat.select("b", api: api)
        XCTAssertEqual(chat.draft, "")
        chat.draft = "会话 B 草稿"
        chat.select("a", api: api)
        XCTAssertEqual(chat.draft, "会话 A 草稿")
        try await waitUntil("会话 A 已完成加载") { chat.session?.id == "a" }
        XCTAssertEqual(chat.draft, "会话 A 草稿")
        chat.reset()
        chat.select("b", api: api)
        XCTAssertEqual(chat.draft, "")
        try await waitUntil("重置后的会话 B 已完成加载") { chat.session?.id == "b" }
        XCTAssertEqual(chat.draft, "")
    }

    func testSendFromSourceConvergingIntoExistingSessionPreservesTargetDraft() async throws {
        let sendCount = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/ai/sessions/a", "/api/ai/sessions":
                return .init(status: 200, body: readerSessionFixture.replacingOccurrences(of: "reader-session", with: "a"))
            case "/api/ai/chat":
                sendCount.withLock { $0 += 1 }
                return .init(status: 200, body: """
                event: done
                data: {"session":{"id":"a","version":8,"title":"继续聊","origin":"note","updatedAt":"2026-11-25","turns":[{"role":"user","text":"另一条问题"},{"role":"assistant","text":"已回复"}]}}


                """, headers: ["Content-Type": "text/event-stream"])
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "")")
                return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let chat = AIChatStore()
        let profile = InsightsStore()

        // 1. User leaves an unsent draft in historical session A.
        chat.select("a", api: api)
        try await waitUntil("历史会话 A 加载完成") { chat.session?.id == "a" }
        chat.draft = "会话 A 原有未发送草稿"

        // 2. User opens from a note whose source resolves to the same session A and sends another prompt.
        chat.start(source: "note-a")
        chat.loadSource("note-a", api: api)
        try await waitUntil("按来源加载到同一会话 A") { chat.session?.id == "a" && !chat.loadingSession }
        XCTAssertEqual(chat.draft, "")
        chat.draft = "另一条问题"
        chat.send(api: api, options: .init(), profile: profile)
        try await waitUntil("发送完成") { !chat.sending }
        XCTAssertEqual(sendCount.withLock { $0 }, 1)
        XCTAssertEqual(chat.session?.id, "a")
        XCTAssertEqual(chat.draft, "会话 A 原有未发送草稿")

        // 3. Switching away and back to session A preserves the original unsent draft.
        chat.start()
        XCTAssertEqual(chat.draft, "")
        chat.select("a", api: api)
        XCTAssertEqual(chat.draft, "会话 A 原有未发送草稿")

        // 4. Explicitly clearing session A's draft deletes its slot and does not resurrect it.
        chat.draft = ""
        chat.start()
        chat.select("a", api: api)
        try await waitUntil("清空后的会话 A 加载完成") { !chat.loadingSession }
        XCTAssertEqual(chat.draft, "")
    }

    func testInFlightAskAndSessionSwitchRequireConfirmation() async throws {
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes": return .init(status: 200, body: notesFixture)
            case "/api/ai/sessions", "/api/ai/sessions/reader-session":
                return .init(status: 200, body: readerSessionFixture)
            case "/api/ai/sessions/active-session":
                return .init(status: 200, body: readerSessionFixture.replacingOccurrences(of: "reader-session", with: "active-session"))
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "")")
                return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let store = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        store.start()
        try await waitUntil("完成初始同步") { store.api != nil && !store.syncing }
        let api = try XCTUnwrap(store.api)
        let note = try XCTUnwrap(store.notesById["note"])
        let walk = RelatedNotes(focus: .init(id: note.id, body: note.body, createdAt: note.createdAt, reading: nil),
                                mode: "test", indexed: 1, total: 1, related: [])
        let report = InsightReport(id: "report-1", title: "洞察报告", lensName: "回顾", content: "正文",
                                   excerpt: nil, citations: [.init(ref: "1", noteId: note.id, excerpt: "摘录")],
                                   createdAt: "2026-11-25")

        let cases: [(name: String, originTab: AppStore.Tab, setDetail: Bool, trigger: () -> Void, assertConfirmed: () -> Void)] = [
            ("note", .notes, true, { store.askAbout(note) }, {
                XCTAssertNil(store.detail)
                XCTAssertEqual(store.tab, .ai)
                XCTAssertEqual(store.chat.sourceNoteId, note.id)
                XCTAssertEqual(store.chat.session?.id, "reader-session")
            }),
            ("walk", .notes, false, { store.askAbout(walk) }, {
                XCTAssertEqual(store.tab, .ai)
                XCTAssertEqual(store.chat.pins, [note.id])
            }),
            ("report", .notes, false, { store.askAbout(report) }, {
                XCTAssertEqual(store.tab, .ai)
                XCTAssertEqual(store.chat.insight?.id, report.id)
                XCTAssertEqual(store.chat.pins, [note.id])
            }),
            ("session", .notes, false, { store.requestSelectChatSession("reader-session") }, {
                XCTAssertEqual(store.tab, .ai)
                XCTAssertEqual(store.chat.session?.id, "reader-session")
            }),
            ("new", .ai, false, { store.requestNewChat() }, {
                XCTAssertEqual(store.tab, .ai)
                XCTAssertNil(store.chat.session)
            }),
        ]

        await store.chat.select("active-session", api: api).value
        XCTAssertEqual(store.chat.session?.id, "active-session")
        for item in cases {
            store.tab = item.originTab
            store.detail = item.setDetail ? .init(note: note, source: .notes) : nil
            let question = "在途提问-\(item.name)"
            store.chat.draft = question
            store.chat.send(api: api, options: .init(), profile: store.insights)
            XCTAssertTrue(store.chat.sending, "\(item.name): stream should be active")

            item.trigger()
            XCTAssertNotNil(store.pendingChatSwitch, "\(item.name): must require confirmation while sending")
            XCTAssertTrue(store.chat.sending, "\(item.name): must not stop stream before confirm")
            XCTAssertEqual(store.tab, item.originTab, "\(item.name): must stay on origin tab before confirm")
            if item.setDetail { XCTAssertEqual(store.detail?.id, note.id, "\(item.name): must keep detail open") }

            store.cancelChatSwitch()
            XCTAssertNil(store.pendingChatSwitch, "\(item.name): cancel clears pending switch")
            XCTAssertTrue(store.chat.sending, "\(item.name): cancel keeps stream running")
            XCTAssertEqual(store.tab, item.originTab, "\(item.name): cancel stays on origin tab")
            if item.setDetail { XCTAssertEqual(store.detail?.id, note.id, "\(item.name): cancel keeps detail open") }

            item.trigger()
            XCTAssertNotNil(store.pendingChatSwitch, "\(item.name): re-trigger sets pending switch")
            store.confirmChatSwitch()
            XCTAssertNil(store.pendingChatSwitch, "\(item.name): confirm clears pending switch")
            XCTAssertFalse(store.chat.sending, "\(item.name): confirm stops previous stream")
            try await waitUntil("\(item.name): 会话加载完成") { !store.chat.loadingSession }
            item.assertConfirmed()
            XCTAssertEqual(store.chat.draft, "", "\(item.name): interrupted draft stays out of the target")

            store.requestSelectChatSession("active-session")
            try await waitUntil("\(item.name): 返回原会话") { !store.chat.loadingSession }
            XCTAssertEqual(store.chat.session?.id, "active-session")
            XCTAssertEqual(store.chat.draft, question, "\(item.name): restore the interrupted question in its original context")
        }
    }

    func testDeletingPendingChatNoteKeepsTheOriginalStreamAndReader() async throws {
        let requested = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes": return .init(status: 200, body: notesFixture)
            case "/api/ai/chat":
                requested.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 8)
                return .init(status: 200, body: "event: done\ndata: \(readerSessionFixture)\n\n",
                             headers: ["Content-Type": "text/event-stream"])
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "")")
                return .init(status: 404, body: "{}")
            }
        }
        let store = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        defer {
            store.chat.stop()
            release.signal()
            transport.invalidateAndCancel()
            StubProtocol.remove(config)
        }
        store.start()
        try await waitUntil("完成初始同步") { store.api != nil && !store.syncing }
        let api = try XCTUnwrap(store.api)
        let note = try XCTUnwrap(store.notesById["note"])
        store.tab = .notes
        store.detail = .init(note: note, source: .notes)
        store.chat.draft = "正在发送"
        store.chat.send(api: api, options: .init(), profile: store.insights)
        try await waitUntil("原对话请求已在途") { requested.withLock { $0 } }

        store.askAbout(note)
        guard case .note(let pending) = store.pendingChatSwitch else { return XCTFail("Expected pending note") }
        XCTAssertEqual(pending.id, note.id)

        await store.applyRecord(nil, id: note.id)
        XCTAssertNil(store.pendingChatSwitch)
        XCTAssertTrue(store.chat.sending)
        XCTAssertEqual(store.detail?.id, note.id)
        XCTAssertEqual(store.tab, .notes)

        store.confirmChatSwitch()
        XCTAssertTrue(store.chat.sending)
        XCTAssertEqual(store.detail?.id, note.id)
        XCTAssertEqual(store.tab, .notes)

        store.askAbout(note)
        XCTAssertNil(store.pendingChatSwitch, "A deleted note cannot reopen confirmation")
    }

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
                let turns: [[String: Any]] = persisted.withLock { messages in
                    messages.flatMap { [
                        ["role": "user", "text": $0],
                        ["role": "assistant", "text": "回复", "steps": [["id": "retrieve", "kind": "retrieve",
                                                                        "label": "检索笔记", "durationMs": 120]]],
                    ] }
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

        func send(model: String = "model-a", effort: String = "") async throws {
            chat.send(api: client, options: AIOptions(provider: .codex, model: model, reasoningEffort: effort), profile: profile)
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
        XCTAssertEqual(chat.session?.turns?.last?.steps?.first?.durationMs, 120)
        XCTAssertTrue(chat.liveSteps.isEmpty)
        XCTAssertTrue(chat.liveCitations.isEmpty)
        XCTAssertTrue(chat.liveReasoning.isEmpty)
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
        try await send(model: "model-b", effort: "high")

        let requests = wire.withLock { $0 }
        XCTAssertEqual(requests.map(\.version), [1, 1, 2, 2, 2, 3, 3, 3])
        XCTAssertEqual(requests.map(\.message), ["原始问题", "原始问题", "下一问", "修改后的问题", "修改后的问题", "修改后的问题", "修改后的问题", "修改后的问题"])
        XCTAssertEqual(requests.map(\.pins), [["ref"], ["ref"], ["ref"], ["ref"], ["ref", "second"], ["ref", "second"], ["ref", "second"], ["ref", "second"]])
        if requests.count == 8 {
            XCTAssertTrue(requests.allSatisfy { UUID(uuidString: $0.id) != nil })
            XCTAssertEqual(requests[0].id, requests[1].id)
            XCTAssertEqual(Set(requests.dropFirst().map(\.id)).count, 7)
            XCTAssertEqual(requests[5].model, "model-a")
            XCTAssertEqual(requests[6].model, "model-b")
            XCTAssertEqual(requests[5].otherFields, requests[6].otherFields)
            XCTAssertNotEqual(requests[5].id, requests[6].id, "Changing only the POST model must change its request ID")
            XCTAssertNotEqual(requests[6].id, requests[7].id, "Changing only the effort must change its request ID")
            let effortFields = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[7].otherFields) as? [String: Any])
            XCTAssertEqual(effortFields["reasoningEffort"] as? String, "high")
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
            ("reasoningEffort", { $0.reasoningEffort = "high" }),
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
            XCTAssertNil(store.settingsSection)
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
            XCTAssertNil(store.settingsSection)
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
        XCTAssertNil(offline.settingsSection)
        XCTAssertNil(offline.api)
        XCTAssertNil(offline.identity)
        XCTAssertEqual(offline.notesById["note"]?.body, "原始版本")
        try await waitUntil("离线列表可浏览") { offline.results.map(\.id) == ["note"] }

        let changed = try ServerConfiguration(address: config.origin, token: "different-token")
        func assertIsolated(_ store: AppStore) {
            XCTAssertEqual(store.authScreenState, .needsLogin)
            XCTAssertNil(store.settingsSection)
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

    func testLegacySnapshotOpensOfflineThenFetchesUnconditionally() async throws {
        let online = OSAllocatedUnfairLock(initialState: false)
        let (config, transport) = try StubProtocol.make { request in
            if !online.withLock({ $0 }) { return .init(status: 0, body: "", failure: .notConnectedToInternet) }
            if request.url?.path == "/api/session" { return .init(status: 200, body: sessionFixture) }
            XCTAssertEqual(request.url?.path, "/api/notes")
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            return .init(status: 200, body: notesFixture, headers: ["ETag": #""from-server""#])
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = NoteCacheStore(directory: directory)
        let key = NoteCacheStore.Key(origin: config.origin, userId: "account")
        defer {
            transport.invalidateAndCancel(); StubProtocol.remove(config)
            try? FileManager.default.removeItem(at: directory)
        }
        try await cache.bind(config, userId: key.userId)
        let legacy = Note(id: "legacy", body: "离线旧快照", createdAt: "2025-02-01T00:00:00Z", revision: 1)
        try JSONEncoder().encode([legacy]).write(to: directory.appending(path: key.filename))
        let old = try await cache.loadSnapshot(key)
        XCTAssertEqual(old?.notes.map(\.id), [legacy.id])
        XCTAssertNil(old?.etag)

        let store = AppStore(initial: config, temporary: true, cache: cache, makeTransport: StubProtocol.transport)
        store.start()
        try await waitUntil("旧版离线笔记") { !store.syncing && store.results.first?.id == legacy.id }
        XCTAssertTrue(store.isOffline)
        online.withLock { $0 = true }
        store.refresh()
        try await waitUntil("在线笔记") { !store.syncing && store.results.first?.id == "note" }
        let updated = try await cache.loadSnapshot(key)
        XCTAssertEqual(updated?.notes.map(\.id), ["note"])
        XCTAssertEqual(updated?.etag, #""from-server""#)
    }

    func testMatched304SkipsIndexAndValidatorIsClearedOnChangesAndAuthRejection() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [String?]())
        let searches = OSAllocatedUnfairLock(initialState: 0)
        let rejection = OSAllocatedUnfairLock(initialState: 0)
        let tag = #""server-v2""#
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes" where request.httpMethod == "POST":
                return .init(status: 200, body: #"{"note":{"id":"note","body":"本地编辑","createdAt":"2025-02-01T00:00:00Z","turns":[],"revision":3}}"#)
            case "/api/admin/obsidian/sync":
                return .init(status: 200, body: #"{"ok":true,"stats":{"scanned":1,"fetched":1,"created":0,"updated":1,"skipped":0,"excluded":0,"conflicts":0},"status":{"configured":true}}"#)
            case "/api/notes":
                let supplied = request.value(forHTTPHeaderField: "If-None-Match")
                requests.withLock { $0.append(supplied) }
                let status = rejection.withLock { $0 }
                if status != 0 { return .init(status: status, body: "Rejected") }
                if supplied != nil { return .init(status: 304, body: "") }
                return .init(status: 200, body: notesFixture, headers: ["ETag": tag])
            default: return .init(status: 404, body: "")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = NoteCacheStore(directory: directory)
        let key = NoteCacheStore.Key(origin: config.origin, userId: "account")
        defer {
            transport.invalidateAndCancel(); StubProtocol.remove(config)
            try? FileManager.default.removeItem(at: directory)
        }
        let note = Note(id: "note", body: "已缓存", createdAt: "2025-02-01T00:00:00Z", revision: 2)
        try await cache.save([note], etag: tag, for: key)
        try await cache.bind(config, userId: key.userId)
        let store = AppStore(initial: config, temporary: true, cache: cache, makeTransport: StubProtocol.transport,
                             runSearch: { index, query, filter in
                                 searches.withLock { $0 += 1 }
                                 return index.search(query, filter: filter)
                             })
        store.start()
        try await waitUntil("缓存命中 304") { !store.syncing && store.identity != nil }
        await store.searchTask?.value
        XCTAssertEqual(store.results.first?.body, note.body)
        XCTAssertEqual(searches.withLock { $0 }, 1, "304 must not schedule another index search")
        XCTAssertEqual(requests.withLock { $0 }, [tag])

        try await store.update(note, body: "本地编辑")
        let mutated = try await cache.loadSnapshot(key)
        XCTAssertNil(mutated?.etag)
        XCTAssertEqual(mutated?.notes.first?.body, "本地编辑")
        store.refresh()
        try await waitUntil("写入后刷新") { !store.syncing }
        XCTAssertEqual(requests.withLock { $0 }, [tag, nil])

        let api = try XCTUnwrap(store.api)
        _ = try await api.triggerObsidianSync()
        store.refresh()
        try await waitUntil("Obsidian 同步后刷新") { !store.syncing }
        XCTAssertEqual(requests.withLock { $0 }, [tag, nil, nil])

        let changed = try ServerConfiguration(address: config.origin, token: "changed-token")
        store.connect(changed, save: false)
        try await waitUntil("同一账号更换凭据后连接") { !store.syncing && store.identity != nil }
        XCTAssertEqual(requests.withLock { $0 }, [tag, nil, nil, nil])

        for status in [401, 403] {
            rejection.withLock { $0 = status }
            store.refresh()
            try await waitUntil("拒绝后清除可见笔记") { !store.syncing && store.identity == nil }
            XCTAssertTrue(store.notesById.isEmpty)
            XCTAssertTrue(store.results.isEmpty)
            let erased = try await cache.loadSnapshot(key)
            let offline = try await cache.loadOfflineSnapshot(changed)
            XCTAssertNil(erased)
            XCTAssertNil(offline)

            rejection.withLock { $0 = 0 }
            store.connect(changed, save: false)
            try await waitUntil("重新登录") { !store.syncing && store.identity != nil }
        }
        XCTAssertEqual(requests.withLock { $0 }, [tag, nil, nil, nil, tag, nil, tag, nil])
    }

    func testEmptyValidSnapshotStillReusesETagFor304() async throws {
        let suppliedTags = OSAllocatedUnfairLock(initialState: [String?]())
        let emptyTag = #""empty-snapshot-v1""#
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes":
                let tag = request.value(forHTTPHeaderField: "If-None-Match")
                suppliedTags.withLock { $0.append(tag) }
                if tag == emptyTag { return .init(status: 304, body: "", headers: ["ETag": emptyTag]) }
                return .init(status: 200, body: #"{"notes":[],"deleted":[]}"#, headers: ["ETag": emptyTag])
            default: return .init(status: 404, body: "")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = NoteCacheStore(directory: directory)
        let key = NoteCacheStore.Key(origin: config.origin, userId: "account")
        defer {
            transport.invalidateAndCancel(); StubProtocol.remove(config)
            try? FileManager.default.removeItem(at: directory)
        }
        try await cache.save([], etag: emptyTag, for: key)
        try await cache.bind(config, userId: key.userId)
        let store = AppStore(initial: config, temporary: true, cache: cache, makeTransport: StubProtocol.transport)
        store.start()
        try await waitUntil("空快照复用 ETag 命中 304") { !store.syncing && store.identity != nil }
        XCTAssertNil(store.error)
        XCTAssertTrue(store.notesById.isEmpty)
        XCTAssertEqual(suppliedTags.withLock { $0 }, [emptyTag])
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
            let searchEntered = OSAllocatedUnfairLock(initialState: false)
            let searchRelease = DispatchSemaphore(value: 0)
            let searchDone = OSAllocatedUnfairLock(initialState: false)
            let cache = NoteCacheStore(directory: directory)
            let key = NoteCacheStore.Key(origin: config.origin, userId: "account")
            try await cache.save([cachedNote], for: key)
            try await cache.bind(config, userId: key.userId)
            let store = AppStore(initial: config, temporary: true, cache: NoteCacheStore(directory: directory),
                                 makeTransport: StubProtocol.transport,
                                 runSearch: { index, query, filter in
                                     if status == 500 && query == "预载" {
                                         searchEntered.withLock { $0 = true }
                                         XCTAssertEqual(searchRelease.wait(timeout: .now() + 8), .success, "旧搜索门闩不得提前超时")
                                         let found = index.search(query, filter: filter)
                                         searchDone.withLock { $0 = true }
                                         return found
                                     }
                                     return index.search(query, filter: filter)
                                 })
            defer { searchRelease.signal() }
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

            var staleSearchTask: Task<Void, Never>?
            if status == 500 {
                store.query = "预载"
                staleSearchTask = store.searchTask
                XCTAssertNotNil(staleSearchTask, "旧搜索任务必须已创建")
                try await waitUntil("旧搜索必须进入在途态") { searchEntered.withLock { $0 } }
            } else if status != 200 {
                store.query = "预载"
            }
            release.signal()
            try await waitUntil("会话完成 HTTP \(status)") { !store.syncing }

            if status == 200 {
                XCTAssertEqual(store.authScreenState, .online)
                XCTAssertFalse(store.isOffline)
                XCTAssertNotNil(store.api)
                try await waitUntil("认证后同步服务器笔记") { store.results.map(\.id) == ["note"] }
            } else {
                XCTAssertEqual(store.authScreenState, .needsLogin)
                XCTAssertNil(store.settingsSection)
                XCTAssertNil(store.api)
                XCTAssertTrue(store.results.isEmpty)
                XCTAssertTrue(store.notesById.isEmpty)
                if status == 500 {
                    // Release the in-flight stale search strictly AFTER 500 cleared state and await the exact MainActor writeback task.
                    searchRelease.signal()
                    await staleSearchTask?.value
                    XCTAssertTrue(searchDone.withLock { $0 }, "旧搜索应已完成计算")
                    XCTAssertTrue(store.results.isEmpty, "晚到旧搜索不得回填 results")
                    XCTAssertTrue(store.notesById.isEmpty)
                }
                let bound = try await cache.loadOffline(config)
                XCTAssertEqual(bound?.map(\.id), status == 500 ? [cachedNote.id] : nil)
            }
        }
    }

    func testOnlineTransitionClearsPreloadedCacheWhenServerReturnsDifferentUser() async throws {
        let cachedNote = Note(id: "old-user-note", body: "旧用户私密笔记", createdAt: "2026-11-23T00:00:00Z", reading: nil, turns: [], revision: 1)
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session":
                return .init(status: 200, body: #"{"user":{"id":"new-user","name":"新用户"},"codexAvailable":false,"authMode":"oauth"}"#)
            case "/api/notes":
                XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
                return .init(status: 500, body: "notes fetch failed")
            default:
                return .init(status: 404, body: "")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            transport.invalidateAndCancel()
            StubProtocol.remove(config)
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = NoteCacheStore(directory: directory)
        let oldKey = NoteCacheStore.Key(origin: config.origin, userId: "old-user")
        try await cache.save([cachedNote], etag: "old-user-etag", for: oldKey)
        try await cache.bind(config, userId: oldKey.userId)
        let store = AppStore(initial: config, temporary: true, cache: NoteCacheStore(directory: directory),
                             makeTransport: StubProtocol.transport)
        store.start()
        try await waitUntil("切换用户连接完成") { !store.syncing }
        XCTAssertEqual(store.authScreenState, .online)
        XCTAssertEqual(store.identity?.user.id, "new-user")
        XCTAssertTrue(store.notesById.isEmpty, "不同用户的预载笔记必须立即清空")
        XCTAssertTrue(store.results.isEmpty)
        let invalidated = try await cache.load(oldKey)
        XCTAssertNil(invalidated, "旧用户缓存应被失效")
    }

    func testWalkPivotUpdatesFocusPreservesHistoryAndPrunesDeletedNotes() async throws {
        let noteJSON: @Sendable (String) -> String = { id in
            #"{"id":"\#(id)","body":"正文","createdAt":"2025-02-01","turns":[],"revision":1}"#
        }
        let relatedJSON: @Sendable (String, [String]) -> String = { focus, ids in
            let related = ids.map { id in
                #"{"id":"\#(id)","score":0.5,"relevancePercent":50,"sharedTags":[],"note":\#(noteJSON(id))}"#
            }.joined(separator: ",")
            return #"{"focus":\#(noteJSON(focus)),"mode":"lexical","indexed":0,"total":3,"related":[\#(related)]}"#
        }
        let remoteIds = OSAllocatedUnfairLock(initialState: ["a", "b", "c"])
        let (config, fastTransport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session": return .init(status: 200, body: sessionFixture)
            case "/api/notes":
                let notes = remoteIds.withLock { $0.map(noteJSON).joined(separator: ",") }
                return .init(status: 200, body: #"{"notes":[\#(notes)],"deleted":[]}"#)
            case let path? where path.hasSuffix("/related"):
                XCTAssertEqual(request.url?.query, "limit=10")
                let id = String(path.split(separator: "/")[2])
                return .init(status: 200, body: relatedJSON(id, ["a", "b", "c", "stale"].filter { $0 != id }))
            default:
                XCTFail("Unexpected Walk request")
                return .init(status: 404, body: "{}")
            }
        }
        defer { fastTransport.invalidateAndCancel(); StubProtocol.remove(config) }
        let app = AppStore(initial: config, temporary: true, reset: true, makeTransport: StubProtocol.transport)
        app.start()
        try await waitUntil("完成初始同步") { !app.syncing && app.notesById.count == 3 }
        let api = try XCTUnwrap(app.api)
        let walk = app.walk
        walk.shuffle(notes: [try XCTUnwrap(app.notesById["a"])], api: api)
        try await waitUntil("漫步聚焦 A") { !walk.loading }
        XCTAssertEqual(walk.result?.focus.id, "a")
        XCTAssertEqual(walk.result?.related.map(\.id), ["b", "c"])
        walk.pivot(to: "b", api: api)
        try await waitUntil("切换焦点至 B") { !walk.loading }
        XCTAssertEqual(walk.result?.focus.id, "b")
        XCTAssertEqual(walk.previousFocus?.id, "a")
        walk.previous()
        XCTAssertEqual(walk.result?.focus.id, "a")

        // 1. Out-of-order response: slow B starts first, fast C finishes first, then B completes and must not overwrite C.
        do {
            let transportConfig = URLSessionConfiguration.ephemeral
            transportConfig.protocolClasses = [DelayedResponseProtocol.self]
            let transport = URLSession(configuration: transportConfig)
            defer { transport.invalidateAndCancel(); DelayedResponseProtocol.pending.withLock { $0 = nil } }
            let slowBTask = try XCTUnwrap(walk.pivot(to: "b", api: WeijiAPIClient(configuration: config, transport: transport)))
            try await waitUntil("慢 B 请求已在途") { DelayedResponseProtocol.pending.withLock { $0 != nil } }
            let finishSlowB = try XCTUnwrap(DelayedResponseProtocol.pending.withLock { $0 })
            let fastCTask = try XCTUnwrap(walk.pivot(to: "c", api: api))
            await fastCTask.value
            XCTAssertEqual(walk.result?.focus.id, "c")
            XCTAssertEqual(walk.previousFocus?.id, "a")
            finishSlowB(relatedJSON("b", ["a", "c"]))
            await slowBTask.value
            XCTAssertEqual(walk.result?.focus.id, "c")
            XCTAssertEqual(walk.previousFocus?.id, "a")
            XCTAssertNil(walk.error)
        }

        // 2. In-flight deletion: request B is deleted before its response arrives; late response must be discarded.
        do {
            let transportConfig = URLSessionConfiguration.ephemeral
            transportConfig.protocolClasses = [DelayedResponseProtocol.self]
            let transport = URLSession(configuration: transportConfig)
            defer { transport.invalidateAndCancel(); DelayedResponseProtocol.pending.withLock { $0 = nil } }
            let slowDeletedTask = try XCTUnwrap(walk.pivot(to: "b", api: WeijiAPIClient(configuration: config, transport: transport)))
            try await waitUntil("待删 B 请求已在途") { DelayedResponseProtocol.pending.withLock { $0 != nil } }
            let finishDeletedB = try XCTUnwrap(DelayedResponseProtocol.pending.withLock { $0 })
            await app.applyRecord(nil, id: "b")
            XCTAssertNil(app.notesById["b"])
            XCTAssertEqual(walk.result?.related.map(\.id), ["a"])
            finishDeletedB(relatedJSON("b", ["a", "c"]))
            await slowDeletedTask.value
            XCTAssertEqual(walk.result?.focus.id, "c")
            XCTAssertEqual(walk.previousFocus?.id, "a")
            XCTAssertNil(walk.error)
        }

        remoteIds.withLock { $0 = ["a"] }
        app.refresh()
        try await waitUntil("远端同步删除焦点并回退") { !app.syncing }
        XCTAssertEqual(Set(app.notesById.keys), ["a"])
        XCTAssertEqual(walk.result?.focus.id, "a")
        XCTAssertEqual(walk.result?.related.map(\.id), [])
        XCTAssertNil(walk.previousFocus)
        await app.applyRecord(nil, id: "a")
        XCTAssertNil(walk.result)
    }

    func testWalkBadgesUseOnlyActualTagsAndBookTitles() {
        func badges(_ body: String, shared: [String] = [], book: String? = nil) -> [WalkCardBadge] {
            let note = RelatedNoteSummary(id: "related", body: body, createdAt: "2025-02-01",
                                          reading: book.map { Reading(bookTitle: $0) })
            return WalkCardBadge.badges(for: .init(id: note.id, score: 0.5, relevancePercent: 50, sharedTags: shared, note: note))
        }
        XCTAssertEqual(badges("正文"), [])
        XCTAssertEqual(badges("正文", shared: ["ghost"], book: " \n"), [])
        XCTAssertEqual(badges("#Alpha #Work/架构", shared: ["ghost", " WORK/架构 ", "alpha"]),
                       [.init(text: "#work/架构", kind: .tag(root: "work"))])
        XCTAssertEqual(badges("#Alpha #Work/架构", shared: ["ghost"]), [.init(text: "#alpha", kind: .tag(root: "alpha"))])
        XCTAssertEqual(badges("正文", book: " Silo "), [.init(text: "Silo", kind: .book)])
        XCTAssertEqual(badges("正文 #思考", book: "Dune"), [.init(text: "#思考", kind: .tag(root: "思考")), .init(text: "Dune", kind: .book)])
        XCTAssertEqual(WalkCardBadge.accent(for: .tag(root: "work")), .pine)
        XCTAssertEqual(WalkCardBadge.accent(for: .tag(root: "WORK")), .pine)
        XCTAssertEqual(WalkCardBadge.accent(for: .tag(root: "思考")), .plum)
        XCTAssertEqual(WalkCardBadge.accent(for: .tag(root: "工作")), .indigo)
        XCTAssertEqual(WalkCardBadge.accent(for: .tag(root: "c")), .clay)
        XCTAssertEqual(WalkCardBadge.accent(for: .book), .graphite)
    }

    func testInsightsPrepareRecipeAppliesSuggestedRangeClearsTagsAndFiltersCategories() async throws {
        let builtin = #"{"id":"builtin:week","name":"复盘","description":"描述","prompt":"分析笔记","category":"复盘整理","builtin":true,"suggestedRange":"week"}"#
        let custom = #"{"id":"custom","name":"我的配方","description":"描述","prompt":"分析笔记","category":"自定义","builtin":false,"suggestedRange":"invalid"}"#
        let row = #"{"id":"report","title":"历史洞察","lensName":"复盘","content":"报告正文","createdAt":"2025-02-01"}"#
        let captured = OSAllocatedUnfairLock(initialState: [(path: String, scope: InsightScope)]())
        let deletes = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/insights/lenses"): return .init(status: 200, body: #"{"lenses":[\#(builtin),\#(custom)]}"#)
            case ("GET", "/api/insights/reports"): return .init(status: 200, body: #"{"reports":[]}"#)
            case ("DELETE", "/api/insights/lenses/custom"): return .init(status: 200, body: #"{"deleted":"custom"}"#)
            case ("POST", let path?) where ["/api/insights/preview", "/api/insights/run"].contains(path):
                let body = jsonBody(request)
                if let scope = body?["scope"], let data = try? JSONSerialization.data(withJSONObject: scope),
                   let decoded = try? JSONDecoder().decode(InsightScope.self, from: data) {
                    captured.withLock { $0.append((path, decoded)) }
                } else {
                    XCTFail("Missing encoded insight scope")
                }
                if path == "/api/insights/preview" {
                    return .init(status: 200, body: #"{"noteCount":2,"dayCount":1,"tagCount":1}"#)
                }
                XCTAssertEqual(body?["lensId"] as? String, "builtin:week")
                return .init(status: 200, body: "event: done\ndata: {\"report\":\(row)}\n\n",
                             headers: ["Content-Type": "text/event-stream"])
            case ("DELETE", "/api/insights/reports/report"):
                return deletes.withLock {
                    $0 += 1
                    return $0 == 1 ? .init(status: 500, body: #"{"error":"删除失败"}"#)
                                  : .init(status: 200, body: #"{"deleted":"report"}"#)
                }
            default:
                XCTFail("Unexpected insights request")
                return .init(status: 404, body: "{}")
            }
        }
        defer { transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let insights = InsightsStore()
        await insights.loadLibrary(api: api)
        XCTAssertEqual(InsightsStore.filteredLenses(insights.lenses, category: nil).map(\.id), ["builtin:week", "custom"])
        XCTAssertEqual(InsightsStore.filteredLenses(insights.lenses, category: "复盘整理").map(\.id), ["builtin:week"])
        XCTAssertEqual(InsightsStore.filteredLenses(insights.lenses, category: "我的").map(\.id), ["custom"])
        XCTAssertEqual(InsightsStore.resolvedCategory("我的", for: insights.lenses), "我的")
        insights.prepareRecipe(try XCTUnwrap(insights.lenses.last), api: nil)
        XCTAssertEqual(insights.scope.range, "7d")
        try await insights.deleteLens("custom", api: api)
        XCTAssertNil(InsightsStore.resolvedCategory("我的", for: insights.lenses))
        XCTAssertEqual(InsightsStore.resolvedCategory("复盘整理", for: insights.lenses), "复盘整理")

        insights.scope = InsightScope(range: "custom", tags: ["old"], startDate: "2025-01-01", endDate: "2025-01-02")
        insights.prepareRecipe(try XCTUnwrap(insights.lenses.first), api: api)
        XCTAssertEqual(insights.lensId, "builtin:week")
        let recipeScope = InsightScope(range: "week")
        XCTAssertEqual(insights.scope, recipeScope)
        try await waitUntil("推荐范围预览完成") { insights.stats?.noteCount == 2 }
        XCTAssertEqual(captured.withLock { $0.map(\.scope) }, [recipeScope])

        insights.scope.tags = ["keep"]
        let dates = InsightScope(range: "custom", tags: ["keep"], startDate: "2025-02-02", endDate: "2025-02-02")
        insights.applyCustomDateRange(start: "2025-02-02", end: "2025-02-01", api: api)
        XCTAssertEqual(insights.scope, dates)
        try await waitUntil("自定义范围预览完成") { insights.stats?.noteCount == 2 }
        insights.run(api: api, options: .init())
        try await waitUntil("洞察生成完成") { !insights.running }
        XCTAssertNil(insights.liveReportError)
        XCTAssertEqual(captured.withLock { $0.map(\.path) }, ["/api/insights/preview", "/api/insights/preview", "/api/insights/run"])
        XCTAssertEqual(captured.withLock { $0.map(\.scope) }, [recipeScope, dates, dates])
        let report = try XCTUnwrap(insights.liveReport)
        let failedDelete = await insights.deleteReport(report.id, api: api)
        XCTAssertFalse(failedDelete)
        XCTAssertEqual(insights.liveReport?.id, report.id)
        XCTAssertEqual(insights.reports.map(\.id), [report.id])
        XCTAssertEqual(insights.liveReportError, "删除失败")
        let successfulDelete = await insights.deleteReport(report.id, api: api)
        XCTAssertTrue(successfulDelete)
        XCTAssertNil(insights.liveReport)
        XCTAssertEqual(insights.liveReportText, "")
        XCTAssertTrue(insights.reports.isEmpty)
        XCTAssertNil(insights.liveReportError)
    }

    func testInsightRunContinuesWhileReadingHistoryAndRejectsSecondRun() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldInsightRunProtocol.self]
        let transport = URLSession(configuration: configuration)
        let config = try ServerConfiguration(address: "http://insight-run.example:5173", token: "test-token-123")
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let insights = InsightsStore()
        HeldInsightRunProtocol.state.withLock { $0 = .init() }
        defer {
            transport.invalidateAndCancel()
            HeldInsightRunProtocol.state.withLock { $0.finish = nil }
        }
        let history = InsightReport(id: "saved", title: "历史洞察", lensName: "回顾", content: nil,
                                    excerpt: nil, citations: nil, createdAt: "2026-11-25")

        insights.run(api: api, options: .init())
        try await waitUntil("已发出生成请求") { HeldInsightRunProtocol.state.withLock { $0.finish != nil } }
        insights.openReport(history, api: api)
        XCTAssertTrue(insights.loadingReport)
        try await waitUntil("生成期间可以读取历史") { !insights.loadingReport }
        XCTAssertEqual(insights.viewedReport?.id, "saved")
        XCTAssertEqual(insights.viewedReportText, "历史正文")
        XCTAssertTrue(insights.running)
        XCTAssertNil(insights.liveReport)
        insights.run(api: api, options: .init())
        let finish = HeldInsightRunProtocol.state.withLock { state in
            defer { state.finish = nil }
            return state.finish
        }
        try XCTUnwrap(finish)()
        try await waitUntil("原生成任务正常结束") { !insights.running }
        XCTAssertEqual(HeldInsightRunProtocol.state.withLock { $0.requests }, 1)
        XCTAssertEqual(insights.liveReport?.id, "generated")
        XCTAssertEqual(insights.liveReportText, "生成正文")
        XCTAssertEqual(insights.reports.map(\.id), ["generated"])
        XCTAssertEqual(insights.viewedReport?.id, "saved")

        insights.run(api: api, options: .init())
        try await waitUntil("第二次生成已发出") { HeldInsightRunProtocol.state.withLock { $0.finish != nil } }
        let cancellations = HeldInsightRunProtocol.state.withLock { $0.cancellations }
        insights.stopReport()
        try await waitUntil("显式停止后请求取消") {
            HeldInsightRunProtocol.state.withLock { $0.cancellations > cancellations }
        }
        XCTAssertFalse(insights.running)
        XCTAssertEqual(insights.reports.map(\.id), ["generated"])
        XCTAssertEqual(insights.viewedReport?.id, "saved")
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
        try await waitUntil("读取报告详情") { !store.loadingReport }

        let failedDelete = await store.deleteReport(report.id, api: api)
        XCTAssertFalse(failedDelete)
        XCTAssertEqual(store.reports.map(\.id), [report.id])
        XCTAssertEqual(store.viewedReport?.id, report.id)
        XCTAssertEqual(store.viewedReportText, "报告正文")
        XCTAssertEqual(store.viewedReportError, "删除失败")

        let successfulDelete = await store.deleteReport(report.id, api: api)
        XCTAssertTrue(successfulDelete)
        XCTAssertTrue(store.reports.isEmpty)
        XCTAssertNil(store.viewedReport)
        XCTAssertEqual(store.viewedReportText, "")
        XCTAssertNil(store.viewedReportError)
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
        XCTAssertNil(store.settingsSection)
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
        XCTAssertNil(restarted.settingsSection)
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

    func testGatewayModelPreferencesPersistAndFixedAndPlainModelsClearEffort() async throws {
        let (config, transport) = try StubProtocol.make { request in
            switch request.url?.path {
            case "/api/session":
                return .init(status: 200, body: #"{"user":{"id":"models","name":"Test"},"codexAvailable":true,"codexMode":"gateway"}"#)
            case "/api/notes":
                return .init(status: 200, body: notesFixture)
            case "/api/ai/models":
                return .init(status: 200, body: #"{"models":["gemini-3-flash","gemini-4-neon-xhigh","gpt-4.1-mini"],"defaultModel":"gemini-3-flash"}"#)
            default: return .init(status: 404, body: "")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = NoteCacheStore.Key(origin: config.origin, userId: "models")
        let preferences = "weiji.ai." + key.filename + ".codex"
        defer {
            transport.invalidateAndCancel(); StubProtocol.remove(config)
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removeObject(forKey: preferences + ".model")
            UserDefaults.standard.removeObject(forKey: preferences + ".effort")
        }
        let credentials = KeychainStore(read: { _, _ in nil }, write: { _, _, _ in })
        func connect(temporary: Bool = false) async throws -> AppStore {
            let store = AppStore(initial: config, temporary: temporary, cache: NoteCacheStore(directory: directory),
                                 credentials: credentials, makeTransport: StubProtocol.transport)
            store.start()
            try await waitUntil("模型目录可用") { !store.gatewayModelMeta.isEmpty }
            return store
        }
        let store = try await connect()
        XCTAssertEqual(store.selectedGatewayModel?.id, "gemini-3-flash")
        store.setModel("gemini-3-flash")
        store.setReasoningEffort("high")
        XCTAssertEqual(store.options.reasoningEffort, "high")
        let restarted = try await connect()
        XCTAssertEqual(restarted.options.model, "gemini-3-flash")
        XCTAssertEqual(restarted.options.reasoningEffort, "high")

        let temporary = try await connect(temporary: true)
        XCTAssertEqual(temporary.options.model, "")
        XCTAssertEqual(temporary.options.reasoningEffort, "")
        temporary.setReasoningEffort("low")
        XCTAssertEqual(UserDefaults.standard.string(forKey: preferences + ".effort"), "high")

        restarted.setModel("gemini-4-neon-xhigh")
        restarted.setReasoningEffort("xhigh")
        XCTAssertEqual(restarted.selectedGatewayModel?.fixedEffort, "xhigh")
        XCTAssertEqual(restarted.options.reasoningEffort, "")
        restarted.setModel("gemini-3-flash")
        restarted.setReasoningEffort("medium")
        restarted.setModel("gpt-4.1-mini")
        XCTAssertFalse(restarted.selectedGatewayModel?.thinking == true)
        XCTAssertEqual(restarted.options.reasoningEffort, "")
        let unknownThinking = ModelMeta.inferred(from: "custom-thinking-preview")
        XCTAssertFalse(unknownThinking.thinking)
        XCTAssertTrue(unknownThinking.efforts.isEmpty)
        let unknownVersion = ModelMeta.inferred(from: "gpt-6.99-chat-thinking")
        XCTAssertFalse(unknownVersion.thinking)
        XCTAssertTrue(unknownVersion.efforts.isEmpty)
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

    func testLiveStepsCitationsAndTextCoalesceThenClearOnDone() async throws {
        let release = DispatchSemaphore(value: 0)
        let (config, transport) = try StubProtocol.make { _ in
            _ = release.wait(timeout: .now() + 8)
            return .init(status: 200, body: """
            event: done
            data: {"session":{"id":"chat","version":1,"title":"对话","origin":"chat","updatedAt":"2026-11-24","turns":[{"role":"assistant","text":"回答","steps":[{"id":"retrieve","kind":"retrieve","label":"检索","status":"done"}]}]}}


            """, headers: ["Content-Type": "text/event-stream"])
        }
        defer { release.signal(); transport.invalidateAndCancel(); StubProtocol.remove(config) }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let chat = AIChatStore()
        chat.draft = "问题"
        chat.send(api: api, options: .init(), profile: InsightsStore())
        func emit(_ event: String, _ data: String) { chat.receive(.init(event: event, data: data), generation: 1) }
        emit("step", #"{"id":"retrieve","kind":"retrieve","status":"running","label":"检索"}"#)
        emit("step", #"{"id":"think","kind":"think","status":"running","label":"思考"}"#)
        emit("step", #"{"id":"retrieve","kind":"retrieve","status":"done","label":"检索","durationMs":120,"items":[{"ref":"N1","noteId":"a","title":"笔记","excerpt":"段落"}]}"#)
        emit("citations", #"{"citations":[{"ref":"N1","noteId":"a","excerpt":"段落"}]}"#)
        emit("status", #"{"stage":"generating","message":"兼容旧提示"}"#)
        emit("delta", #"{"text":"答"}"#)
        emit("delta", #"{"text":"案"}"#)
        emit("reasoning", #"{"text":"第一段"}"#)
        emit("reasoning", #"{"text":"第二段"}"#)
        XCTAssertEqual(chat.liveSteps.map(\.id), ["retrieve", "think"])
        XCTAssertEqual(chat.liveSteps.first?.status, "done")
        XCTAssertEqual(chat.liveSteps.first?.items?.first?.excerpt, "段落")
        XCTAssertEqual(chat.liveCitations.map(\.ref), ["N1"])
        XCTAssertEqual(chat.status, "兼容旧提示")
        XCTAssertTrue(chat.streamedText.isEmpty)
        XCTAssertTrue(chat.liveReasoning.isEmpty)
        try await waitUntil("合帧发布文本") { chat.streamedText == "答案" && chat.liveReasoning == "第一段第二段" }
        let oversized = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "思", count: 20_100)])
        emit("reasoning", String(decoding: oversized, as: UTF8.self))
        chat.flushStreaming()
        XCTAssertEqual(chat.liveReasoning.count, 20_000)

        emit("delta", #"{"text":"末尾"}"#)
        emit("done", "{}")
        XCTAssertEqual(chat.streamedText, "答案末尾", "done flushes buffered text synchronously")
        XCTAssertTrue(chat.liveSteps.isEmpty)
        XCTAssertTrue(chat.liveReasoning.isEmpty)
        XCTAssertTrue(chat.liveCitations.isEmpty)
        release.signal()
        try await waitUntil("done 提交会话") { !chat.sending }
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.session?.turns?.last?.steps?.first?.status, "done")
        XCTAssertTrue(chat.streamedText.isEmpty)
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
        chat.flushStreaming()
        XCTAssertEqual(chat.streamedText, "第二轮")
        chat.stop()
        chat.receive(.init(event: "delta", data: #"{"text":"停止后迟到"}"#), generation: 3)
        XCTAssertEqual(chat.streamedText, "")
        XCTAssertEqual(chat.draft, "第二个问题")
    }

    func testChatSendClearsDraftImmediatelyAndRestoresOnlyOnFailure() async throws {
        let release = DispatchSemaphore(value: 0)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            if request.httpMethod == "GET" {
                return .init(status: 200, body: readerSessionFixture.replacingOccurrences(of: "reader-session", with: "chat-clear"))
            }
            let attempt = attempts.withLock { $0 += 1; return $0 }
            _ = release.wait(timeout: .now() + 8)
            if attempt <= 2 {
                return .init(status: 0, body: "", failure: .networkConnectionLost)
            }
            return .init(status: 200, body: """
            event: done
            data: {"session":{"id":"chat-clear","version":1,"title":"测试","origin":"chat","updatedAt":"2026-11-25","turns":[{"role":"user","text":"立即清空测试"},{"role":"assistant","text":"收到"}]}}


            """, headers: ["Content-Type": "text/event-stream"])
        }
        defer {
            for _ in 0..<4 { release.signal() }
            transport.invalidateAndCancel()
            StubProtocol.remove(config)
        }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let chat = AIChatStore()
        let profile = InsightsStore()

        // 1. In-flight clear + restore on failure when user left composer empty.
        let initialResets = chat.composerResetCount
        chat.draft = "立即清空测试"
        chat.send(api: api, options: .init(), profile: profile)
        XCTAssertTrue(chat.sending)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.pendingQuestion, "立即清空测试")
        XCTAssertEqual(chat.composerResetCount, initialResets + 1)
        release.signal()
        try await waitUntil("首次失败恢复草稿") { !chat.sending }
        XCTAssertEqual(chat.draft, "立即清空测试")
        XCTAssertTrue(chat.error?.contains("-1005") == true)

        // 2. If user types a follow-up while in flight, failure must preserve it instead of overwriting.
        chat.send(api: api, options: .init(), profile: profile)
        XCTAssertTrue(chat.sending)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.composerResetCount, initialResets + 2)
        chat.draft = "追问"
        release.signal()
        try await waitUntil("带新草稿失败") { !chat.sending }
        XCTAssertEqual(chat.draft, "追问")

        // 3. Clean success keeps draft empty.
        chat.start(source: "source")
        chat.draft = "立即清空测试"
        chat.send(api: api, options: .init(), profile: profile)
        XCTAssertTrue(chat.sending)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.composerResetCount, initialResets + 3)
        release.signal()
        try await waitUntil("发送成功保持清空") { !chat.sending }
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.pendingQuestion, "")
        XCTAssertEqual(chat.session?.id, "chat-clear")
        chat.draft = "成功后的追问"
        chat.start(source: "source")
        XCTAssertEqual(chat.draft, "")
        chat.select("chat-clear", api: api)
        try await waitUntil("新会话完成加载") { chat.session?.id == "chat-clear" }
        XCTAssertEqual(chat.draft, "成功后的追问")
    }

    func testStopThenResendReusesClientRequestIDAndEditRotatesIt() async throws {
        let releaseFirst = DispatchSemaphore(value: 0)
        let requestIDs = OSAllocatedUnfairLock(initialState: [String]())
        let (config, transport) = try StubProtocol.make { request in
            let body = jsonBody(request)
            let clientId = body?["clientRequestId"] as? String ?? ""
            let index = requestIDs.withLock { ids -> Int in
                ids.append(clientId)
                return ids.count
            }
            if index == 1 {
                _ = releaseFirst.wait(timeout: .now() + 8)
            }
            return .init(status: 200, body: """
            event: done
            data: {"session":{"id":"chat-stop","version":1,"title":"测试","origin":"chat","updatedAt":"2026-11-25","turns":[{"role":"user","text":"停止后重试"},{"role":"assistant","text":"收到"}]}}


            """, headers: ["Content-Type": "text/event-stream"])
        }
        defer {
            releaseFirst.signal()
            transport.invalidateAndCancel()
            StubProtocol.remove(config)
        }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let chat = AIChatStore()
        let profile = InsightsStore()

        // 1. Send, hold upstream response, stop mid-flight -> draft restored
        chat.draft = "停止后重试"
        chat.send(api: api, options: .init(), profile: profile)
        try await waitUntil("首轮请求到达服务端") { requestIDs.withLock { !$0.isEmpty } }
        chat.stop()
        XCTAssertFalse(chat.sending)
        XCTAssertEqual(chat.draft, "停止后重试")
        releaseFirst.signal()

        // 2. Resend identical restored draft -> MUST reuse exact same clientRequestId
        chat.send(api: api, options: .init(), profile: profile)
        try await waitUntil("停止后原样重发完成") { !chat.sending }
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.draft, "")

        // 3. New send with edited text after stop -> rotates to a fresh clientRequestId
        chat.start()
        chat.draft = "修改后的问题"
        chat.send(api: api, options: .init(), profile: profile)
        try await waitUntil("修改文案发送完成") { !chat.sending }

        let captured = requestIDs.withLock { $0 }
        XCTAssertEqual(captured.count, 3)
        XCTAssertFalse(captured[0].isEmpty)
        XCTAssertEqual(captured[0], captured[1], "Stop followed by identical resend must preserve clientRequestId")
        XCTAssertNotEqual(captured[1], captured[2], "Fresh/edited request must generate a new clientRequestId")
    }

    func testReaderStackSkipsDeletedNotesAndPrunesTombstones() {
        let noteA = Note(id: "note-a", body: "正文 A", createdAt: "2026-11-26T00:00:00Z", revision: 1)
        let noteB = Note(id: "note-b", body: "正文 B", createdAt: "2026-11-27T00:00:00Z", revision: 1)
        let noteC = Note(id: "note-c", body: "正文 C", createdAt: "2026-11-28T00:00:00Z", revision: 1)
        var stack = NoteReaderStack()
        stack.push(noteA.id)
        stack.push(noteB.id)
        stack.push(noteC.id)

        // Delete B and C remotely; only A remains live.
        let afterDelete = [noteA.id: noteA]
        XCTAssertTrue(stack.hasLiveEntry(in: afterDelete))
        XCTAssertEqual(stack.popLive(in: afterDelete)?.id, noteA.id)
        XCTAssertFalse(stack.hasLiveEntry(in: afterDelete))
        XCTAssertNil(stack.popLive(in: afterDelete))

        stack.push(noteB.id)
        stack.prune(using: afterDelete)
        XCTAssertTrue(stack.ids.isEmpty)
    }

    func testRemoveBlocksDeletingActiveStreamingSession() async throws {
        let release = DispatchSemaphore(value: 0)
        let deleteRequests = OSAllocatedUnfairLock(initialState: 0)
        let (config, transport) = try StubProtocol.make { request in
            if request.httpMethod == "DELETE" {
                deleteRequests.withLock { $0 += 1 }
                return .init(status: 200, body: #"{"deleted":true}"#)
            }
            if request.httpMethod == "GET", request.url?.path == "/api/ai/sessions" {
                return .init(status: 200, body: #"{"sessions":[{"id":"stream-1","title":"进行中的会话","version":1,"origin":"chat","updatedAt":"2026-11-28T00:00:00Z"}]}"#)
            }
            if request.httpMethod == "GET", request.url?.path == "/api/ai/sessions/stream-1" {
                return .init(status: 200, body: #"{"session":{"id":"stream-1","title":"进行中的会话","version":1,"origin":"chat","updatedAt":"2026-11-28T00:00:00Z","turns":[{"role":"user","text":"首问"},{"role":"assistant","text":"首答"}]}}"#)
            }
            _ = release.wait(timeout: .now() + 8)
            return .init(status: 200, body: "event: done\ndata: {\"session\":{\"id\":\"stream-1\",\"version\":2,\"title\":\"进行中的会话\",\"origin\":\"chat\",\"updatedAt\":\"2026-11-28T00:00:00Z\",\"turns\":[]}}\n\n",
                         headers: ["Content-Type": "text/event-stream"])
        }
        defer {
            release.signal()
            transport.invalidateAndCancel()
            StubProtocol.remove(config)
        }
        let api = WeijiAPIClient(configuration: config, transport: transport)
        let chat = AIChatStore()
        let profile = InsightsStore()
        chat.refreshSessions(api: api)
        try await waitUntil("加载会话列表") { chat.sessions.count == 1 }
        chat.select("stream-1", api: api)
        try await waitUntil("加载目标会话") { chat.session?.id == "stream-1" }

        chat.draft = "追问中"
        chat.send(api: api, options: .init(), profile: profile)
        XCTAssertTrue(chat.sending)
        XCTAssertFalse(chat.canDeleteSession("stream-1"))

        await chat.remove("stream-1", api: api)
        XCTAssertEqual(deleteRequests.withLock { $0 }, 0, "Active streaming session must not issue DELETE")
        XCTAssertTrue(chat.sending, "Blocked delete must keep stream running")
        XCTAssertEqual(chat.session?.id, "stream-1")
        XCTAssertEqual(chat.sessions.map(\.id), ["stream-1"])

        chat.stop()
        XCTAssertTrue(chat.canDeleteSession("stream-1"))
    }
}

private let readerSessionFixture = #"{"session":{"id":"reader-session","title":"会话","version":7,"updatedAt":"2026-11-25T00:00:00Z","origin":"chat"}}"#
private let sourceSessionJSON = #"{"id":"s1","title":"会话","version":1,"updatedAt":"2025-02-01","origin":"note","sourceNoteId":"note","turns":[{"role":"assistant","text":"会话回答"}]}"#
private let sourceSessionFixture = #"{"session":\#(sourceSessionJSON)}"#

// Hold a response without blocking URLProtocol's shared request queue.
private final class DelayedResponseProtocol: URLProtocol, @unchecked Sendable {
    static let pending = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertTrue(["/api/notes/b/related", "/api/ai/sessions/s0"].contains(url.path))
        Self.pending.withLock { pending in
            pending = { body in
                guard !self.stopped.withLock({ $0 }),
                      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(body.utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}

private final class HeldInsightRunProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var requests = 0
        var cancellations = 0
        var finish: (@Sendable () -> Void)?
    }

    static let state = OSAllocatedUnfairLock(initialState: State())
    private let finished = OSAllocatedUnfairLock(initialState: false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let streaming = url.path == "/api/insights/run"
        if streaming {
            Self.state.withLock { state in
                state.requests += 1
                state.finish = { self.complete(streaming: true, url: url) }
            }
        } else {
            XCTAssertEqual(url.path, "/api/insights/reports/saved")
            complete(streaming: false, url: url)
        }
    }

    private func complete(streaming: Bool, url: URL) {
        let body = streaming
            ? "event: done\ndata: {\"report\":{\"id\":\"generated\",\"title\":\"新洞察\",\"lensName\":\"回顾\",\"content\":\"生成正文\",\"createdAt\":\"2026-11-25\"}}\n\n"
            : #"{"report":{"id":"saved","title":"历史洞察","lensName":"回顾","content":"历史正文","createdAt":"2026-11-25"}}"#
        let headers = ["Content-Type": streaming ? "text/event-stream" : "application/json"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers) else { return }
        finished.withLock { $0 = true }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if request.url?.path == "/api/insights/run", !finished.withLock({ $0 }) {
            Self.state.withLock { $0.cancellations += 1 }
        }
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
