import Foundation
import XCTest
@testable import Weiji

@MainActor
final class WritingStyleTests: XCTestCase {
    private static let style = #"{"rules":"先说结论","anchorNoteIds":["note"],"anchors":[{"id":"note","createdAt":"2026-11-28","excerpt":"原创"}],"missingAnchorCount":0,"scope":{"range":"all","tzOffsetMinutes":0,"tags":[],"tagMode":"any"},"noteCount":12,"updatedAt":"2026-11-28","ready":true}"#
    private static let styleEnvelope = #"{"style":\#(style)}"#
    private static let generated = #"{"style":\#(style),"suggestedAnchors":[{"id":"example","createdAt":"2026-11-27","excerpt":"一句短例"}]}"#
    private static let blind = #"{"source":{"kind":"topic","text":"散步"},"candidates":[{"slot":"A","variant":"styled","text":"甲"},{"slot":"B","variant":"baseline","text":"乙"}]}"#
    private static let session = #"{"id":"history","title":"对话","sourceNoteId":"note","version":1,"updatedAt":"2026-11-28","origin":"note","turns":[]}"#
    private static let history = #"{"session":\#(session)}"#
    private static let initialNotes = #"{"notes":[{"id":"note","body":"原创","createdAt":"2026-11-28","turns":[],"revision":1}],"deleted":[]}"#
    private let stylePath = "/api/ai/writing-style"
    private let generatePath = "/api/ai/writing-style/generate"
    private let blindPath = "/api/ai/writing-style/blind-test"
    private let chatPath = "/api/ai/chat"
    private let sourcePath = "/api/ai/sessions"
    private let historyPath = "/api/ai/sessions/history"

    func testWritingStyleModelsAndOriginalFilter() throws {
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(WritingStyleResponse.self, from: Data(#"{"style":null}"#.utf8)).style)
        let style = try XCTUnwrap(decoder.decode(WritingStyleResponse.self, from: Data(Self.styleEnvelope.utf8)).style)
        XCTAssertEqual(style.rules, "先说结论")
        XCTAssertEqual(style.anchors.first?.excerpt, "原创")
        XCTAssertEqual(style.scope, InsightScope(range: "all", tzOffsetMinutes: 0))
        XCTAssertTrue(style.ready)
        let generated = try decoder.decode(WritingStyleGenerateResponse.self, from: Data(Self.generated.utf8))
        XCTAssertEqual(generated.style.noteCount, 12)
        XCTAssertEqual(generated.suggestedAnchors.map(\.id), ["example"])
        XCTAssertThrowsError(try decoder.decode(WritingStyleGenerateResponse.self, from: Data(#"{"suggestedAnchors":[]}"#.utf8)))
        let topic = try decoder.decode(BlindTestResponse.self, from: Data(Self.blind.utf8))
        XCTAssertEqual(topic.source.kind, "topic")
        XCTAssertEqual(topic.source.text, "散步")
        XCTAssertNil(topic.source.noteId)
        let holdout = try decoder.decode(BlindTestResponse.self, from: Data(#"{"source":{"kind":"note","noteId":"note","text":"留出原创"},"candidates":[]}"#.utf8))
        XCTAssertEqual(holdout.source.kind, "note")
        XCTAssertEqual(holdout.source.noteId, "note")
        XCTAssertEqual(holdout.source.text, "留出原创")
        let edit = try object(WritingStyleEdit(anchorNoteIds: ["note"]))
        XCTAssertEqual(edit.keys.sorted(), ["anchorNoteIds"])
        XCTAssertEqual(edit["anchorNoteIds"] as? [String], ["note"])
        let options = AIOptions(provider: .openai, model: "model", apiKey: "test", reasoningEffort: "high")
        XCTAssertEqual(try object(options.nonStreamingFields) as? [String: String],
                       ["provider": "openai", "model": "model", "apiKey": "test", "reasoningEffort": "high"])
        XCTAssertEqual(try object(options.fields)["stream"] as? Bool, true)

        var note = Note(id: "note", body: "  原创\n", createdAt: "2026-11-28", revision: 1)
        XCTAssertEqual(Note.extractOriginalWriting(from: note), "原创")
        note.body = " \n"
        XCTAssertNil(Note.extractOriginalWriting(from: note))
        note.reading = Reading(bookTitle: "读书")
        note.body = "没注明来源"
        XCTAssertNil(Note.extractOriginalWriting(from: note))
        note.body = " \n\n原文：书摘"
        XCTAssertNil(Note.extractOriginalWriting(from: note))
        note.body = "  我的想法\n\n原文：书摘"
        XCTAssertEqual(Note.extractOriginalWriting(from: note), "我的想法")
    }

    func testWritingStyleStoreStreamCancelBlindTestAndReset() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let api = wire.api()
        let store = InsightsStore()
        wire.reply(stylePath, body: Self.styleEnvelope)
        await store.loadWritingStyle(api: api)
        XCTAssertEqual(store.writingStyleRulesText, "先说结论")

        wire.hold(generatePath)
        store.generateWritingStyle(api: api, options: .init(), isRelayMode: false)
        try await eventually("提炼开始") { wire.waiting(self.generatePath) == 1 }
        XCTAssertEqual(wire.requests(generatePath).last?["stream"] as? Bool, true)
        XCTAssertEqual((wire.requests(generatePath).last?["scope"] as? [String: Any])?["range"] as? String, "all")
        let stream = try XCTUnwrap(wire.take(generatePath))
        stream.begin(stream: true)
        stream.write(Self.sse("status", #"{"message":"正在提炼"}"#) + Self.sse("delta", #"{"text":"部分规则"}"#)
                     + ": " + String(repeating: " ", count: 8192) + "\n\n")
        try await eventually("status 和 delta 实时落态") {
            store.writingStyleStatus == "正在提炼" && store.writingStyleRulesText == "部分规则"
        }
        store.stopWritingStyle()
        XCTAssertFalse(store.generatingWritingStyle)
        XCTAssertEqual(store.writingStyleRulesText, "先说结论")
        XCTAssertNil(store.writingStyleStatus)
        try await eventually("取消底层 SSE") { stream.isStopped }

        wire.reply(generatePath, body: Self.sse("done", Self.generated), stream: true)
        store.generateWritingStyle(api: api, options: .init(), isRelayMode: false)
        try await eventually("生成完成") { !store.generatingWritingStyle }
        XCTAssertEqual(store.writingStyle?.noteCount, 12)
        XCTAssertEqual(store.suggestedAnchors.map(\.id), ["example"])

        wire.reply(blindPath, body: Self.blind)
        store.runBlindTest(api: api, options: .init(), prompt: String(repeating: "字", count: 505), isRelayMode: false)
        try await eventually("盲测完成") { !store.runningBlindTest }
        XCTAssertEqual((wire.requests(blindPath).first?["prompt"] as? String)?.utf16.count, 500)
        XCTAssertNil(wire.requests(blindPath).first?["stream"])
        XCTAssertEqual(store.blindTest?.candidates.map(\.slot), ["A", "B"])
        XCTAssertNil(store.blindTestVote)
        store.voteBlindTest("B")
        XCTAssertEqual(store.blindTestVote, "B")
        XCTAssertEqual(store.blindTest?.candidates.first(where: { $0.slot == "B" })?.variant, "baseline")

        wire.hold(blindPath)
        store.runBlindTest(api: api, options: .init(), prompt: " ", isRelayMode: false)
        try await eventually("留出笔记盲测开始") { wire.waiting(self.blindPath) == 1 }
        XCTAssertNil(wire.requests(blindPath).last?["prompt"])
        let blind = try XCTUnwrap(wire.take(blindPath))
        store.reset()
        try await eventually("重置取消盲测") { blind.isStopped }
        XCTAssertNil(store.writingStyle)
        XCTAssertFalse(store.writingStyleLoaded)
        XCTAssertEqual(store.writingStyleRulesText, "")
        XCTAssertEqual(store.writingStyleScope.range, "all")
        XCTAssertTrue(store.suggestedAnchors.isEmpty)
        XCTAssertFalse(store.loadingWritingStyle || store.savingWritingStyle || store.generatingWritingStyle || store.runningBlindTest)
        XCTAssertNil(store.blindTest)
        XCTAssertNil(store.blindTestVote)
        XCTAssertNil(store.blindTestError)
        XCTAssertNil(store.writingStyleStatus)
        XCTAssertNil(store.writingStyleError)
    }

    func testWritingStyleSaveGuardBlocksFailedAwaitsPendingAndIgnoresStaleGet() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let api = wire.api()
        let insights = InsightsStore()
        let chat = AIChatStore()
        wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
        wire.reply(stylePath, body: #"{"style":null}"#)
        await insights.loadWritingStyle(api: api)
        XCTAssertTrue(insights.writingStyleLoaded)
        wire.hold(stylePath, method: "GET")
        let staleGet = Task { await insights.loadWritingStyle(api: api) }
        try await eventually("旧 GET 已发出") { wire.waiting(self.stylePath, method: "GET") == 1 }
        wire.reply(stylePath, method: "POST", status: 503, body: #"{"error":"保存出错"}"#)
        let failed = try XCTUnwrap(insights.saveWritingStyle(.init(rules: "失败的规则"), api: api))
        let saved = await failed.value
        XCTAssertFalse(saved)
        XCTAssertEqual(insights.writingStyleError, "保存出错")
        let get = try XCTUnwrap(wire.take(stylePath, method: "GET"))
        get.complete(body: Self.styleEnvelope)
        await staleGet.value
        XCTAssertNil(insights.writingStyle)
        XCTAssertEqual(insights.writingStyleError, "保存出错")

        wire.reply(stylePath, body: Self.styleEnvelope)
        await insights.loadWritingStyle(api: api)
        XCTAssertEqual(wire.requests(stylePath, method: "GET").count, 2)
        chat.useWritingStyle = true
        chat.draft = "待发草稿"
        chat.send(api: api, options: .init(), profile: insights)
        try await eventually("失败保存阻断聊天") { !chat.sending }
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
        XCTAssertEqual(chat.draft, "待发草稿")
        XCTAssertEqual(chat.error, "写作风格保存失败。请重新保存写作风格后再发送。")

        insights.reset()
        XCTAssertNil(insights.writingStyleError)
        chat.send(api: api, options: .init(), profile: insights)
        try await eventually("重置后放行") { !chat.sending && wire.requests(self.chatPath).count == 1 }
        XCTAssertNil(chat.error)

        await insights.loadWritingStyle(api: api)
        XCTAssertTrue(insights.writingStyleLoaded)
        wire.hold(stylePath, method: "POST")
        let pending = try XCTUnwrap(insights.saveWritingStyle(.init(rules: "等待的规则"), api: api))
        chat.draft = "等保存再发送"
        chat.useWritingStyle = true
        chat.send(api: api, options: .init(), profile: insights)
        try await eventually("延迟保存已发出") { wire.waiting(self.stylePath, method: "POST") == 1 }
        XCTAssertTrue(chat.sending)
        XCTAssertEqual(wire.requests(chatPath).count, 1)
        try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(body: Self.styleEnvelope)
        let completed = await pending.value
        XCTAssertTrue(completed)
        try await eventually("保存后发送") { !chat.sending && wire.requests(self.chatPath).count == 2 }
        XCTAssertNil(chat.error)

        let resetSave = try XCTUnwrap(insights.saveWritingStyle(.init(rules: "旧账户"), api: api))
        try await eventually("旧账户保存已发出") { wire.waiting(self.stylePath, method: "POST") == 1 }
        var loadingEntered = false
        let loading = Task {
            loadingEntered = true
            await insights.loadWritingStyle(api: api)
        }
        try await eventually("读取开始等待旧账户保存") { loadingEntered }
        insights.reset()
        _ = await resetSave.value
        await loading.value
        XCTAssertNil(insights.writingStyle)
        XCTAssertFalse(insights.writingStyleLoaded)
        XCTAssertEqual(wire.requests(stylePath, method: "GET").count, 3)
    }

    func testWritingStyleAnchorAddRequiresSuccessfulLoadAndPreservesExistingAnchors() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let api = wire.api()
        let insights = InsightsStore()
        wire.reply(stylePath, status: 503, body: #"{"error":"暂时无法读取"}"#)
        await insights.loadWritingStyle(api: api)
        XCTAssertFalse(insights.writingStyleLoaded)
        XCTAssertEqual(insights.writingStyleError, "暂时无法读取")
        XCTAssertNil(insights.addWritingStyleAnchor("c", api: api))
        XCTAssertNil(insights.saveWritingStyle(.init(rules: "不能覆盖"), api: api))
        XCTAssertTrue(wire.requests(stylePath, method: "POST").isEmpty)

        let ab = #"{"style":{"rules":"先说结论","anchorNoteIds":["a","b"],"anchors":[{"id":"a","createdAt":"2026-11-28","excerpt":"甲"},{"id":"b","createdAt":"2026-11-28","excerpt":"乙"}],"missingAnchorCount":0,"scope":{"range":"all","tzOffsetMinutes":0,"tags":[],"tagMode":"any"},"noteCount":12,"updatedAt":"2026-11-28","ready":true}}"#
        let abc = ab.replacingOccurrences(of: #""a","b"]"#, with: #""a","b","c"]"#)
            .replacingOccurrences(of: #""excerpt":"乙"}]"#, with: #""excerpt":"乙"},{"id":"c","createdAt":"2026-11-28","excerpt":"丙"}]"#)
        wire.reply(stylePath, body: ab)
        await insights.loadWritingStyle(api: api)
        XCTAssertTrue(insights.writingStyleLoaded)
        XCTAssertNil(insights.writingStyleError)
        wire.reply(stylePath, method: "POST", body: abc)
        let added = try XCTUnwrap(insights.addWritingStyleAnchor("c", api: api))
        let addedSuccessfully = await added.value
        XCTAssertTrue(addedSuccessfully)
        let posts = wire.requests(stylePath, method: "POST")
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?["anchorNoteIds"] as? [String], ["a", "b", "c"])
        XCTAssertEqual(insights.writingStyle?.anchors.map(\.id), ["a", "b", "c"])

        insights.reset()
        wire.reply(stylePath, body: #"{"style":null}"#)
        await insights.loadWritingStyle(api: api)
        XCTAssertTrue(insights.writingStyleLoaded)
        XCTAssertNil(insights.writingStyle)
        wire.reply(stylePath, method: "POST", body: Self.styleEnvelope)
        let firstAnchor = try XCTUnwrap(insights.addWritingStyleAnchor("note", api: api))
        let firstAnchorSaved = await firstAnchor.value
        XCTAssertTrue(firstAnchorSaved)
        XCTAssertEqual(wire.requests(stylePath, method: "POST").last?["anchorNoteIds"] as? [String], ["note"])
    }

    func testWritingStyleRelayZeroSilentDowngradeOnProviderSwitchAndPendingSave() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, _) = try await connected(wire, mode: "relay")
        wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
        XCTAssertTrue(store.isRelayMode)
        store.insights.generateWritingStyle(api: api, options: store.options, isRelayMode: store.isRelayMode)
        store.insights.runBlindTest(api: api, options: store.options, prompt: "主题", isRelayMode: store.isRelayMode)
        XCTAssertEqual(store.insights.writingStyleError, InsightsStore.writingStyleRelayMessage)
        XCTAssertEqual(store.insights.blindTestError, InsightsStore.writingStyleRelayMessage)
        XCTAssertTrue(wire.requests(generatePath).isEmpty)
        XCTAssertTrue(wire.requests(blindPath).isEmpty)

        store.setProvider(.openai)
        let chat = store.chat
        chat.toggleWritingStyle(isRelayMode: store.isRelayMode)
        chat.draft = "仍要风格"
        store.setProvider(.codex)
        XCTAssertTrue(chat.useWritingStyle)
        XCTAssertEqual(chat.error, InsightsStore.writingStyleRelayMessage)
        chat.send(api: api, options: store.options, profile: store.insights, isRelayMode: { store.isRelayMode })
        XCTAssertFalse(chat.sending)
        XCTAssertEqual(chat.draft, "仍要风格")
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
        chat.toggleWritingStyle(isRelayMode: true)
        XCTAssertFalse(chat.useWritingStyle)
        chat.send(api: api, options: store.options, profile: store.insights, isRelayMode: { store.isRelayMode })
        try await eventually("允许主动关闭风格后发送") { !chat.sending && wire.requests(self.chatPath).count == 1 }
        XCTAssertNil(wire.requests(chatPath).first?["useWritingStyle"])

        wire.reply(stylePath, body: Self.styleEnvelope)
        await store.insights.loadWritingStyle(api: api)
        wire.hold(stylePath, method: "POST")
        store.setProvider(.openai)
        chat.toggleWritingStyle(isRelayMode: store.isRelayMode)
        chat.draft = "等待保存的草稿"
        let pending = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "新规则"), api: api))
        chat.send(api: api, options: store.options, profile: store.insights, isRelayMode: { store.isRelayMode })
        try await eventually("保存未完成") { wire.waiting(self.stylePath, method: "POST") == 1 }
        XCTAssertTrue(chat.sending)
        store.setProvider(.codex)
        XCTAssertFalse(chat.sending)
        XCTAssertTrue(chat.useWritingStyle)
        XCTAssertEqual(chat.draft, "等待保存的草稿")
        XCTAssertEqual(chat.error, InsightsStore.writingStyleRelayMessage)
        try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(body: Self.styleEnvelope)
        let completed = await pending.value
        XCTAssertTrue(completed)
        XCTAssertEqual(wire.requests(chatPath).count, 1)

        // The second check must also work when no provider reconciliation has run.
        store.setProvider(.openai)
        var becameRelay = false
        let retry = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "另一条规则"), api: api))
        chat.send(api: api, options: store.options, profile: store.insights, isRelayMode: { becameRelay })
        try await eventually("再次等待保存") { wire.waiting(self.stylePath, method: "POST") == 1 }
        becameRelay = true
        try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(body: Self.styleEnvelope)
        _ = await retry.value
        try await eventually("等待结束后复核 relay") { !chat.sending }
        XCTAssertEqual(chat.draft, "等待保存的草稿")
        XCTAssertTrue(chat.useWritingStyle)
        XCTAssertEqual(chat.error, InsightsStore.writingStyleRelayMessage)
        XCTAssertEqual(wire.requests(chatPath).count, 1)
    }

    func testAIChatPerTurnWritingStyleAndSignature() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let api = wire.api()
        let chat = AIChatStore()
        let insights = InsightsStore()
        wire.reply(chatPath, status: 503, body: #"{"error":"重试"}"#)
        chat.draft = "同一个问题"
        chat.send(api: api, options: .init(), profile: insights)
        try await eventually("普通对话失败可重试") { !chat.sending }
        let plain = try XCTUnwrap(wire.requests(chatPath).first)
        XCTAssertNil(plain["useWritingStyle"])
        let plainId = try XCTUnwrap(plain["clientRequestId"] as? String)
        XCTAssertEqual(chat.draft, "同一个问题")

        wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
        chat.toggleWritingStyle(isRelayMode: false)
        chat.send(api: api, options: .init(), profile: insights)
        try await eventually("风格对话成功") { !chat.sending }
        let styled = try XCTUnwrap(wire.requests(chatPath).last)
        XCTAssertEqual(styled["useWritingStyle"] as? Bool, true)
        XCTAssertEqual(plain["message"] as? String, styled["message"] as? String)
        XCTAssertNotEqual(plainId, try XCTUnwrap(styled["clientRequestId"] as? String))
        XCTAssertFalse(chat.useWritingStyle)
        XCTAssertEqual(chat.session?.id, "history")
        XCTAssertTrue(chat.draft.isEmpty)
    }

    func testRewriteWithStylePreservesDraftHandlesLoadFailure409AndSwitchGuard() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "relay")
        let chat = store.chat
        wire.reply(sourcePath, body: Self.history)
        wire.reply(historyPath, body: Self.history)
        wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
        store.setProvider(.openai)
        store.detail = .init(note: note, source: .notes)
        store.rewriteWithStyle(note)
        try await eventually("无草稿自动改写") { wire.requests(self.chatPath).count == 1 && !chat.sending }
        XCTAssertNil(store.detail)
        XCTAssertEqual(store.tab, .ai)
        let first = try XCTUnwrap(wire.requests(chatPath).first)
        XCTAssertEqual(first["sourceNoteId"] as? String, note.id)
        XCTAssertEqual(first["useWritingStyle"] as? Bool, true)
        XCTAssertEqual(first["message"] as? String, AIChatStore.rewriteNotePrompt)

        // A failed or canceled source load must never enqueue a chat POST.
        chat.reset()
        wire.reply(sourcePath, status: 503, body: #"{"error":"无法读取会话"}"#)
        store.rewriteWithStyle(note)
        try await eventually("原会话加载失败") { chat.error == "无法读取会话" && !chat.loadingSession }
        XCTAssertTrue(chat.draft.isEmpty)
        wire.hold(sourcePath)
        store.rewriteWithStyle(note)
        try await eventually("等待原会话") { wire.waiting(self.sourcePath, method: "GET") == 1 }
        let canceled = try XCTUnwrap(wire.take(sourcePath, method: "GET"))
        store.requestNewChat()
        try await eventually("切换取消原会话加载") { canceled.isStopped }
        XCTAssertNil(chat.sourceNoteId)
        XCTAssertEqual(wire.requests(chatPath).count, 1)

        wire.hold(historyPath)
        let selected = chat.select("history", api: api)
        try await eventually("包装 select 已出站") { wire.waiting(self.historyPath, method: "GET") == 1 }
        let selectedRequest = try XCTUnwrap(wire.take(historyPath, method: "GET"))
        selected.cancel()
        await selected.value
        try await eventually("select 包装取消转发到底层") { selectedRequest.isStopped }
        XCTAssertNil(chat.session)

        wire.reply(sourcePath, body: Self.history)
        wire.reply(historyPath, body: Self.history)
        store.askAbout(note)
        chat.draft = "笔记草稿"
        store.requestNewChat()
        store.rewriteWithStyle(note)
        try await eventually("笔记草稿载入") { !chat.loadingSession }
        XCTAssertEqual(chat.draft, "笔记草稿")
        XCTAssertTrue(chat.useWritingStyle)
        XCTAssertEqual(wire.requests(chatPath).count, 1)

        chat.draft = ""
        store.requestSelectChatSession("history")
        try await eventually("选择历史会话") { !chat.loadingSession && chat.session?.id == "history" }
        chat.draft = "历史会话草稿"
        store.requestNewChat()
        store.rewriteWithStyle(note)
        try await eventually("恢复历史会话草稿") { chat.draft == "历史会话草稿" }
        XCTAssertTrue(chat.useWritingStyle)
        XCTAssertEqual(wire.requests(chatPath).count, 1)

        store.requestNewChat()
        wire.hold(sourcePath)
        store.rewriteWithStyle(note)
        try await eventually("改写的源加载延迟") { wire.waiting(self.sourcePath, method: "GET") == 1 }
        XCTAssertTrue(chat.draft.isEmpty)
        chat.draft = "加载期间刚输入"
        try XCTUnwrap(wire.take(sourcePath, method: "GET")).complete(body: Self.history)
        await store.awaitPendingRewrite()
        await chat.waitForIdle()
        XCTAssertEqual(chat.session?.id, "history")
        XCTAssertEqual(wire.requests(chatPath).count, 1)
        XCTAssertEqual(chat.draft, "加载期间刚输入")
        XCTAssertTrue(chat.useWritingStyle)
        store.requestSelectChatSession("history")
        try await eventually("再次加载历史会话") { !chat.loadingSession }
        XCTAssertEqual(chat.draft, "历史会话草稿")
        wire.reply(sourcePath, body: Self.history)
        store.askAbout(note)
        try await eventually("重新打开笔记草稿") { !chat.loadingSession }
        XCTAssertEqual(chat.draft, "加载期间刚输入")
        XCTAssertEqual(wire.requests(chatPath).count, 1)

        chat.reset()
        wire.reply(chatPath, status: 409, body: #"{"error":"版本冲突","current":\#(Self.session)}"#)
        store.rewriteWithStyle(note)
        try await eventually("冲突保留原改写草稿") { !chat.sending && chat.error == "版本冲突" }
        XCTAssertEqual(chat.draft, AIChatStore.rewriteNotePrompt)
        XCTAssertTrue(chat.useWritingStyle)
        XCTAssertEqual(wire.requests(chatPath).count, 2)

        store.setProvider(.codex)
        store.detail = .init(note: note, source: .notes)
        let sourceLoads = wire.requests(sourcePath, method: "GET").count
        store.rewriteWithStyle(note)
        XCTAssertEqual(store.error, InsightsStore.writingStyleRelayMessage)
        XCTAssertEqual(store.detail?.id, note.id)
        XCTAssertEqual(wire.requests(sourcePath, method: "GET").count, sourceLoads)
        XCTAssertEqual(wire.requests(chatPath).count, 2)

        store.setProvider(.openai)
        store.requestNewChat()
        wire.hold(chatPath, method: "POST")
        chat.draft = "先前的问题"
        chat.send(api: api, options: store.options, profile: store.insights)
        try await eventually("已有发送进行中") { wire.waiting(self.chatPath, method: "POST") == 1 }
        store.rewriteWithStyle(note)
        guard case .rewriteNote(let pending) = store.pendingChatSwitch else { return XCTFail("需确认切换") }
        XCTAssertEqual(pending.id, note.id)
        XCTAssertTrue(chat.sending)
        XCTAssertEqual(store.detail?.id, note.id)
        store.cancelChatSwitch()
        XCTAssertNil(store.pendingChatSwitch)
        XCTAssertTrue(chat.sending)
        store.rewriteWithStyle(note)
        await store.applyRecord(nil, id: note.id)
        XCTAssertNil(store.pendingChatSwitch)
        store.confirmChatSwitch()
        store.rewriteWithStyle(note)
        XCTAssertNil(store.pendingChatSwitch)
        XCTAssertTrue(chat.sending)
        XCTAssertEqual(store.detail?.id, note.id)
        XCTAssertEqual(wire.requests(sourcePath, method: "GET").count, sourceLoads)
        XCTAssertEqual(wire.requests(chatPath).count, 3)

        await store.applyRecord(NoteRecord(note: note, deleted: nil), id: note.id)
        wire.hold(sourcePath)
        let previousSend = try XCTUnwrap(wire.take(chatPath, method: "POST"))
        store.rewriteWithStyle(note)
        store.confirmChatSwitch()
        try await eventually("确认切换取消旧请求并加载笔记") {
            previousSend.isStopped && wire.waiting(self.sourcePath, method: "GET") == 1
        }
        XCTAssertNil(store.pendingChatSwitch)
        XCTAssertNil(store.detail)
        XCTAssertEqual(chat.sourceNoteId, note.id)
        XCTAssertTrue(chat.useWritingStyle)
        XCTAssertEqual(wire.requests(chatPath).count, 3)
        chat.stop()
    }

    func testRewriteWithStyleCancelsWhenSourceIsDeletedWhileWaitingForSave() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "gateway")
        wire.reply(stylePath, body: Self.styleEnvelope)
        await store.insights.loadWritingStyle(api: api)
        wire.hold(stylePath, method: "POST")
        let save = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
        try await eventually("风格保存已挂起") { wire.waiting(self.stylePath, method: "POST") == 1 }
        let response = try XCTUnwrap(wire.take(stylePath, method: "POST"))
        wire.reply(sourcePath, body: #"{"session":null}"#)
        wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
        store.rewriteWithStyle(note)
        await store.awaitPendingRewrite()
        XCTAssertTrue(store.chat.sending)
        XCTAssertEqual(store.chat.sourceNoteId, note.id)
        XCTAssertEqual(store.chat.recoverableDraft, AIChatStore.rewriteNotePrompt)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)

        await store.replace(with: [], etag: nil, persist: false)
        XCTAssertFalse(store.chat.sending)
        XCTAssertNil(store.chat.sourceNoteId)
        XCTAssertEqual(store.chat.error, "原笔记已删除，已取消按风格改写。")
        XCTAssertTrue(store.chat.recoverableDraft.isEmpty)
        response.complete(body: Self.styleEnvelope)
        let saved = await save.value
        XCTAssertTrue(saved)
        await store.awaitPendingRewrite()
        await store.chat.waitForIdle()
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
        XCTAssertNil(store.chat.session)
    }

    func testRewriteWithStyleSendsOnlyLatestNoteWhenSourceLoadsFinishOutOfOrder() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, _, noteA) = try await connected(wire, mode: "gateway")
        let noteB = Note(id: "note-b", body: "另一条笔记", createdAt: "2026-11-28", revision: 1)
        await store.replace(with: [noteA, noteB], persist: false)
        wire.hold(sourcePath)
        let historyB = Self.history.replacingOccurrences(of: #""sourceNoteId":"note""#, with: #""sourceNoteId":"note-b""#)
        wire.reply(chatPath, body: Self.sse("done", historyB), stream: true)

        store.rewriteWithStyle(noteA)
        try await eventually("第一条笔记的会话读取已挂起") { wire.waiting(self.sourcePath) == 1 }
        let loadA = try XCTUnwrap(wire.take(sourcePath))
        store.rewriteWithStyle(noteB)
        try await eventually("第二条笔记的会话读取已挂起") { wire.waiting(self.sourcePath) == 1 }
        let loadB = try XCTUnwrap(wire.take(sourcePath))
        for (load, note) in [(loadA, noteA), (loadB, noteB)] {
            let query = try XCTUnwrap(load.request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
            XCTAssertEqual(query.first(where: { $0.name == "sourceNoteId" })?.value, note.id)
        }
        loadB.complete(body: #"{"session":null}"#)
        await store.awaitPendingRewrite()
        await store.chat.waitForIdle()
        loadA.complete(body: Self.history)
        try await eventually("旧读取已取消") { loadA.isStopped }
        await store.awaitPendingRewrite()
        await store.chat.waitForIdle()
        let posts = wire.requests(chatPath)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?["sourceNoteId"] as? String, noteB.id)
        XCTAssertEqual(posts.first?["useWritingStyle"] as? Bool, true)
        XCTAssertEqual(store.chat.sourceNoteId, noteB.id)
    }

    private func connected(_ wire: StyleHTTP, mode: String) async throws -> (AppStore, WeijiAPIClient, Note) {
        wire.reply("/api/session", body: #"{"user":{"id":"account","name":"测试账户"},"codexAvailable":true,"codexMode":"\#(mode)"}"#)
        wire.reply("/api/notes", body: Self.initialNotes)
        let store = AppStore(initial: wire.config, temporary: true, reset: true, makeTransport: wire.transport)
        store.start()
        try await eventually("登录并加载笔记") { store.api != nil && store.notesById["note"] != nil }
        return (store, try XCTUnwrap(store.api), try XCTUnwrap(store.notesById["note"]))
    }

    private func eventually(_ reason: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(3)
        while !condition(), clock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else {
            XCTFail(reason, file: file, line: line)
            throw WeijiAPIError.interrupted
        }
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private static func sse(_ event: String, _ data: String) -> String { "event: \(event)\ndata: \(data)\n\n" }
}

// Asynchronous holds let a save overtake a GET and let a test observe individual SSE frames.
private final class StyleHTTP: @unchecked Sendable {
    private typealias Handler = (StyleProtocol) -> Void
    let config: ServerConfiguration
    private let host = UUID().uuidString.lowercased() + ".example"
    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private var pending: [String: [StyleProtocol]] = [:]
    private var bodies: [String: [[String: Any]]] = [:]
    private var transports: [URLSession] = []

    init() throws {
        config = try ServerConfiguration(address: "http://" + host, token: "test-token")
        StyleProtocol.register(host) { [weak self] request in self?.receive(request) }
    }

    func transport() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StyleProtocol.self]
        let transport = URLSession(configuration: configuration)
        lock.withLock { transports.append(transport) }
        return transport
    }

    func api() -> WeijiAPIClient { WeijiAPIClient(configuration: config, transport: transport()) }
    func close() {
        StyleProtocol.register(host, handler: nil)
        for transport in lock.withLock({ transports }) { transport.invalidateAndCancel() }
    }

    func reply(_ path: String, method: String? = nil, status: Int = 200, body: String, stream: Bool = false) {
        let key = route(path, method ?? defaultMethod(path))
        lock.withLock { routes[key] = { $0.complete(status: status, body: body, stream: stream) } }
    }

    func hold(_ path: String, method: String? = nil) {
        let key = route(path, method ?? defaultMethod(path))
        lock.withLock { routes[key] = nil }
    }

    func waiting(_ path: String, method: String? = nil) -> Int {
        lock.withLock { pending[route(path, method ?? defaultMethod(path))]?.count ?? 0 }
    }

    func take(_ path: String, method: String? = nil) -> StyleProtocol? {
        lock.withLock {
            let key = route(path, method ?? defaultMethod(path))
            guard let first = pending[key]?.first else { return nil }
            pending[key]?.removeFirst()
            return first
        }
    }

    func requests(_ path: String, method: String? = nil) -> [[String: Any]] {
        lock.withLock { bodies[route(path, method ?? defaultMethod(path))] ?? [] }
    }

    private func receive(_ call: StyleProtocol) {
        let request = call.request
        let key = route(request.url?.path ?? "", request.httpMethod ?? "GET")
        let body = jsonBody(request) ?? [:]
        let handler = lock.withLock { () -> Handler? in
            bodies[key, default: []].append(body)
            if let route = routes[key] { return route }
            pending[key, default: []].append(call)
            return nil
        }
        handler?(call)
    }

    private func route(_ path: String, _ method: String) -> String { method + " " + path }
    private func defaultMethod(_ path: String) -> String {
        path == "/api/ai/chat" || path.hasSuffix("/generate") || path.hasSuffix("/blind-test") ? "POST" : "GET"
    }
}

private final class StyleProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var handlers: [String: (StyleProtocol) -> Void] = [:]
    private static let deliveryKey = DispatchSpecificKey<Bool>()
    private static let deliveryQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "weiji.tests.writing-style-protocol")
        queue.setSpecific(key: deliveryKey, value: true)
        return queue
    }()
    private var stopped = false
    var isStopped: Bool { onDeliveryQueue { stopped } }

    static func register(_ host: String, handler: ((StyleProtocol) -> Void)?) {
        registryLock.withLock { handlers[host] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.registryLock.withLock { Self.handlers[request.url?.host ?? ""] }
        if let handler { handler(self) }
        else { complete(status: 500, body: "Unexpected request") }
    }
    override func stopLoading() { onDeliveryQueue { stopped = true } }

    private func onDeliveryQueue<T>(_ action: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.deliveryKey) == true { return action() }
        return Self.deliveryQueue.sync(execute: action)
    }

    private func deliver(_ event: (URLProtocolClient) -> Void) {
        onDeliveryQueue {
            if !stopped, let client { event(client) }
        }
    }

    func begin(status: Int = 200, stream: Bool) {
        guard let url = request.url else { return }
        let headers = ["Content-Type": stream ? "text/event-stream" : "application/json"]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        deliver { $0.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
    }

    func write(_ body: String) {
        deliver { $0.urlProtocol(self, didLoad: Data(body.utf8)) }
    }

    func complete(status: Int = 200, body: String, stream: Bool = false) {
        begin(status: status, stream: stream)
        write(body)
        deliver { $0.urlProtocolDidFinishLoading(self) }
    }
}
