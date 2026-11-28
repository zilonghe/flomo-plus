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
    private static let rewriteHistoryA = #"{"session":{"id":"history-a","title":"笔记 A 的历史","sourceNoteId":"note","version":1,"updatedAt":"2026-11-28","origin":"note","turns":[{"role":"user","text":"之前的问题"}]}}"#
    private static let initialNotes = #"{"notes":[{"id":"note","body":"原创","createdAt":"2026-11-28","turns":[],"revision":1}],"deleted":[]}"#
    private static let emptyNotes = #"{"notes":[],"deleted":[]}"#
    private static let expired = #"{"error":"登录已过期"}"#
    private static let newDraft = " 原有新对话草稿 "
    private nonisolated static let firstDraft = " 首段用户原文含换行\n🪴 "
    private nonisolated static let nextDraft = "第二段补充包含空格与表情包🙂\t"
    private let stylePath = "/api/ai/writing-style"
    private let generatePath = "/api/ai/writing-style/generate"
    private let blindPath = "/api/ai/writing-style/blind-test"
    private let chatPath = "/api/ai/chat"
    private let profilePath = "/api/ai/profile"
    private let reportsPath = "/api/insights/reports"
    private let runReportPath = "/api/insights/run"
    private let sourcePath = "/api/ai/sessions"
    private let historyPath = "/api/ai/sessions/history"
    private let rewriteHistoryPath = "/api/ai/sessions/history-a"

    func testWritingStyleModelsAndOriginalFilter() throws {
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(WritingStyleResponse.self, from: Data(#"{"style":null}"#.utf8)).style)
        XCTAssertTrue(try object(WritingStyleResponse(style: nil))["style"] is NSNull)
        XCTAssertThrowsError(try decoder.decode(WritingStyleResponse.self, from: Data("{}".utf8))) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return XCTFail("应报告缺少 style 键：\(error)") }
            XCTAssertEqual(key.stringValue, "style")
        }
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
        let firstSent = try XCTUnwrap(wire.requests(chatPath).first?["message"] as? String)
        XCTAssertEqual(Array(firstSent.utf8), Array("待发草稿".utf8))

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
        let secondSent = try XCTUnwrap(wire.requests(chatPath).last?["message"] as? String)
        XCTAssertEqual(Array(secondSent.utf8), Array("等保存再发送".utf8))

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

    func testProfileSaveFailureWhileWaitingForStyleBlocksChatSend() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let api = wire.api()
        let insights = InsightsStore()
        let chat = AIChatStore()
        let profilePath = "/api/ai/profile"
        let draft = "待发草稿"
        wire.reply(stylePath, body: Self.styleEnvelope)
        wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
        await insights.loadWritingStyle(api: api)
        wire.hold(stylePath, method: "POST")
        let styleSave = try XCTUnwrap(insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
        try await eventually("风格保存已挂起") { wire.waiting(self.stylePath, method: "POST") == 1 }

        chat.draft = draft
        chat.useWritingStyle = true
        chat.send(api: api, options: .init(), profile: insights)
        // Let the send task reach the held style save before starting the profile save.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: ()) }
        }
        XCTAssertTrue(chat.sending)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)

        wire.reply(profilePath, method: "POST", status: 503, body: #"{"error":"画像保存出错"}"#)
        let profileSave = try XCTUnwrap(insights.saveProfile(.init(enabled: false), api: api))
        let profileSaved = await profileSave.value
        XCTAssertFalse(profileSaved)
        XCTAssertEqual(insights.profileError, "画像保存出错")
        XCTAssertEqual(wire.requests(profilePath, method: "POST").first?["enabled"] as? Bool, false)
        XCTAssertTrue(chat.sending)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)

        try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(body: Self.styleEnvelope)
        let styleSaved = await styleSave.value
        XCTAssertTrue(styleSaved)
        try await eventually("画像保存失败阻断聊天") { !chat.sending }
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
        XCTAssertEqual(chat.draft, draft)
        XCTAssertEqual(chat.error, "个人画像保存失败。请重新保存画像后再发送。")

        wire.reply(profilePath, method: "POST", body: #"{"profile":{"content":"个人画像","enabled":false,"noteCount":1}}"#)
        let retry = try XCTUnwrap(insights.saveProfile(.init(enabled: false), api: api))
        let retrySaved = await retry.value
        XCTAssertTrue(retrySaved)
        chat.send(api: api, options: .init(), profile: insights)
        try await eventually("重新保存画像后允许发送") { !chat.sending }
        let posts = wire.requests(chatPath)
        XCTAssertEqual(posts.count, 1)
        let sent = try XCTUnwrap(posts.first?["message"] as? String)
        XCTAssertEqual(Array(sent.utf8), Array(draft.utf8))
        XCTAssertNil(chat.error)
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

        wire.reply(stylePath, body: "{}")
        await insights.loadWritingStyle(api: api)
        XCTAssertFalse(insights.writingStyleLoaded)
        XCTAssertNotNil(insights.writingStyleError)
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

    func testWritingStyleLoadSurvivesViewCancellationAndIsSharedOnReentry() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let api = wire.api()
        let insights = InsightsStore()
        wire.hold(stylePath)
        let view1 = Task { await insights.loadWritingStyle(api: api) }
        try await eventually("第一次进入已请求写作风格") { wire.waiting(self.stylePath) == 1 }
        let request = try XCTUnwrap(wire.take(stylePath))
        wire.reply(stylePath, body: Self.styleEnvelope)

        view1.cancel()
        var reentered = false
        var reentryFinished = false
        let view2 = Task {
            reentered = true
            await insights.loadWritingStyle(api: api)
            reentryFinished = true
        }
        try await eventually("第二次进入开始读取") { reentered }
        XCTAssertTrue(insights.loadingWritingStyle)
        XCTAssertFalse(reentryFinished)
        request.complete(body: Self.styleEnvelope)
        await view2.value
        XCTAssertTrue(insights.writingStyleLoaded)
        XCTAssertFalse(insights.loadingWritingStyle)
        XCTAssertEqual(insights.writingStyleRulesText, "先说结论")
        await view1.value
        XCTAssertEqual(wire.requests(stylePath, method: "GET").count, 1)
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
        let posts = wire.requests(chatPath)
        let sent = try XCTUnwrap(posts.first?["message"] as? String)
        XCTAssertEqual(Array(sent.utf8), Array("仍要风格".utf8))
        XCTAssertNil(posts.first?["useWritingStyle"])

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
        let draft = "同一个问题"
        chat.draft = draft
        chat.send(api: api, options: .init(), profile: insights)
        try await eventually("普通对话失败可重试") { !chat.sending }
        let plainPosts = wire.requests(chatPath)
        XCTAssertEqual(plainPosts.count, 1)
        let plain = try XCTUnwrap(plainPosts.first)
        XCTAssertNil(plain["useWritingStyle"])
        let plainId = try XCTUnwrap(plain["clientRequestId"] as? String)
        let plainMessage = try XCTUnwrap(plain["message"] as? String)
        XCTAssertEqual(Array(plainMessage.utf8), Array(draft.utf8))
        XCTAssertEqual(chat.draft, draft)

        wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
        chat.toggleWritingStyle(isRelayMode: false)
        chat.send(api: api, options: .init(), profile: insights)
        try await eventually("风格对话成功") { !chat.sending }
        let posts = wire.requests(chatPath)
        XCTAssertEqual(posts.count, 2)
        let styled = try XCTUnwrap(posts.last)
        XCTAssertEqual(styled["useWritingStyle"] as? Bool, true)
        let styledMessage = try XCTUnwrap(styled["message"] as? String)
        XCTAssertEqual(Array(styledMessage.utf8), Array(draft.utf8))
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
        let firstMessage = try XCTUnwrap(first["message"] as? String)
        XCTAssertEqual(Array(firstMessage.utf8), Array(AIChatStore.rewriteNotePrompt.utf8))

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
        let conflictPosts = wire.requests(chatPath)
        XCTAssertEqual(conflictPosts.count, 2)
        let conflictMessage = try XCTUnwrap(conflictPosts.last?["message"] as? String)
        XCTAssertEqual(Array(conflictMessage.utf8), Array(AIChatStore.rewriteNotePrompt.utf8))

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
        let interruptedMessage = try XCTUnwrap(wire.requests(chatPath).last?["message"] as? String)
        XCTAssertEqual(Array(interruptedMessage.utf8), Array("先前的问题".utf8))
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

    func testRewriteWithStyleCancelsLateHistoryWhenSourceIsDeletedDuringLoad() async throws {
        for draft in ["", "我自己写的草稿"] {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, _, note) = try await connected(wire, mode: "gateway")
            wire.hold(sourcePath)
            wire.reply(chatPath, body: Self.sse("done", Self.rewriteHistoryA), stream: true)
            store.rewriteWithStyle(note)
            let rewrite = try XCTUnwrap(store.currentRewriteTask)
            try await eventually("源会话读取已挂起") { wire.waiting(self.sourcePath) == 1 }
            let response = try XCTUnwrap(wire.take(sourcePath))
            store.chat.draft = draft

            await store.replace(with: [], persist: false)
            response.complete(body: Self.rewriteHistoryA)
            await rewrite.value
            await store.chat.waitForIdle()
            assertDeletedRewrite(store.chat, draft: draft)
            XCTAssertTrue(wire.requests(chatPath).isEmpty)
        }
    }

    func testRewriteWithExistingNoteDraftCancelsLateHistoryWhenSourceIsDeleted() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "gateway")
        let chat = store.chat
        let draft = "已有笔记草稿"
        chat.start(source: note.id)
        chat.draft = draft
        store.requestNewChat()
        wire.hold(sourcePath)
        let global = #"{"session":{"id":"global","title":"对话","version":1,"updatedAt":"2026-11-28","origin":"global","turns":[]}}"#
        wire.reply(chatPath, body: Self.sse("done", global), stream: true)
        store.rewriteWithStyle(note)
        try await eventually("已有草稿时源会话读取仍已发出") { wire.waiting(self.sourcePath) == 1 }
        let response = try XCTUnwrap(wire.take(sourcePath))
        XCTAssertEqual(chat.draft, draft)
        XCTAssertTrue(chat.useWritingStyle)

        await store.replace(with: [], persist: false)
        XCTAssertFalse(chat.loadingSession, "删源应立即取消原会话读取")
        response.complete(body: Self.rewriteHistoryA)
        try await eventually("源会话读取结束") { !chat.loadingSession }
        await chat.waitForIdle()
        assertDeletedRewrite(chat, draft: draft)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)

        chat.send(api: api, options: store.options, profile: store.insights)
        await chat.waitForIdle()
        let posts = wire.requests(chatPath)
        XCTAssertEqual(posts.count, 1)
        let sent = try XCTUnwrap(posts.first?["message"] as? String)
        XCTAssertEqual(Array(sent.utf8), Array(draft.utf8))
        XCTAssertNil(posts.first?["sessionId"])
        XCTAssertNil(posts.first?["sourceNoteId"])
        XCTAssertNil(posts.first?["useWritingStyle"])
    }

    func testRewriteWithStyleCancelsWhenSourceIsDeletedWhileWaitingForSave() async throws {
        let profilePath = "/api/ai/profile"
        for path in [stylePath, profilePath] {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, note) = try await connected(wire, mode: "gateway")
            wire.hold(path, method: "POST")
            let pendingSave: Task<Bool, Never>
            let savedBody: String
            if path == stylePath {
                wire.reply(stylePath, body: Self.styleEnvelope)
                await store.insights.loadWritingStyle(api: api)
                pendingSave = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
                savedBody = Self.styleEnvelope
            } else {
                pendingSave = try XCTUnwrap(store.insights.saveProfile(.init(content: "正在保存", enabled: true), api: api))
                savedBody = #"{"profile":{"content":"正在保存","enabled":true,"noteCount":1}}"#
            }
            try await eventually("保存已挂起：\(path)") { wire.waiting(path, method: "POST") == 1 }
            let response = try XCTUnwrap(wire.take(path, method: "POST"))
            wire.reply(sourcePath, body: Self.rewriteHistoryA)
            wire.reply(chatPath, body: Self.sse("done", Self.rewriteHistoryA), stream: true)
            store.rewriteWithStyle(note)
            await store.awaitPendingRewrite()
            XCTAssertTrue(store.chat.sending)
            XCTAssertEqual(store.chat.session?.id, "history-a")
            XCTAssertEqual(store.chat.sourceNoteId, note.id)
            XCTAssertEqual(store.chat.pendingQuestion, AIChatStore.rewriteNotePrompt)
            XCTAssertEqual(store.chat.recoverableDraft, "")
            XCTAssertTrue(wire.requests(chatPath).isEmpty)

            await store.replace(with: [], persist: false)
            assertDeletedRewrite(store.chat)
            response.complete(body: savedBody)
            let saved = await pendingSave.value
            XCTAssertTrue(saved)
            await store.chat.waitForIdle()
            assertDeletedRewrite(store.chat)
            XCTAssertTrue(wire.requests(chatPath).isEmpty)
        }
    }

    func testDeletingRewriteSourcePreservesBothUnsentDrafts() async throws {
        for existingNew in ["", "已有新对话草稿"] {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, note) = try await connected(wire, mode: "gateway")
            store.chat.draft = existingNew

            let preserved = try await deleteRewriteSourceWithTwoDrafts(store, api: api, note: note, wire: wire)
            let expected = existingNew.isEmpty ? preserved : existingNew + "\n\n" + preserved
            assertDeletedRewrite(store.chat, draft: expected)
            try await assertDraftSurvivesHistoryRoundTrip(expected, store: store, wire: wire)
            XCTAssertTrue(wire.requests(chatPath).isEmpty)
        }
    }

    func testDeletingRewriteSourceMovesRestoredHistoryDraftToNewChat() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "gateway")
        let chat = store.chat
        let preserved = "历史会话还没发的草稿"
        wire.reply(rewriteHistoryPath, body: Self.rewriteHistoryA)
        await chat.select("history-a", api: api).value
        XCTAssertEqual(chat.session?.id, "history-a")
        chat.draft = preserved
        store.requestNewChat()

        wire.reply(sourcePath, body: Self.rewriteHistoryA)
        wire.reply(chatPath, body: Self.sse("done", Self.rewriteHistoryA), stream: true)
        store.rewriteWithStyle(note)
        await store.awaitPendingRewrite()
        XCTAssertEqual(chat.draft, preserved)

        try await syncDeleteRewriteSource(note, store: store, wire: wire)
        assertDeletedRewrite(chat, draft: preserved)
        try await assertDraftSurvivesHistoryRoundTrip(preserved, store: store, wire: wire)
        await chat.select("history-a", api: api).value
        XCTAssertEqual(chat.session?.id, "history-a")
        XCTAssertEqual(chat.draft, "", "原历史会话不应保留迁出的草稿副本")
        store.requestNewChat()
        XCTAssertEqual(Array(chat.draft.utf8), Array(preserved.utf8))
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
    }

    func testHistory401AfterDeletingRewriteSourceRecoversBothDraftsOnReauth() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "gateway")
        let userId = try XCTUnwrap(store.identity?.user.id)
        let preserved = try await deleteRewriteSourceWithTwoDrafts(store, api: api, note: note, wire: wire)
        assertDeletedRewrite(store.chat, draft: preserved)

        wire.reply(rewriteHistoryPath, status: 401, body: #"{"error":"登录已过期"}"#)
        store.requestSelectChatSession("history-a")
        XCTAssertEqual(store.chat.draft, "")
        XCTAssertEqual(store.chat.recoverableDraft, preserved)
        try await eventually("历史会话 GET 返回 401 并退出登录") {
            store.authScreenState == .needsLogin && !store.syncing
        }
        XCTAssertEqual(wire.requests(rewriteHistoryPath).count, 1)

        let renewed = try ServerConfiguration(address: wire.config.origin, token: "renewed-test-token")
        store.connect(renewed, save: false)
        try await eventually("同账号重登并同步") { store.authScreenState == .online && !store.syncing }
        XCTAssertEqual(store.identity?.user.id, userId)
        XCTAssertNil(store.notesById[note.id])
        XCTAssertEqual(store.chat.draft, preserved)
        XCTAssertEqual(store.chat.draft.utf8.count, 80)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
    }

    func testDraftTypedAfterEmptyRewriteCancellationReturnsToNewChat() async throws {
        let typed = Self.firstDraft + "\n\n" + Self.nextDraft
        let existingNew = " 原有新对话草稿 "
        XCTAssertEqual(typed.utf8.count, 80)
        XCTAssertEqual(existingNew.utf8.count, 23)
        let cases: [(savedNew: String, text: String, historyStatus: Int?)] = [
            ("", typed, 200), (existingNew, typed, 200), ("", typed, 401), (existingNew, typed, 401),
            (existingNew, "", nil), (existingNew, typed, nil),
        ]
        for (savedNew, text, historyStatus) in cases {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, note) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            chat.updateDraftFromUser(savedNew)
            let save = try await beginAutomaticRewriteWaitingForSave(note, store: store, api: api, wire: wire)
            try await syncDeleteRewriteSource(note, store: store, wire: wire)
            assertDeletedRewrite(chat, savedNew: savedNew)
            try await finishWritingStyleSave(save, wire: wire)

            chat.send(api: api, options: store.options, profile: store.insights)
            await chat.waitForIdle()
            XCTAssertTrue(wire.requests(chatPath).isEmpty, "空取消后的输入框不应发送")
            chat.updateDraftFromUser(text)
            let expected = [savedNew, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            switch historyStatus {
            case 200:
                try await assertDraftSurvivesHistoryRoundTrip(expected, store: store, wire: wire)
            case 401:
                wire.reply(rewriteHistoryPath, status: 401, body: #"{"error":"登录已过期"}"#)
                store.requestSelectChatSession("history-a")
                try await reauthenticate(store, wire: wire)
                XCTAssertEqual(wire.requests(rewriteHistoryPath).count, 1)
            default:
                store.requestNewChat()
            }
            XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8))
            XCTAssertTrue(wire.requests(chatPath).isEmpty)
        }
    }

    func testHistory401WithItsOwnDraftRestoresBothContextsOnlyForSameAccount() async throws {
        enum Login: CaseIterable { case sameAccount, otherAccount, otherOrigin }
        let historyDraft = " H 草稿含换行\n🙂下一行"
        XCTAssertEqual(historyDraft.utf8.count, 32)
        for login in Login.allCases {
            for savedInHistory in [true, false] {
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, note) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                if savedInHistory {
                    wire.reply(rewriteHistoryPath, body: Self.rewriteHistoryA)
                    await chat.select("history-a", api: api).value
                    XCTAssertEqual(chat.session?.id, "history-a")
                    chat.updateDraftFromUser(historyDraft)
                    store.requestNewChat()
                }
                let rescued = try await deleteRewriteSourceWithTwoDrafts(store, api: api, note: note, wire: wire)
                XCTAssertEqual(rescued.utf8.count, 80)
                assertDeletedRewrite(chat, draft: rescued)

                wire.hold(rewriteHistoryPath)
                store.requestSelectChatSession("history-a")
                try await eventually("历史会话 GET 已挂起") { wire.waiting(self.rewriteHistoryPath) == 1 }
                XCTAssertEqual(chat.draft, savedInHistory ? historyDraft : "")
                if !savedInHistory { chat.updateDraftFromUser(historyDraft) }
                try XCTUnwrap(wire.take(rewriteHistoryPath)).complete(status: 401, body: #"{"error":"登录已过期"}"#)

                let loginWire = login == .otherOrigin ? try StyleHTTP() : wire
                defer { if loginWire !== wire { loginWire.close() } }
                let user = login == .otherAccount ? "other-account" : "account"
                loginWire.reply("/api/session", body: #"{"user":{"id":"\#(user)","name":"测试账户"},"codexAvailable":true,"codexMode":"gateway"}"#)
                loginWire.reply("/api/notes", body: #"{"notes":[],"deleted":[]}"#)
                loginWire.reply("/api/ai/models", body: #"{"models":[]}"#)
                try await reauthenticate(store, wire: loginWire)
                XCTAssertEqual(store.identity?.user.id, user)
                XCTAssertEqual(store.configuration?.origin, loginWire.config.origin)

                let expectedNew = login == .sameAccount ? rescued : ""
                let expectedHistory = login == .sameAccount ? historyDraft : ""
                XCTAssertEqual(Array(chat.draft.utf8), Array(expectedNew.utf8))
                loginWire.reply(rewriteHistoryPath, body: Self.rewriteHistoryA)
                store.requestSelectChatSession("history-a")
                try await eventually("重登后打开历史会话") { !chat.loadingSession && chat.session?.id == "history-a" }
                XCTAssertEqual(Array(chat.draft.utf8), Array(expectedHistory.utf8))
                store.requestNewChat()
                XCTAssertEqual(Array(chat.draft.utf8), Array(expectedNew.utf8))
                XCTAssertTrue(wire.requests(chatPath).isEmpty)
                XCTAssertTrue(loginWire.requests(chatPath).isEmpty)
            }
        }
    }

    func testClearedRescuedNewChatDraftDoesNotReturnAfter401() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "gateway")
        let rescued = try await deleteRewriteSourceWithTwoDrafts(store, api: api, note: note, wire: wire)
        XCTAssertEqual(Array(store.chat.draft.utf8), Array(rescued.utf8))
        XCTAssertEqual(store.chat.draft.utf8.count, 80)

        store.chat.updateDraftFromUser("")
        wire.reply("/api/notes", status: 401, body: #"{"error":"登录已过期"}"#)
        store.refresh()
        try await eventually("刷新笔记返回 401") { store.authScreenState == .needsLogin && !store.syncing }
        wire.reply("/api/notes", body: #"{"notes":[],"deleted":[]}"#)
        try await reauthenticate(store, wire: wire)
        XCTAssertEqual(store.chat.draft.utf8.count, 0)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
    }

    func testNoteDraftSurvivesSourceGETOrChatPOST401UntilNotesSync() async throws {
        let savedNew = Self.newDraft
        let typed = Self.firstDraft + "\n\n" + Self.nextDraft
        let merged = savedNew + "\n\n" + typed
        XCTAssertEqual(savedNew.utf8.count, 23)
        XCTAssertEqual(typed.utf8.count, 80)
        XCTAssertEqual(merged.utf8.count, 105)

        for rejectPOST in [false, true] {
            for rejectFirstLogin in [false, true] {
                for sourceExists in [false, true] {
                    let scenario = "POST 401: \(rejectPOST), 重登再遇 401: \(rejectFirstLogin), 来源仍在: \(sourceExists)"
                    let wire = try StyleHTTP()
                    defer { wire.close() }
                    let (store, api, note) = try await connected(wire, mode: "gateway")
                    let chat = store.chat
                    let userId = try XCTUnwrap(store.identity?.user.id)
                    chat.updateDraftFromUser(savedNew)
                    wire.hold(sourcePath)
                    wire.reply(chatPath, status: 401, body: Self.expired)
                    store.rewriteWithStyle(note)
                    try await eventually("来源 GET 已挂起") { wire.waiting(self.sourcePath) == 1 }
                    chat.updateDraftFromUser(typed)
                    let source = try XCTUnwrap(wire.take(sourcePath))
                    if rejectPOST {
                        source.complete(body: Self.rewriteHistoryA)
                        await store.awaitPendingRewrite()
                        XCTAssertFalse(chat.sending, scenario)
                        XCTAssertTrue(wire.requests(chatPath).isEmpty, scenario)
                        chat.send(api: api, options: store.options, profile: store.insights)
                    } else {
                        source.complete(status: 401, body: Self.expired)
                    }

                    if rejectFirstLogin {
                        try await eventually("首次 401 后回到登录页") { store.authScreenState == .needsLogin && !store.syncing }
                        wire.hold("/api/notes")
                        let renewed = try ServerConfiguration(address: wire.config.origin, token: "first-renewed-test-token")
                        store.connect(renewed, save: false)
                        try await eventually("重登后笔记列表尚未返回") { wire.waiting("/api/notes") == 1 }
                        XCTAssertEqual(store.identity?.user.id, userId)
                        XCTAssertTrue(chat.canReference(note.id), scenario)
                        XCTAssertEqual(Array(chat.draft.utf8), Array(savedNew.utf8), scenario)
                        let savedNote = try XCTUnwrap(chat.recoverableDraftSnapshot.savedDrafts["note:\(note.id)"])
                        XCTAssertEqual(Array(savedNote.utf8), Array(typed.utf8), scenario)
                        try XCTUnwrap(wire.take("/api/notes")).complete(status: 401, body: Self.expired)
                    }

                    wire.reply("/api/notes", body: sourceExists ? Self.initialNotes : #"{"notes":[],"deleted":[]}"#)
                    try await reauthenticate(store, wire: wire)
                    XCTAssertEqual(store.identity?.user.id, userId, scenario)
                    XCTAssertEqual(store.notesById[note.id] != nil, sourceExists, scenario)
                    let expected = sourceExists ? savedNew : merged
                    XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), scenario)
                    if sourceExists {
                        wire.reply(sourcePath, body: Self.rewriteHistoryA)
                        store.askAbout(note)
                        try await eventually("重新打开来源笔记") { !chat.loadingSession && chat.session?.id == "history-a" }
                        XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), scenario)
                        store.requestNewChat()
                        XCTAssertEqual(Array(chat.draft.utf8), Array(savedNew.utf8), scenario)
                    } else {
                        try await assertDraftSurvivesHistoryRoundTrip(merged, store: store, wire: wire)
                    }

                    let posts = wire.requests(chatPath)
                    XCTAssertEqual(posts.count, rejectPOST ? 1 : 0, scenario)
                    if rejectPOST {
                        let message = try XCTUnwrap(posts.first?["message"] as? String)
                        XCTAssertEqual(Array(message.utf8), Array(typed.utf8), scenario)
                        XCTAssertEqual(posts.first?["sourceNoteId"] as? String, note.id, scenario)
                    }
                }
            }
        }
    }

    func testReauthRescuesDeletedNoteWithoutFillingAnInFlightNewChat() async throws {
        try await assertReauthRescuesDeletedNoteDuringSend(followUp: "")
    }

    func testReauthPreservesInFlightDraftAndFollowUpWhenRescuingDeletedNote() async throws {
        let followUp = "新的追问保留空格与结束标点📝\t"
        XCTAssertEqual(followUp.utf8.count, 44)
        try await assertReauthRescuesDeletedNoteDuringSend(followUp: followUp)
    }

    func testConfirmingNewChatKeepsUnseenRescuedDraft() async throws {
        enum Event { case requestNew, deleteSource, saveFails, relay, confirm, cancel, reauthenticate }
        let sequences: [[Event]] = [
            [.deleteSource, .requestNew, .confirm],
            [.requestNew, .confirm, .deleteSource],
            [.requestNew, .deleteSource, .confirm],
            [.requestNew, .deleteSource, .saveFails, .confirm],
            [.requestNew, .saveFails, .deleteSource, .confirm],
            [.requestNew, .saveFails, .confirm, .deleteSource],
            [.requestNew, .deleteSource, .relay, .confirm],
            [.requestNew, .relay, .deleteSource, .confirm],
            [.requestNew, .deleteSource, .saveFails, .cancel],
            [.requestNew, .deleteSource, .saveFails, .reauthenticate],
        ]
        let rescued = Self.firstDraft + "\n\n" + Self.nextDraft
        XCTAssertEqual(rescued.utf8.count, 80)
        for followUp in ["", "新的追问保留空格与结束标点📝\t"] {
            let active = followUp.isEmpty ? Self.newDraft : Self.newDraft + "\n\n" + followUp
            for events in sequences {
                let scenario = "\(events)，追问: \(followUp.utf8.count) 字节"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, _, note) = try await connected(wire, mode: events.contains(.relay) ? "relay" : "gateway")
                let chat = store.chat
                try await rejectSourceLoad(note, draft: rescued, store: store, wire: wire)
                let notes = try await beginReauthWithHeldNotes(store, wire: wire)
                let api = try XCTUnwrap(store.api)
                store.setProvider(.openai)
                let save = try await holdWritingStyleSave(store, api: api, wire: wire)
                wire.reply(chatPath, status: 503, body: #"{"error":"未结清保存不应发送"}"#)

                XCTAssertEqual(Array(chat.draft.utf8), Array(Self.newDraft.utf8), scenario)
                chat.toggleWritingStyle(isRelayMode: false)
                chat.send(api: api, options: store.options, profile: store.insights)
                XCTAssertTrue(chat.sending, scenario)
                chat.updateDraftFromUser(followUp)
                for event in events {
                    switch event {
                    case .requestNew:
                        store.requestNewChat()
                        guard case .new = store.pendingChatSwitch else { return XCTFail("发送中必须先确认新建") }
                    case .deleteSource:
                        let before = chat.draft
                        notes.complete(body: Self.emptyNotes)
                        try await eventually("笔记同步已确认删源") { !store.syncing && !chat.canReference(note.id) }
                        if chat.sending || store.pendingChatSwitch != nil {
                            XCTAssertEqual(Array(chat.draft.utf8), Array(before.utf8), scenario)
                        }
                    case .saveFails:
                        try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(status: 503, body: #"{"error":"保存失败"}"#)
                        let saved = await save.value
                        XCTAssertFalse(saved, scenario)
                        await chat.waitForIdle()
                        XCTAssertFalse(chat.sending, scenario)
                        XCTAssertNotNil(store.pendingChatSwitch, scenario)
                        if !chat.canReference(note.id) {
                            XCTAssertEqual(Array(chat.draft.utf8), Array(active.utf8), scenario)
                            XCTAssertEqual(Array(chat.recoverableDraftSnapshot.activeDraft.utf8),
                                           Array((active + "\n\n" + rescued).utf8), scenario)
                            XCTAssertNil(chat.recoverableDraftSnapshot.savedDrafts["new"], scenario)
                        }
                    case .relay:
                        store.setProvider(.codex)
                        XCTAssertFalse(chat.sending, scenario)
                        XCTAssertEqual(chat.error, InsightsStore.writingStyleRelayMessage, scenario)
                    case .confirm:
                        guard case .new = store.pendingChatSwitch else { return XCTFail("新建确认应仍然挂起") }
                        store.confirmChatSwitch()
                        XCTAssertFalse(chat.sending, scenario)
                        if chat.canReference(note.id) { XCTAssertEqual(chat.draft, "", scenario) }
                    case .cancel:
                        store.cancelChatSwitch()
                        XCTAssertNil(store.pendingChatSwitch, scenario)
                    case .reauthenticate:
                        try await rejectNotesRefresh(store, wire: wire)
                        wire.reply("/api/notes", body: Self.emptyNotes)
                        try await reauthenticate(store, wire: wire)
                        XCTAssertNil(store.pendingChatSwitch, scenario)
                    }
                }

                if !events.contains(.saveFails) { try await finishWritingStyleSave(save, wire: wire) }
                await chat.waitForIdle()
                let expected = events.contains(.confirm) ? rescued : active + "\n\n" + rescued
                XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), scenario)
                try await assertDraftSurvivesHistoryRoundTrip(expected, store: store, wire: wire)

                try await rejectNotesRefresh(store, wire: wire)
                wire.reply("/api/notes", body: Self.emptyNotes)
                try await reauthenticate(store, wire: wire)
                XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), scenario)
                store.requestNewChat()
                XCTAssertEqual(chat.draft, "", "空闲时连续新建仍应清空当前草稿")
                XCTAssertEqual(wire.requests(chatPath).count, 0, scenario)
            }
        }
    }

    private func assertReauthRescuesDeletedNoteDuringSend(followUp typedFollowUp: String) async throws {
        enum Outcome { case chatFailure, chatConflict, profileFailure, stop, success, unauthorized, relay }
        let notesPath = "/api/notes"
        let profilePath = "/api/ai/profile"
        let noteDraft = Self.firstDraft + "\n\n" + Self.nextDraft
        XCTAssertEqual(Self.newDraft.utf8.count, 23)
        XCTAssertEqual(noteDraft.utf8.count, 80)
        let outcomes: [Outcome] = [.chatFailure, .profileFailure, .success, .unauthorized]
            + (typedFollowUp.isEmpty ? [.relay] : [.chatConflict, .stop])

        for outcome in outcomes {
            let scenario = "发送结果：\(outcome)"
            let followUp = outcome == .relay ? Self.nextDraft : typedFollowUp
            let merged = [Self.newDraft, followUp, noteDraft].filter { !$0.isEmpty }.joined(separator: "\n\n")
            XCTAssertEqual(merged.utf8.count, followUp.isEmpty ? 105 : 151, scenario)
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, _, note) = try await connected(wire, mode: outcome == .relay ? "relay" : "gateway")
            let chat = store.chat
            try await rejectSourceLoad(note, draft: noteDraft, store: store, wire: wire)
            let notes = try await beginReauthWithHeldNotes(store, wire: wire)
            let api = try XCTUnwrap(store.api)
            XCTAssertEqual(Array(chat.draft.utf8), Array(Self.newDraft.utf8), scenario)
            XCTAssertTrue(chat.canReference(note.id), scenario)

            let waitsForProfile = outcome == .profileFailure || outcome == .stop || outcome == .relay
            var profileSave: Task<Bool, Never>?
            if waitsForProfile {
                wire.hold(profilePath, method: "POST")
                profileSave = try XCTUnwrap(store.insights.saveProfile(.init(enabled: false), api: api))
                try await eventually("画像保存尚未返回") { wire.waiting(profilePath, method: "POST") == 1 }
            }
            if outcome == .relay {
                store.setProvider(.openai)
                chat.toggleWritingStyle(isRelayMode: store.isRelayMode)
            }
            if waitsForProfile {
                wire.reply(chatPath, status: 503, body: #"{"error":"画像保存结清前不应发送"}"#)
            } else {
                wire.hold(chatPath)
            }
            chat.send(api: api, options: store.options, profile: store.insights)
            XCTAssertTrue(chat.sending, scenario)
            XCTAssertEqual(Array(chat.pendingQuestion.utf8), Array(Self.newDraft.utf8), scenario)
            if !waitsForProfile {
                try await eventually("聊天 POST 尚未返回") { wire.waiting(self.chatPath) == 1 }
            }
            chat.updateDraftFromUser(followUp)

            notes.complete(body: Self.emptyNotes)
            try await eventually("笔记同步已确认 A 删除") { !store.syncing && !chat.canReference(note.id) }
            XCTAssertTrue(chat.sending, scenario)
            XCTAssertEqual(Array(chat.draft.utf8), Array(followUp.utf8), scenario)
            XCTAssertEqual(Array(chat.recoverableDraftSnapshot.activeDraft.utf8), Array(merged.utf8), scenario)

            switch outcome {
            case .chatFailure, .chatConflict:
                let status = outcome == .chatConflict ? 409 : 503
                let message = outcome == .chatConflict ? "对话已更新" : "聊天不可用"
                try XCTUnwrap(wire.take(chatPath)).complete(status: status, body: #"{"error":"\#(message)"}"#)
                await chat.waitForIdle()
                XCTAssertEqual(chat.error, message, scenario)
            case .profileFailure:
                try XCTUnwrap(wire.take(profilePath, method: "POST")).complete(status: 503, body: #"{"error":"画像不可用"}"#)
                await chat.waitForIdle()
                XCTAssertEqual(store.insights.profileError, "画像不可用")
                XCTAssertNotNil(chat.error)
            case .success:
                try XCTUnwrap(wire.take(chatPath)).complete(body: Self.sse("done", Self.history), stream: true)
                await chat.waitForIdle()
                XCTAssertEqual(chat.session?.id, "history")
                XCTAssertEqual(Array(chat.draft.utf8), Array(followUp.utf8), scenario)
                store.requestNewChat()
            case .unauthorized:
                try XCTUnwrap(wire.take(chatPath)).complete(status: 401, body: Self.expired)
                wire.reply(notesPath, body: Self.emptyNotes)
                try await reauthenticate(store, wire: wire)
            case .stop, .relay:
                if outcome == .relay { store.setProvider(.codex) }
                else { chat.stop() }
                XCTAssertFalse(chat.sending, scenario)
                try XCTUnwrap(wire.take(profilePath, method: "POST")).complete(body: #"{"profile":{"content":"画像","enabled":false,"noteCount":1}}"#)
                let saved = await profileSave?.value
                XCTAssertEqual(saved, true, scenario)
                await chat.waitForIdle()
                if outcome == .relay { XCTAssertEqual(chat.error, InsightsStore.writingStyleRelayMessage) }
            }
            let expected = outcome == .success ? noteDraft : merged
            XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), scenario)
            let posts = wire.requests(chatPath)
            XCTAssertEqual(posts.count, waitsForProfile ? 0 : 1, scenario)
            if !waitsForProfile {
                let sent = try XCTUnwrap(posts.first?["message"] as? String, scenario)
                XCTAssertEqual(Array(sent.utf8), Array(Self.newDraft.utf8), scenario)
            }
            try await assertDraftSurvivesHistoryRoundTrip(expected, store: store, wire: wire)
            if !typedFollowUp.isEmpty, outcome != .success, outcome != .unauthorized {
                try await rejectNotesRefresh(store, wire: wire)
                wire.reply(notesPath, body: Self.emptyNotes)
                try await reauthenticate(store, wire: wire)
                XCTAssertEqual(store.identity?.user.id, "account", scenario)
                XCTAssertEqual(Array(chat.draft.utf8), Array(merged.utf8), scenario)
            }
            XCTAssertEqual(wire.requests(chatPath).count, posts.count, scenario)
        }
    }

    func testReauthKeepsAutomaticRewriteSuppressedAfterTwo401s() async throws {
        for rejectPOST in [true, false] {
            for sourceExists in [false, true] {
                let scenario = "自动 POST 401：\(rejectPOST)，最终来源仍在：\(sourceExists)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, note) = try await connected(wire, mode: rejectPOST ? "gateway" : "relay")
                let chat = store.chat
                chat.updateDraftFromUser(Self.newDraft)
                if rejectPOST {
                    wire.reply(sourcePath, body: Self.rewriteHistoryA)
                    wire.reply(chatPath, status: 401, body: Self.expired)
                    store.rewriteWithStyle(note)
                } else {
                    store.setProvider(.openai)
                    let save = try await beginAutomaticRewriteWaitingForSave(note, store: store, api: api, wire: wire)
                    store.setProvider(.codex)
                    XCTAssertEqual(chat.draft, AIChatStore.rewriteNotePrompt, scenario)
                    try await finishWritingStyleSave(save, wire: wire)
                    try await rejectNotesRefresh(store, wire: wire)
                }

                let notes = try await beginReauthWithHeldNotes(store, wire: wire)
                XCTAssertEqual(chat.draft, "", scenario)
                XCTAssertEqual(chat.recoverableDraft, "", scenario)
                let snapshot = chat.recoverableDraftSnapshot
                XCTAssertTrue(snapshot.suppressedAutomaticPrompt, scenario)
                let parked = try XCTUnwrap(snapshot.savedDrafts["new"])
                XCTAssertEqual(Array(parked.utf8), Array(Self.newDraft.utf8), scenario)
                let originalPosts = wire.requests(chatPath)
                XCTAssertEqual(originalPosts.count, rejectPOST ? 1 : 0, scenario)
                if rejectPOST {
                    let sent = try XCTUnwrap(originalPosts.first?["message"] as? String, scenario)
                    XCTAssertEqual(Array(sent.utf8), Array(AIChatStore.rewriteNotePrompt.utf8), scenario)
                }
                notes.complete(status: 401, body: Self.expired)

                wire.reply("/api/notes", body: sourceExists ? Self.initialNotes : Self.emptyNotes)
                try await reauthenticate(store, wire: wire)
                XCTAssertEqual(store.identity?.user.id, "account", scenario)
                XCTAssertEqual(store.notesById[note.id] != nil, sourceExists, scenario)
                XCTAssertEqual(chat.draft, "", scenario)
                XCTAssertEqual(chat.recoverableDraft, "", scenario)
                wire.reply(chatPath, status: 503, body: #"{"error":"空输入不应发送"}"#)
                chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
                await chat.waitForIdle()
                XCTAssertEqual(wire.requests(chatPath).count, originalPosts.count, scenario)
                store.requestNewChat()
                XCTAssertEqual(Array(chat.draft.utf8), Array(Self.newDraft.utf8), scenario)
            }
        }
    }

    func testWhitespaceDoesNotUnsuppressAutomaticRewriteAcross401s() async throws {
        enum Phase: CaseIterable { case inFlight, afterDeletion, relayRestored }
        let real = " \t\u{3000}" + String(repeating: "x", count: 33) + "\u{3000}\n"
        let template = AIChatStore.rewriteNotePrompt
        XCTAssertEqual(real.utf8.count, 42)
        XCTAssertEqual(template.utf8.count, 144)
        for phase in Phase.allCases {
            let edits: [(text: String, isUserDraft: Bool)] = phase == .relayRestored
                ? ["", " ", "\t", "\n", " \t\n", "\u{3000}"].map { ($0, false) } + [(real, true), (template, true)]
                : [(" \t\n", false), ("\u{3000}", false)]
            for (text, isUserDraft) in edits {
                let scenario = "\(phase)，输入: \(text.debugDescription)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, note) = try await connected(wire, mode: phase == .relayRestored ? "relay" : "gateway")
                let chat = store.chat
                chat.updateDraftFromUser(Self.newDraft)
                store.setProvider(.openai)
                let save = try await beginAutomaticRewriteWaitingForSave(note, store: store, api: api, wire: wire)
                if phase == .afterDeletion {
                    try await syncDeleteRewriteSource(note, store: store, wire: wire)
                    XCTAssertFalse(chat.sending, scenario)
                } else if phase == .relayRestored {
                    store.setProvider(.codex)
                    XCTAssertFalse(chat.sending, scenario)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(template.utf8), scenario)
                }
                chat.updateDraftFromUser(text)
                let snapshot = chat.recoverableDraftSnapshot
                XCTAssertEqual(snapshot.suppressedAutomaticPrompt, !isUserDraft, scenario)
                XCTAssertEqual(Array(snapshot.activeDraft.utf8), isUserDraft ? Array(text.utf8) : [], scenario)
                wire.reply(chatPath, status: 503, body: #"{"error":"聊天未完成"}"#)

                let expected = isUserDraft ? Self.newDraft + "\n\n" + text : ""
                for _ in 0..<2 {
                    try await rejectNotesRefresh(store, wire: wire)
                    wire.reply("/api/notes", body: Self.emptyNotes)
                    try await reauthenticate(store, wire: wire)
                    XCTAssertEqual(chat.recoverableDraftSnapshot.suppressedAutomaticPrompt, !isUserDraft, scenario)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), scenario)
                    if !isUserDraft {
                        chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
                        await chat.waitForIdle()
                        XCTAssertEqual(wire.requests(chatPath).count, 0, scenario)
                    }
                }
                let saved = await save.value
                XCTAssertFalse(saved, scenario)
                if isUserDraft {
                    chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
                    await chat.waitForIdle()
                    let posts = wire.requests(chatPath)
                    XCTAssertEqual(posts.count, 1, scenario)
                    let message = try XCTUnwrap(posts.first?["message"] as? String, scenario)
                    XCTAssertEqual(Array(message.utf8), Array(expected.utf8), scenario)
                } else {
                    store.requestNewChat()
                    XCTAssertEqual(Self.newDraft.utf8.count, 23)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(Self.newDraft.utf8), scenario)
                }
            }
        }
    }

    func testReauthKeepsBothHandwrittenPartsWhenSendingIsRejected() async throws {
        let noteDraft = Self.firstDraft + "\n\n" + Self.nextDraft
        let merged = Self.newDraft + "\n\n" + noteDraft
        XCTAssertEqual(Self.firstDraft.utf8.count, 34)
        XCTAssertEqual(Self.nextDraft.utf8.count, 44)
        XCTAssertEqual(noteDraft.utf8.count, 80)
        XCTAssertEqual(merged.utf8.count, 105)

        for waitingForSave in [false, true] {
            for sourceExists in [false, true] {
                let scenario = "风格保存未返回：\(waitingForSave)，来源仍在：\(sourceExists)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, note) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                chat.updateDraftFromUser(Self.newDraft)
                try await openSourceNote(note, store: store, wire: wire)
                chat.updateDraftFromUser(Self.firstDraft)
                chat.toggleWritingStyle(isRelayMode: store.isRelayMode)

                var save: Task<Bool, Never>?
                if waitingForSave {
                    wire.reply(stylePath, body: Self.styleEnvelope)
                    await store.insights.loadWritingStyle(api: api)
                    wire.hold(stylePath, method: "POST")
                    save = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
                    try await eventually("风格保存尚未返回") { wire.waiting(self.stylePath, method: "POST") == 1 }
                }
                wire.hold(chatPath)
                chat.send(api: api, options: store.options, profile: store.insights)
                XCTAssertTrue(chat.sending, scenario)
                XCTAssertEqual(Array(chat.pendingQuestion.utf8), Array(Self.firstDraft.utf8), scenario)
                XCTAssertEqual(chat.draft, "", scenario)
                chat.updateDraftFromUser(Self.nextDraft)
                if let save {
                    try await rejectNotesRefresh(store, wire: wire)
                    let saved = await save.value
                    XCTAssertFalse(saved, scenario)
                } else {
                    try await eventually("聊天 POST 尚未返回") { wire.waiting(self.chatPath) == 1 }
                    try XCTUnwrap(wire.take(chatPath)).complete(status: 401, body: Self.expired)
                }

                wire.reply("/api/notes", body: sourceExists ? Self.initialNotes : Self.emptyNotes)
                try await reauthenticate(store, wire: wire)
                XCTAssertEqual(store.notesById[note.id] != nil, sourceExists, scenario)
                let home = sourceExists ? Self.newDraft : merged
                XCTAssertEqual(Array(chat.draft.utf8), Array(home.utf8), scenario)
                if sourceExists {
                    try await openSourceNote(note, store: store, wire: wire)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(noteDraft.utf8), scenario)
                    store.requestNewChat()
                    XCTAssertEqual(Array(chat.draft.utf8), Array(home.utf8), scenario)
                } else {
                    try await assertDraftSurvivesHistoryRoundTrip(merged, store: store, wire: wire)
                }
                let posts = wire.requests(chatPath)
                XCTAssertEqual(posts.count, waitingForSave ? 0 : 1, scenario)
                if !waitingForSave {
                    let sent = try XCTUnwrap(posts.first?["message"] as? String)
                    XCTAssertEqual(Array(sent.utf8), Array(Self.firstDraft.utf8), scenario)
                    XCTAssertEqual(posts.first?["sourceNoteId"] as? String, note.id, scenario)
                }
            }
        }
    }

    func testReauthRescuesReopenedNoteDraftWhenDeletedInForeground() async throws {
        enum Deletion: CaseIterable { case background, leaveThenUnauthorized, unauthorizedWhileActive }
        let typed = Self.firstDraft + "\n\n" + Self.nextDraft
        let merged = Self.newDraft + "\n\n" + typed
        for deletion in Deletion.allCases {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, _, note) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            try await rejectSourceLoad(note, draft: typed, store: store, wire: wire)
            try await reauthenticate(store, wire: wire)
            XCTAssertEqual(Array(chat.draft.utf8), Array(Self.newDraft.utf8))
            try await openSourceNote(note, store: store, wire: wire)
            XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8))
            if deletion == .background { store.requestNewChat() }

            try await syncDeleteRewriteSource(note, store: store, wire: wire)
            if deletion == .unauthorizedWhileActive {
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8))
                try await rejectNotesRefresh(store, wire: wire)
                let notes = try await beginReauthWithHeldNotes(store, wire: wire)
                XCTAssertEqual(Array(chat.draft.utf8), Array(merged.utf8), "已知删源，恢复不需要再等笔记列表")
                notes.complete(body: Self.emptyNotes)
                try await eventually("重登后完成同步") { !store.syncing }
            } else {
                try await assertDraftSurvivesHistoryRoundTrip(merged, store: store, wire: wire)
                try await rejectNotesRefresh(store, wire: wire)
                wire.reply("/api/notes", body: Self.emptyNotes)
                try await reauthenticate(store, wire: wire)
            }
            XCTAssertEqual(Array(chat.draft.utf8), Array(merged.utf8), "\(deletion)")
            try await assertDraftSurvivesHistoryRoundTrip(merged, store: store, wire: wire)
            XCTAssertTrue(wire.requests(chatPath).isEmpty)
        }
    }

    func testWalkAndInsightDraftsRestoreInTheirOriginalContextAfter401() async throws {
        XCTAssertEqual(Self.newDraft.utf8.count, 23)
        try await assertWalkAndInsightDraftsRestore(savedNew: Self.newDraft)
    }

    func testReauthKeepsWalkAndInsightDraftsSeparateWithAnEmptyNewChat() async throws {
        try await assertWalkAndInsightDraftsRestore(savedNew: "")
    }

    func testInsightDraftMovesOnlyAfterConfirmedReportDeletion() async throws {
        enum Scenario: CaseIterable {
            case retained, delete200, delete404, missing404, open404, laterPage, detail503, cancelledProbe
        }
        let id = "report-51"
        let listPath = reportsPath
        let detailPath = "\(listPath)/\(id)"
        let draftKey = "insight:\(id)"
        let typed = " AI草稿含换行\n🙂下一行"
        let gone = #"{"error":"报告不存在"}"#
        let unavailable = #"{"error":"报告暂不可用"}"#
        XCTAssertEqual(typed.utf8.count, 32)

        let present = #"{"reports":[\#(Self.reportJSON(id))]}"#
        let detail = #"{"report":\#(Self.reportJSON(id))}"#

        for scenario in Scenario.allCases {
            let label = "\(scenario)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let insights = store.insights
            let chat = store.chat
            let summary = try await openInsightReport(id, store: store, wire: wire)
            store.askAbout(summary)
            chat.updateDraftFromUser(typed)

            let deletedHere = scenario == .delete200 || scenario == .delete404
            if deletedHere {
                let success = scenario == .delete200
                if !success { store.requestNewChat() } // A parked draft can move to the open composer immediately.
                wire.reply(detailPath, method: "DELETE", status: success ? 200 : 404,
                           body: success ? #"{"deleted":"\#(id)"}"# : gone)
                let deleted = await insights.deleteReport(id, api: api)
                XCTAssertEqual(deleted, success, label)
                XCTAssertEqual(insights.viewedReportError, success ? nil : "报告不存在", label)
                XCTAssertNil(insights.viewedReport, label)
                XCTAssertEqual(insights.viewedReportText, "", label)
                XCTAssertTrue(insights.reports.isEmpty, label)
                XCTAssertNil(chat.insight, label)
                store.tab = .insights
                store.askAbout(summary)
                XCTAssertEqual(store.tab, .insights, label)
                XCTAssertNil(chat.insight, label)
            }
            try await rejectNotesRefresh(store, wire: wire)
            wire.reply("/api/notes", body: Self.initialNotes)
            try await reauthenticate(store, wire: wire)
            let reauthAPI = try XCTUnwrap(store.api)
            XCTAssertEqual(wire.requests(listPath).count, 1, label)
            XCTAssertEqual(wire.requests(detailPath).count, 1, "重登时还未打开洞察，不应探测报告")
            XCTAssertEqual(Array(chat.draft.utf8), deletedHere ? Array(typed.utf8) : [], label)
            XCTAssertEqual(chat.recoverableDraftSnapshot.savedDrafts[draftKey].map { Array($0.utf8) },
                           deletedHere ? nil : Array(typed.utf8), label)

            if scenario == .open404 {
                wire.reply(detailPath, status: 404, body: gone)
                insights.openReport(summary, api: reauthAPI)
                try await eventually("打开已删除报告返回 404") { !insights.loadingReport }
                XCTAssertEqual(insights.viewedReportError, "报告不存在")
                XCTAssertEqual(wire.requests(detailPath).count, 2, label)
            } else {
                let firstPage = (1...50).map { Self.reportJSON("report-\($0)") }.joined(separator: ",")
                let summaries = scenario == .retained ? present
                    : (scenario == .laterPage ? #"{"reports":[\#(firstPage)]}"# : #"{"reports":[]}"#)
                wire.reply(listPath, body: summaries)
                if scenario == .detail503 {
                    wire.reply(detailPath, status: 503, body: unavailable)
                } else if deletedHere || scenario == .missing404 {
                    wire.reply(detailPath, status: 404, body: gone)
                }
                if scenario == .cancelledProbe {
                    wire.hold(detailPath)
                    let loading = Task { await insights.loadLibrary(api: reauthAPI) }
                    try await eventually("缺失报告的详情查询已发出") { wire.waiting(detailPath) == 1 }
                    let pending = try XCTUnwrap(wire.take(detailPath))
                    loading.cancel()
                    await loading.value
                    pending.complete(status: 404, body: gone)
                } else {
                    await insights.loadLibrary(api: reauthAPI)
                }
                let probed = !deletedHere && scenario != .retained
                XCTAssertEqual(wire.requests(detailPath).count, probed ? 2 : 1, label)
                if scenario == .laterPage { XCTAssertEqual(insights.reports.count, 50) }
            }

            if deletedHere || scenario == .missing404 || scenario == .open404 {
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                XCTAssertNil(chat.recoverableDraftSnapshot.savedDrafts[draftKey], label)
                try await assertDraftSurvivesHistoryRoundTrip(typed, store: store, wire: wire)
                try await rejectNotesRefresh(store, wire: wire)
                wire.reply("/api/notes", body: Self.initialNotes)
                try await reauthenticate(store, wire: wire)
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
            } else {
                XCTAssertEqual(chat.draft, "", label)
                let saved = try XCTUnwrap(chat.recoverableDraftSnapshot.savedDrafts[draftKey], label)
                XCTAssertEqual(Array(saved.utf8), Array(typed.utf8), label)
                wire.reply(detailPath, body: detail)
                insights.openReport(summary, api: reauthAPI)
                try await eventually("仍存在的报告详情已加载") { !insights.loadingReport }
                store.askAbout(try XCTUnwrap(insights.viewedReport))
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                store.requestNewChat()
                XCTAssertEqual(chat.draft, "", label)
            }
            XCTAssertEqual(wire.requests(chatPath).count, 0, label)
        }
    }

    func testConfirmedMissingInsightCancelsPendingFollowUp() async throws {
        let id = "deleted-report"
        let path = "\(reportsPath)/\(id)"
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, _) = try await connected(wire, mode: "gateway")
        let chat = store.chat
        let insights = store.insights
        let report = try await openInsightReport(id, store: store, wire: wire)
        store.askAbout(report)
        chat.updateDraftFromUser(Self.firstDraft)
        store.requestNewChat()

        let save = try await holdWritingStyleSave(store, api: api, wire: wire)
        chat.updateDraftFromUser(Self.newDraft)
        chat.toggleWritingStyle(isRelayMode: false)
        wire.reply(chatPath, status: 503, body: #"{"error":"等待保存不应发送"}"#)
        chat.send(api: api, options: store.options, profile: insights)
        wire.reply(reportsPath, body: #"{"reports":[]}"#)
        wire.hold(path)
        let loading = Task { await insights.loadLibrary(api: api) }
        defer { loading.cancel() }
        try await eventually("缺失报告的详情核实已发出") { wire.waiting(path) == 1 }
        store.tab = .insights
        store.askAbout(try XCTUnwrap(insights.viewedReport))
        guard case .report(let pending) = store.pendingChatSwitch else { return XCTFail("发送中必须先确认继续追问") }
        XCTAssertEqual(pending.id, id)

        try XCTUnwrap(wire.take(path)).complete(status: 404, body: #"{"error":"报告不存在"}"#)
        await loading.value
        XCTAssertNil(insights.viewedReport)
        XCTAssertEqual(insights.viewedReportText, "")
        XCTAssertFalse(chat.canReferenceInsight(id))
        XCTAssertNil(store.pendingChatSwitch)
        store.confirmChatSwitch()
        store.askAbout(report)
        XCTAssertEqual(store.tab, .insights)
        XCTAssertNil(store.pendingChatSwitch)
        XCTAssertNil(chat.insight)
        XCTAssertTrue(chat.sending, "失效的切换不得中断旧发送")

        try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(status: 503, body: #"{"error":"保存失败"}"#)
        let saved = await save.value
        XCTAssertFalse(saved)
        await chat.waitForIdle()
        let rescued = Self.newDraft + "\n\n" + Self.firstDraft
        XCTAssertEqual(Array(chat.draft.utf8), Array(rescued.utf8))
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
        chat.start(insight: report)
        XCTAssertNil(chat.insight, "直接启动聊天也不能重新注入已确认删除的报告")
        XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new")
    }

    func testDeletingCurrentRewriteDuringNewChatConfirmationPreservesTheOtherDraft() async throws {
        enum Background: CaseIterable { case newChat, reportFirst, rewriteFirst }
        enum Decision: CaseIterable { case confirm, cancel, reauthenticate, history }
        let outside = String(repeating: "另", count: 26) + "  "
        let followUp = " " + String(repeating: "续", count: 14) + " "
        let merged = outside + "\n\n" + followUp
        XCTAssertEqual([outside, followUp, merged].map { $0.utf8.count }, [80, 44, 126])

        for background in Background.allCases {
            for decision in Decision.allCases {
                let label = "\(background), \(decision)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, note) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                let report = background == .newChat ? nil : try await openInsightReport("report", store: store, wire: wire)
                if let report { store.askAbout(report) }
                chat.updateDraftFromUser(outside)
                let save = try await beginAutomaticRewriteWaitingForSave(note, store: store, api: api, wire: wire)
                chat.updateDraftFromUser(followUp)
                store.requestNewChat()
                guard case .new = store.pendingChatSwitch else { return XCTFail(label) }

                if let report, background == .reportFirst {
                    try await confirmReportDeletion(report, via: .delete200, store: store, api: api, wire: wire)
                }
                try await syncDeleteRewriteSource(note, store: store, wire: wire)
                if let report, background == .rewriteFirst {
                    try await confirmReportDeletion(report, via: .delete200, store: store, api: api, wire: wire)
                }
                XCTAssertFalse(chat.sending, label)
                XCTAssertEqual(chat.error, AIChatStore.deletedRewriteSourceMessage, label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(followUp.utf8), label)
                XCTAssertEqual(Array(chat.recoverableDraftSnapshot.activeDraft.utf8), Array(merged.utf8), label)
                try await finishWritingStyleSave(save, wire: wire)
                await chat.waitForIdle()

                switch decision {
                case .confirm: store.confirmChatSwitch()
                case .cancel: store.cancelChatSwitch()
                case .reauthenticate:
                    try await rejectNotesRefresh(store, wire: wire)
                    wire.reply("/api/notes", body: Self.emptyNotes)
                    try await reauthenticate(store, wire: wire)
                case .history:
                    try await assertDraftSurvivesHistoryRoundTrip(merged, store: store, wire: wire)
                }
                XCTAssertNil(store.pendingChatSwitch, label)
                XCTAssertEqual(Array(chat.draft.utf8), Array((decision == .confirm ? outside : merged).utf8), label)
                store.requestNewChat()
                XCTAssertEqual(chat.draft, "", label)
                XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
            }
        }
    }

    func testRemovingCurrentHistorySettlesPendingNewChatWithoutDiscardingRescuedDrafts() async throws {
        enum Event { case session, report, note, failedSession, unrelatedSession }
        let newDraft = String(repeating: "新", count: 26) + "  "
        let reportDraft = String(repeating: "报", count: 26) + "  "
        let followUp = " " + String(repeating: "续", count: 14) + " "
        let both = newDraft + "\n\n" + reportDraft
        let merged = newDraft + "\n\n" + followUp
        XCTAssertEqual([newDraft, reportDraft, both, merged].map { $0.utf8.count }, [80, 80, 162, 126])
        let cases: [(keepNew: Bool, events: [Event], pending: Bool, expected: String)] = [
            (true, [.session], false, newDraft),
            (false, [.report, .session], false, reportDraft),
            (false, [.session, .report], false, reportDraft),
            (true, [.report, .session], false, both),
            (true, [.session, .note], false, merged),
            (true, [.note, .session], true, newDraft),
            (true, [.failedSession], true, newDraft),
            (true, [.unrelatedSession], true, newDraft),
        ]
        for scenario in cases {
            let label = "\(scenario.events)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, note) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            if scenario.keepNew { chat.updateDraftFromUser(newDraft) }
            let report = scenario.events.contains(.report) ? try await openInsightReport("report", store: store, wire: wire) : nil
            if let report {
                store.askAbout(report)
                chat.updateDraftFromUser(reportDraft)
            }
            let save = try await beginAutomaticRewriteWaitingForSave(note, store: store, api: api, wire: wire)
            XCTAssertEqual(chat.session?.id, "history-a", label)
            chat.updateDraftFromUser(followUp)
            let id = scenario.events.contains(.unrelatedSession) ? "other-history" : "history-a"
            let path = "\(sourcePath)/\(id)"
            wire.hold(path, method: "DELETE")
            let removal = Task { await chat.remove(id, api: api) }
            try await eventually("会话删除请求已发出") { wire.waiting(path, method: "DELETE") == 1 }
            let reply = try XCTUnwrap(wire.take(path, method: "DELETE"))
            store.requestNewChat()
            guard case .new = store.pendingChatSwitch else { return XCTFail(label) }

            for event in scenario.events {
                switch event {
                case .report:
                    try await confirmReportDeletion(try XCTUnwrap(report), via: .delete200, store: store, api: api, wire: wire)
                case .note:
                    try await syncDeleteRewriteSource(note, store: store, wire: wire)
                case .session, .unrelatedSession:
                    reply.complete(body: #"{"deleted":"\#(id)"}"#)
                    await removal.value
                case .failedSession:
                    reply.complete(status: 500, body: #"{"error":"稍后再试"}"#)
                    await removal.value
                }
            }
            XCTAssertEqual(store.pendingChatSwitch?.isNewChat, scenario.pending ? true : nil, label)
            store.confirmChatSwitch()
            XCTAssertNil(store.pendingChatSwitch, label)
            XCTAssertNil(chat.session, label)
            XCTAssertEqual(Array(chat.draft.utf8), Array(scenario.expected.utf8), label)
            try await finishWritingStyleSave(save, wire: wire)
            await chat.waitForIdle()
            try await assertDraftSurvivesHistoryRoundTrip(scenario.expected, store: store, wire: wire)
            store.requestNewChat()
            XCTAssertEqual(chat.draft, "", label)
            XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
        }
    }

    func testRemovingPendingHistoryTargetCancelsOnlyItsConfirmation() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "gateway")
        let save = try await beginAutomaticRewriteWaitingForSave(note, store: store, api: api, wire: wire)
        store.requestSelectChatSession("other-history")
        guard case .session("other-history") = store.pendingChatSwitch else { return XCTFail("应先确认切换") }
        let path = "\(sourcePath)/other-history"
        wire.reply(path, method: "DELETE", body: #"{"deleted":"other-history"}"#)
        await store.chat.remove("other-history", api: api)
        XCTAssertNil(store.pendingChatSwitch)
        store.confirmChatSwitch()
        XCTAssertTrue(store.chat.sending)
        XCTAssertEqual(store.chat.session?.id, "history-a")
        XCTAssertTrue(wire.requests(path).isEmpty)
        store.chat.stop()
        try await finishWritingStyleSave(save, wire: wire)
        await store.chat.waitForIdle()
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
    }

    func testDeleteWhileLoadingSessionMovesSubsequentDraftToNewChat() async throws {
        let draft = " " + String(repeating: "续", count: 14) + "\t"
        let other = #"{"id":"unrelated","title":"另一段对话","version":1,"updatedAt":"2026-11-28","origin":"global","turns":[]}"#
        XCTAssertEqual(draft.utf8.count, 44)
        for status in [200, 404] {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            wire.reply(sourcePath, body: #"{"sessions":[\#(Self.session)],"nextCursor":"older"}"#)
            chat.refreshSessions(api: api)
            try await eventually("初始列表已加载") { chat.sessions.map(\.id) == ["history"] && !chat.loadingList }

            wire.hold(historyPath, method: "DELETE")
            let removal = Task { await chat.remove("history", api: api) }
            try await eventually("删除会话已发出") { wire.waiting(self.historyPath, method: "DELETE") == 1 }
            wire.hold(historyPath)
            let selection = chat.select("history", api: api)
            try await eventually("会话详情 GET 仍在加载") { wire.waiting(self.historyPath) == 1 }
            let detail = try XCTUnwrap(wire.take(historyPath))
            XCTAssertTrue(chat.loadingSession)
            XCTAssertNil(chat.session)

            wire.hold(sourcePath)
            chat.refreshSessions(api: api, more: true)
            try await eventually("删除期间发起加载更多") { wire.waiting(self.sourcePath) == 1 }
            let page = try XCTUnwrap(wire.take(sourcePath))
            let query = URLComponents(url: try XCTUnwrap(page.request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertTrue(query?.contains(URLQueryItem(name: "cursor", value: "older")) == true)
            try XCTUnwrap(wire.take(historyPath, method: "DELETE")).complete(body: #"{"deleted":"history"}"#)
            await removal.value
            XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new")
            XCTAssertFalse(chat.loadingSession)
            XCTAssertTrue(chat.sessions.isEmpty)

            detail.complete(status: status, body: status == 200 ? Self.history : #"{"error":"会话不存在"}"#)
            await selection.value
            XCTAssertNil(chat.session)
            XCTAssertNil(chat.error)
            page.complete(body: #"{"sessions":[\#(Self.session),\#(other)],"nextCursor":null}"#)
            try await eventually("过期分页已结清") { !chat.loadingList }
            XCTAssertEqual(chat.sessions.map(\.id), ["unrelated"])
            XCTAssertNil(chat.cursor)

            wire.reply(sourcePath, body: Self.history)
            let loaded = await chat.loadSource("note", api: api).value
            XCTAssertFalse(loaded, "来源 GET 也不能重新显示已经删除的会话")
            XCTAssertNil(chat.session)
            chat.updateDraftFromUser(draft)
            await chat.select("history", api: api).value
            XCTAssertEqual(wire.requests(historyPath).count, 1, "已删除会话不能再次选中")
            XCTAssertEqual(Array(chat.draft.utf8), Array(draft.utf8))
            try await assertDraftSurvivesHistoryRoundTrip(draft, store: store, wire: wire)
            try await rejectNotesRefresh(store, wire: wire)
            wire.reply("/api/notes", body: Self.initialNotes)
            try await reauthenticate(store, wire: wire)
            XCTAssertEqual(Array(chat.draft.utf8), Array(draft.utf8))
            XCTAssertNil(chat.recoverableDraftSnapshot.savedDrafts["session:history"])
            XCTAssertTrue(wire.requests(chatPath).isEmpty)
        }
    }

    func testDeletedSessionLateSendCompletionDoesNotResurrectSession() async throws {
        enum Timing: CaseIterable { case beforeDone, beforeEOF, afterEOF, unrelated, failed }
        func sessionJSON(_ id: String, version: Int = 1) -> String {
            #"{"id":"\#(id)","title":"对话","version":\#(version),"updatedAt":"2026-11-28","origin":"global","turns":[{"role":"user","text":"原问题"},{"role":"assistant","text":"原回答"}]}"#
        }
        let history = sessionJSON("history")
        let completion = Self.sse("done", #"{"session":\#(history)}"#)
        for timing in Timing.allCases {
            let label = "\(timing)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            let report = try await openInsightReport("report", store: store, wire: wire, cited: true, content: "报告正文片段")
            store.askAbout(report)
            chat.useWritingStyle = true
            chat.updateDraftFromUser(Self.firstDraft)
            wire.hold(chatPath)
            chat.send(api: api, options: store.options, profile: store.insights)
            try await eventually("发送已交给传输层") { wire.waiting(self.chatPath) == 1 }
            let reply = try XCTUnwrap(wire.take(chatPath), label)
            reply.begin(stream: true)
            if timing == .beforeEOF || timing == .afterEOF {
                reply.write(Self.sse("status", #"{"stage":"writing","message":"回复中"}"#))
                try await eventually("收到状态帧") { chat.status == "回复中" }
                reply.write(completion)
                try await eventually("已处理 done，EOF 尚未返回") { chat.status == nil && chat.sending }
                if timing == .afterEOF {
                    reply.finish()
                    await chat.waitForIdle()
                    XCTAssertEqual(chat.session?.id, "history", label)
                }
            }
            wire.reply(sourcePath, body: #"{"sessions":[\#(history),\#(sessionJSON("other"))],"nextCursor":null}"#)
            chat.refreshSessions(api: api)
            try await eventually("历史列表已显示 H") { !chat.loadingList && chat.sessions.contains { $0.id == "history" } }
            let id = timing == .unrelated ? "other" : "history"
            let path = "\(sourcePath)/\(id)"
            wire.reply(path, method: "DELETE", status: timing == .failed ? 503 : 200,
                       body: timing == .failed ? #"{"error":"删除失败"}"# : #"{"deleted":"\#(id)"}"#)
            await chat.remove(id, api: api)
            XCTAssertEqual(wire.requests(path, method: "DELETE").count, 1, label)
            chat.updateDraftFromUser(Self.nextDraft)
            if timing != .afterEOF {
                if timing != .beforeEOF { reply.write(completion) }
                reply.finish()
                await chat.waitForIdle()
            }

            let survives = timing == .unrelated || timing == .failed
            XCTAssertEqual(chat.sessions.map(\.id), timing == .unrelated ? ["history"] : (survives ? ["history", "other"] : ["other"]), label)
            XCTAssertEqual(chat.session?.id, survives ? "history" : nil, label)
            let shown = AIChatView.displayedTurns(session: chat.session, loadingSession: chat.loadingSession,
                                                 sourceNoteId: chat.sourceNoteId, notesById: store.notesById)
            XCTAssertEqual(shown?.map(\.text) ?? [], survives ? ["原问题", "原回答"] : [], label)
            XCTAssertEqual(Array(chat.draft.utf8), Array(Self.nextDraft.utf8), label)
            if !survives {
                XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new", label)
                XCTAssertNil(chat.insight, label)
                XCTAssertTrue(chat.pins.isEmpty, label)
                XCTAssertFalse(chat.useWritingStyle, label)
            }
            wire.reply(chatPath, body: Self.sse("done", #"{"session":\#(sessionJSON(survives ? "history" : "fresh"))}"#), stream: true)
            chat.send(api: api, options: store.options, profile: store.insights)
            await chat.waitForIdle()
            let posts = wire.requests(chatPath)
            XCTAssertEqual(posts.count, 2, label)
            let followUp = try XCTUnwrap(posts.last, label)
            let message = try XCTUnwrap(followUp["message"] as? String, label)
            XCTAssertEqual(Array(message.utf8), Array(Self.nextDraft.utf8), label)
            XCTAssertEqual(followUp["sessionId"] as? String, survives ? "history" : nil, label)
        }

        for refetch in [false, true] {
            for deleted in [false, true] {
                let label = "409, refetch=\(refetch), deleted=\(deleted)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let api = wire.api()
                let chat = AIChatStore()
                let profile = InsightsStore()
                let options = AIOptions()
                let activePath = "\(sourcePath)/active"
                if refetch {
                    wire.reply(activePath, body: #"{"session":\#(sessionJSON("active"))}"#)
                    await chat.select("active", api: api).value
                    wire.hold(activePath)
                }
                chat.updateDraftFromUser(Self.firstDraft)
                wire.hold(chatPath)
                chat.send(api: api, options: options, profile: profile)
                try await eventually("冲突前 POST 已出站") { wire.waiting(self.chatPath) == 1 }
                let reply = try XCTUnwrap(wire.take(chatPath), label)
                if refetch {
                    reply.complete(status: 409, body: #"{"error":"冲突"}"#)
                    try await eventually("409 已发起会话重读") { wire.waiting(activePath) == 1 }
                }
                if deleted {
                    wire.reply(historyPath, method: "DELETE", body: #"{"deleted":"history"}"#)
                    await chat.remove("history", api: api)
                }
                let candidate = sessionJSON(refetch && !deleted ? "active" : "history", version: 2)
                if refetch {
                    try XCTUnwrap(wire.take(activePath), label).complete(body: #"{"session":\#(candidate)}"#)
                } else {
                    reply.complete(status: 409, body: #"{"error":"冲突","current":\#(candidate)}"#)
                }
                await chat.waitForIdle()

                let expectedID: String? = refetch ? "active" : (deleted ? nil : "history")
                let expectedVersion: Int? = deleted ? (refetch ? 1 : nil) : 2
                XCTAssertEqual(chat.session?.id, expectedID, label)
                XCTAssertEqual(chat.session?.version, expectedVersion, label)
                XCTAssertEqual(chat.error, "冲突", label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(Self.firstDraft.utf8), label)
                XCTAssertEqual(wire.requests(chatPath).count, 1, label)
                wire.reply(chatPath, body: Self.sse("done", #"{"session":\#(sessionJSON(expectedID ?? "fresh", version: 3))}"#), stream: true)
                chat.send(api: api, options: options, profile: profile)
                await chat.waitForIdle()
                let posts = wire.requests(chatPath)
                XCTAssertEqual(posts.count, 2, label)
                let retry = try XCTUnwrap(posts.last, label)
                let message = try XCTUnwrap(retry["message"] as? String, label)
                XCTAssertEqual(retry["sessionId"] as? String, expectedID, label)
                XCTAssertEqual(retry["expectedVersion"] as? Int, expectedVersion, label)
                XCTAssertEqual(Array(message.utf8), Array(Self.firstDraft.utf8), label)
            }
        }
    }

    func testDeletedSessionLateSendSettlesPendingNewChatConfirmation() async throws {
        enum Target: CaseIterable { case newBeforeDelete, newAfterDelete, otherHistory }
        for doneFirst in [false, true] {
            for target in Target.allCases where !doneFirst || target != .newAfterDelete {
                for saved in ["", Self.firstDraft + "\n\n" + Self.nextDraft] {
                    let label = "doneFirst=\(doneFirst), \(target), saved=\(saved.utf8.count)"
                    let wire = try StyleHTTP()
                    defer { wire.close() }
                    let (store, api, _) = try await connected(wire, mode: "gateway")
                    let chat = store.chat
                    let reply = try await beginHeldReportSend(store, api: api, wire: wire, saved: saved)
                    try await listHistoryWhileSending(chat, api: api, wire: wire)
                    wire.hold(historyPath, method: "DELETE")
                    let removal = Task { await chat.remove("history", api: api) }
                    try await eventually("会话删除等待响应") { wire.waiting(self.historyPath, method: "DELETE") == 1 }
                    chat.updateDraftFromUser(Self.nextDraft)
                    if target == .newBeforeDelete {
                        store.requestNewChat()
                        XCTAssertEqual(store.pendingChatSwitch?.isNewChat, true, label)
                    } else if target == .otherHistory {
                        store.requestSelectChatSession("history-a")
                        guard case .session("history-a") = store.pendingChatSwitch else { return XCTFail(label) }
                    }
                    if doneFirst { try await deliverHeldChatDone(reply, chat: chat) }
                    try XCTUnwrap(wire.take(historyPath, method: "DELETE")).complete(body: #"{"deleted":"history"}"#)
                    await removal.value
                    if target == .newAfterDelete {
                        store.requestNewChat()
                        XCTAssertEqual(store.pendingChatSwitch?.isNewChat, true, label)
                    }
                    if !doneFirst { try await deliverHeldChatDone(reply, chat: chat) }
                    reply.finish()
                    await chat.waitForIdle()

                    let expected = saved.isEmpty ? Self.nextDraft : saved + "\n\n" + Self.nextDraft
                    XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new", label)
                    XCTAssertNil(chat.recoverableDraftSnapshot.savedDrafts["new"], label)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), label)
                    if target == .otherHistory {
                        guard case .session("history-a") = store.pendingChatSwitch else { return XCTFail(label) }
                        wire.reply(rewriteHistoryPath, body: Self.rewriteHistoryA)
                        store.confirmChatSwitch()
                        try await eventually("未删除的确认目标仍可打开") { chat.session?.id == "history-a" }
                        XCTAssertEqual(chat.draft, "", label)
                        store.requestNewChat()
                    } else {
                        XCTAssertNil(store.pendingChatSwitch, label)
                        store.confirmChatSwitch()
                    }
                    XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), label)
                    XCTAssertEqual(wire.requests(chatPath).count, 1, label)
                    try await assertOrdinaryChatSend(expected, store: store, wire: wire)
                }
            }
        }
    }

    func testDeletedSessionKnownDoneSettlesBeforeDisconnectStopOr401() async throws {
        enum End: CaseIterable { case disconnect, stop, reauth, differentID, failedDelete }
        for doneFirst in [false, true] {
            for end in End.allCases {
                let deleted = end != .differentID && end != .failedDelete
                for followUp in ["", Self.nextDraft] where deleted || !followUp.isEmpty {
                    let label = "doneFirst=\(doneFirst), \(end), followUp=\(followUp.utf8.count)"
                    let wire = try StyleHTTP()
                    defer { wire.close() }
                    let (store, api, _) = try await connected(wire, mode: "gateway")
                    let chat = store.chat
                    let reply = try await beginHeldReportSend(store, api: api, wire: wire)
                    try await listHistoryWhileSending(chat, api: api, wire: wire)
                    chat.updateDraftFromUser(followUp)
                    if doneFirst { try await deliverHeldChatDone(reply, chat: chat) }
                    let id = end == .differentID ? "other" : "history"
                    wire.reply("\(sourcePath)/\(id)", method: "DELETE", status: end == .failedDelete ? 503 : 200,
                               body: end == .failedDelete ? #"{"error":"删除失败"}"# : #"{"deleted":"\#(id)"}"#)
                    await chat.remove(id, api: api)
                    if !doneFirst { try await deliverHeldChatDone(reply, chat: chat) }

                    XCTAssertEqual(chat.sending, !deleted, label)
                    XCTAssertEqual(chat.pendingQuestion, deleted ? "" : Self.firstDraft, label)
                    XCTAssertEqual(chat.streamedText, deleted ? "" : "部分回复", label)
                    XCTAssertEqual(chat.sessions.contains { $0.id == "history" }, !deleted, label)
                    switch end {
                    case .disconnect: reply.fail(URLError(.networkConnectionLost))
                    case .stop: chat.stop(); reply.finish()
                    case .reauth:
                        try await rejectNotesRefresh(store, wire: wire)
                        reply.finish()
                        wire.reply("/api/notes", body: Self.initialNotes)
                        try await reauthenticate(store, wire: wire)
                    case .differentID, .failedDelete: reply.finish()
                    }
                    await chat.waitForIdle()
                    XCTAssertEqual(chat.session?.id, deleted ? nil : "history", label)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(followUp.utf8), label)
                    if deleted {
                        XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new", label)
                        XCTAssertTrue(chat.recoverableDraftSnapshot.savedDrafts.isEmpty, label)
                        XCTAssertFalse(chat.useWritingStyle, label)
                        XCTAssertNil(chat.insight, label)
                        try await assertOrdinaryChatSend(followUp, store: store, wire: wire)
                    }
                }
            }
        }
    }

    func testDeletedSourceSession409DetachesToNewChat() async throws {
        enum Conflict: CaseIterable { case sourceOnly, noFollowUp, deletedCurrent, deletedReport, differentID, failedDelete, liveCurrent }
        for scenario in Conflict.allCases {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, note) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            let saved = Self.firstDraft + "\n\n" + Self.nextDraft
            let report: InsightReport?
            if scenario == .deletedCurrent || scenario == .deletedReport {
                report = try await openInsightReport("report", store: store, wire: wire, cited: true)
                chat.updateDraftFromUser(saved)
                store.askAbout(try XCTUnwrap(report))
            } else {
                report = nil
                wire.reply(sourcePath, body: #"{"session":null}"#)
                store.askAbout(note)
                try await eventually("初次查询来源会话返回空") { !chat.loadingSession }
                XCTAssertNil(chat.session)
                XCTAssertEqual(chat.sourceNoteId, note.id)
            }
            chat.useWritingStyle = true
            chat.updateDraftFromUser(Self.firstDraft)
            wire.hold(chatPath)
            chat.send(api: api, options: store.options, profile: store.insights)
            try await eventually("冲突前请求已发送") { wire.waiting(self.chatPath) == 1 }
            let reply = try XCTUnwrap(wire.take(chatPath))
            let posted = try XCTUnwrap(wire.requests(chatPath).first)
            XCTAssertNil(posted["sessionId"])
            XCTAssertEqual(posted["sourceNoteId"] as? String, report == nil ? note.id : nil)
            XCTAssertEqual(posted["referencedNoteIds"] as? [String], [note.id])
            try await listHistoryWhileSending(chat, api: api, wire: wire)
            let id = scenario == .differentID ? "other" : "history"
            let path = "\(sourcePath)/\(id)"
            let deleted = #"{"deleted":"\#(id)"}"#
            if scenario == .sourceOnly {
                wire.hold(path, method: "DELETE")
                let removal = Task { await chat.remove(id, api: api) }
                try await eventually("会话删除等待响应") { wire.waiting(path, method: "DELETE") == 1 }
                wire.reply(sourcePath, body: #"{"sessions":[],"nextCursor":null}"#)
                chat.refreshSessions(api: api)
                try await eventually("列表刷新先于删除回包") { !chat.loadingList && chat.sessions.isEmpty }
                try XCTUnwrap(wire.take(path, method: "DELETE")).complete(body: deleted)
                await removal.value
            } else {
                wire.reply(path, method: "DELETE", status: scenario == .failedDelete ? 503 : 200,
                           body: scenario == .failedDelete ? #"{"error":"删除失败"}"# : deleted)
                await chat.remove(id, api: api)
            }
            let followUp = scenario == .noFollowUp ? "" : Self.nextDraft
            chat.updateDraftFromUser(followUp)
            if scenario == .deletedReport {
                try await confirmReportDeletion(try XCTUnwrap(report), via: .delete200, store: store, api: api, wire: wire)
            }
            switch scenario {
            case .deletedCurrent, .deletedReport:
                reply.complete(status: 409, body: #"{"error":"冲突","current":\#(Self.session)}"#)
            case .liveCurrent:
                let live = Self.session.replacingOccurrences(of: #""id":"history""#, with: #""id":"live""#)
                reply.complete(status: 409, body: #"{"error":"冲突","current":\#(live)}"#)
            default:
                reply.complete(body: Self.sse("error", #"{"status":409,"error":"冲突"}"#), stream: true)
            }
            await chat.waitForIdle()
            let label = "\(scenario)"
            XCTAssertEqual(wire.requests(chatPath).count, 1, label)
            XCTAssertEqual(chat.sessions.contains { $0.id == "history" },
                           scenario == .differentID || scenario == .failedDelete, label)
            if scenario == .differentID || scenario == .failedDelete || scenario == .liveCurrent {
                XCTAssertEqual(chat.session?.id, scenario == .liveCurrent ? "live" : nil, label)
                XCTAssertEqual(chat.sourceNoteId, note.id, label)
                XCTAssertEqual(chat.pins, [note.id], label)
                XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "note:\(note.id)", label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(followUp.utf8), label)
                XCTAssertEqual(chat.error, "冲突", label)
                continue
            }

            let expected: String
            switch scenario {
            case .noFollowUp: expected = Self.firstDraft
            case .deletedCurrent: expected = saved + "\n\n" + followUp
            case .deletedReport: expected = saved + "\n\n" + Self.firstDraft + "\n\n" + followUp
            default: expected = followUp
            }
            XCTAssertNil(chat.session, label)
            XCTAssertNil(chat.sourceNoteId, label)
            XCTAssertNil(chat.insight, label)
            XCTAssertTrue(chat.pins.isEmpty, label)
            XCTAssertFalse(chat.useWritingStyle, label)
            XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), label)
            if scenario == .deletedReport {
                XCTAssertTrue(chat.recoverableDraftSnapshot.requiresDeletedInsightConfirmation, label)
                XCTAssertEqual(chat.error, AIChatStore.deletedInsightReportMessage, label)
                chat.send(api: api, options: store.options, profile: store.insights)
                await chat.waitForIdle()
                XCTAssertEqual(wire.requests(chatPath).count, 1, label)
            } else {
                XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new", label)
                XCTAssertEqual(chat.error, "冲突", label)
            }
            if scenario == .sourceOnly { try await assertDraftSurvivesHistoryRoundTrip(expected, store: store, wire: wire) }
            try await assertOrdinaryChatSend(expected, store: store, wire: wire)
        }
    }

    func testPendingSessionDeletePreservesFollowUpAcrossCleanEOF() async throws {
        for target in DeleteSwitch.allCases {
            for saved in ["", Self.firstDraft + "\n\n" + Self.nextDraft] {
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, _) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                let reply = try await beginHeldReportSend(store, api: api, wire: wire, saved: saved)
                let reportHistory = Self.session.replacingOccurrences(of: #""sourceNoteId":"note","#, with: "")
                wire.reply(sourcePath, body: #"{"sessions":[\#(reportHistory)],"nextCursor":null}"#)
                chat.refreshSessions(api: api)
                try await eventually("报告会话已出现在历史列表") { chat.sessions.map(\.id) == ["history"] }
                let (removal, receipt) = try await beginHeldHistoryDelete(chat, api: api, wire: wire)
                chat.updateDraftFromUser(Self.nextDraft)
                requestSwitchDuringDelete(target, store: store)
                reply.write(Self.sse("done", #"{"session":\#(reportHistory)}"#))
                reply.finish()
                await chat.waitForIdle()

                let label = "\(target), saved=\(saved.utf8.count)"
                XCTAssertEqual(chat.session?.id, "history", label)
                XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "post-delete", label)
                XCTAssertEqual(chat.draft, Self.nextDraft, label)
                receipt.complete(body: #"{"deleted":"history"}"#)
                await removal.value

                let expected = saved.isEmpty ? Self.nextDraft : saved + "\n\n" + Self.nextDraft
                try await assertMigratedDeleteDraft(expected, target: target, store: store, wire: wire)
                try await assertOrdinaryChatSend(expected, store: store, wire: wire)
            }
        }
    }

    func testKnownDoneSessionNeverResendsOriginalQuestionBeforeDeleteAck() async throws {
        enum Ending: CaseIterable { case disconnect, stop, reauth, reauthWithoutDelete, confirmBeforeEOF }
        for ending in Ending.allCases {
            for saved in ["", Self.firstDraft + "\n\n" + Self.nextDraft] {
                for followUp in ["", Self.nextDraft] where ending != .confirmBeforeEOF || !followUp.isEmpty {
                    let wire = try StyleHTTP()
                    defer { wire.close() }
                    let (store, api, _) = try await connected(wire, mode: "gateway")
                    let chat = store.chat
                    let reply = try await beginHeldReportSend(store, api: api, wire: wire, saved: saved)
                    let report = try XCTUnwrap(chat.insight)
                    try await listHistoryWhileSending(chat, api: api, wire: wire)
                    let deleting = ending != .reauthWithoutDelete
                    let deletion = deleting ? try await beginHeldHistoryDelete(chat, api: api, wire: wire) : nil
                    chat.updateDraftFromUser(followUp)
                    try await deliverHeldChatDone(reply, chat: chat)

                    let label = "\(ending), saved=\(saved.utf8.count), followUp=\(followUp.utf8.count)"
                    XCTAssertTrue(chat.sending, label)
                    XCTAssertNil(chat.session, label)
                    let snapshot = chat.recoverableDraftSnapshot
                    XCTAssertEqual(snapshot.activeContextKey, deleting ? "post-delete" : "session:history", label)
                    XCTAssertEqual(snapshot.activeDraft, followUp, label)
                    XCTAssertEqual(snapshot.savedDrafts["new"] ?? "", saved, label)

                    switch ending {
                    case .disconnect: reply.fail(URLError(.networkConnectionLost))
                    case .stop: chat.stop(); reply.finish()
                    case .reauth, .reauthWithoutDelete:
                        try await rejectNotesRefresh(store, wire: wire)
                        if let (removal, receipt) = deletion {
                            await removal.value
                            XCTAssertTrue(receipt.isStopped, label)
                        }
                        reply.finish()
                        wire.reply("/api/notes", body: Self.initialNotes)
                        try await reauthenticate(store, wire: wire)
                    case .confirmBeforeEOF:
                        requestSwitchDuringDelete(.new, store: store)
                        store.confirmChatSwitch()
                        reply.finish()
                    }
                    await chat.waitForIdle()
                    if ending == .disconnect || ending == .stop {
                        XCTAssertEqual(chat.session?.id, "history", label)
                        XCTAssertEqual(chat.draft, followUp, label)
                        XCTAssertEqual(chat.pendingQuestion, "", label)
                        XCTAssertEqual(chat.streamedText, "", label)
                        XCTAssertNil(chat.error, label)
                        XCTAssertFalse(chat.useWritingStyle, label)
                    }
                    if ending != .reauth, let (removal, receipt) = deletion {
                        receipt.complete(body: #"{"deleted":"history"}"#)
                        await removal.value
                    }
                    let parts = deleting ? [saved, followUp] : [saved.isEmpty ? followUp : saved]
                    let expected = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    XCTAssertEqual(chat.draft, ending == .confirmBeforeEOF ? saved : expected, label)
                    store.askAbout(report)
                    XCTAssertEqual(chat.draft, ending == .confirmBeforeEOF ? followUp : "", label)
                    XCTAssertEqual(wire.requests(chatPath).count, 1, label)
                    if ending == .confirmBeforeEOF { continue }
                    store.requestNewChat()
                    try await assertOrdinaryChatSend(expected, store: store, wire: wire)
                }
            }
        }
    }

    func testSourceConflict409BeforeSessionDeleteDetachesToNewChat() async throws {
        enum Deletion: CaseIterable { case succeeded, failed, otherSource }
        for outcome in Deletion.allCases {
            for deleteFirst in [false, true] where !deleteFirst || outcome == .succeeded {
                for saved in ["", Self.firstDraft + "\n\n" + Self.nextDraft] {
                    let wire = try StyleHTTP()
                    defer { wire.close() }
                    let (store, api, note) = try await connected(wire, mode: "gateway")
                    let chat = store.chat
                    let source: Note
                    if outcome == .otherSource {
                        source = Note(id: "note-b", body: "另一条笔记", createdAt: "2026-11-28", revision: 1)
                        await store.replace(with: [note, source], persist: false)
                    } else { source = note }
                    chat.updateDraftFromUser(saved)
                    wire.reply(sourcePath, body: #"{"session":null}"#)
                    store.askAbout(source)
                    try await eventually("来源查询未找到会话") { !chat.loadingSession && chat.session == nil }
                    chat.useWritingStyle = true
                    let reply = try await beginHeldNoteSend(store, api: api, wire: wire, source: source)
                    try await listHistoryWhileSending(chat, api: api, wire: wire)
                    let (removal, receipt) = try await beginHeldHistoryDelete(chat, api: api, wire: wire)
                    chat.updateDraftFromUser(Self.nextDraft)
                    requestSwitchDuringDelete(.new, store: store)

                    if deleteFirst {
                        receipt.complete(body: #"{"deleted":"history"}"#)
                        await removal.value
                    }
                    reply.complete(body: Self.sse("error", #"{"status":409,"error":"该对话已被删除。"}"#), stream: true)
                    await chat.waitForIdle()
                    if !deleteFirst {
                        XCTAssertEqual(chat.sourceNoteId, source.id)
                        XCTAssertEqual(chat.draft, Self.nextDraft)
                        if outcome == .failed { receipt.complete(status: 503, body: #"{"error":"删除失败"}"#) }
                        else { receipt.complete(body: #"{"deleted":"history"}"#) }
                        await removal.value
                    }

                    let label = "\(outcome), deleteFirst=\(deleteFirst), saved=\(saved.utf8.count)"
                    XCTAssertEqual(wire.requests(chatPath).count, 1, label)
                    if outcome == .succeeded {
                        let expected = saved.isEmpty ? Self.nextDraft : saved + "\n\n" + Self.nextDraft
                        try await assertMigratedDeleteDraft(expected, target: .new, store: store, wire: wire)
                        try await assertDraftSurvivesHistoryRoundTrip(expected, store: store, wire: wire)
                        try await assertOrdinaryChatSend(expected, store: store, wire: wire)
                    } else {
                        XCTAssertEqual(chat.sourceNoteId, source.id, label)
                        XCTAssertEqual(chat.pins, [source.id], label)
                        XCTAssertTrue(chat.useWritingStyle, label)
                        XCTAssertEqual(chat.draft, Self.nextDraft, label)
                        XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "note:\(source.id)", label)
                        XCTAssertEqual(chat.recoverableDraftSnapshot.savedDrafts["new"] ?? "", saved, label)
                        XCTAssertEqual(chat.sessions.contains { $0.id == "history" }, outcome == .failed, label)
                    }
                }
            }
        }
    }

    func testLoadedNoteSessionDeleteMigratesInFlightFollowUpToNewChat() async throws {
        let current = Self.session.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
        for saved in ["", Self.firstDraft + "\n\n" + Self.nextDraft] {
            for deleteFirst in [false, true] {
                for target in DeleteSwitch.allCases {
                    let wire = try StyleHTTP()
                    defer { wire.close() }
                    let (store, api, note) = try await connected(wire, mode: "gateway")
                    let chat = store.chat
                    chat.updateDraftFromUser(saved)
                    wire.reply(sourcePath, body: Self.history)
                    store.askAbout(note)
                    try await eventually("笔记加载了历史会话 v1") { !chat.loadingSession && chat.session?.version == 1 }
                    let reply = try await beginHeldNoteSend(store, api: api, wire: wire, source: note)
                    let (removal, receipt) = try await beginHeldHistoryDelete(chat, api: api, wire: wire)
                    chat.updateDraftFromUser(Self.nextDraft)
                    requestSwitchDuringDelete(target, store: store)

                    if deleteFirst {
                        receipt.complete(body: #"{"deleted":"history"}"#)
                        await removal.value
                    }
                    reply.complete(status: 409, body: #"{"error":"版本冲突","current":\#(current)}"#)
                    await chat.waitForIdle()
                    if !deleteFirst {
                        XCTAssertEqual(chat.session?.version, 2)
                        XCTAssertEqual(chat.draft, Self.nextDraft)
                        receipt.complete(body: #"{"deleted":"history"}"#)
                        await removal.value
                    }

                    let expected = saved.isEmpty ? Self.nextDraft : saved + "\n\n" + Self.nextDraft
                    try await assertMigratedDeleteDraft(expected, target: target, store: store, wire: wire)
                    XCTAssertNil(chat.recoverableDraftSnapshot.savedDrafts["note:\(note.id)"])
                    wire.reply(sourcePath, body: #"{"session":null}"#)
                    store.askAbout(note)
                    try await eventually("重开笔记未加载已删除会话") { !chat.loadingSession && chat.session == nil }
                    XCTAssertEqual(chat.draft, "")
                    store.requestNewChat()
                    try await assertOrdinaryChatSend(expected, store: store, wire: wire)
                }
            }

            for startDeleteOutsideNote in [false, true] {
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, note) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                chat.updateDraftFromUser(saved)
                wire.reply(sourcePath, body: Self.history)
                store.askAbout(note)
                try await eventually("笔记加载了历史会话") { !chat.loadingSession && chat.session?.id == "history" }
                chat.updateDraftFromUser(Self.nextDraft)
                if startDeleteOutsideNote { store.requestNewChat() }
                let (removal, receipt) = try await beginHeldHistoryDelete(chat, api: api, wire: wire)
                if startDeleteOutsideNote {
                    store.askAbout(note)
                    try await eventually("删除回执前重新打开笔记") { !chat.loadingSession && chat.session?.id == "history" }
                }
                receipt.complete(body: #"{"deleted":"history"}"#)
                await removal.value
                XCTAssertEqual(chat.draft, saved)
                XCTAssertEqual(chat.recoverableDraftSnapshot.savedDrafts["note:\(note.id)"], Self.nextDraft)
                XCTAssertNil(chat.session)
                XCTAssertNil(chat.sourceNoteId)
                XCTAssertTrue(chat.pins.isEmpty)
            }
        }
    }

    private enum DeleteSwitch: CaseIterable { case none, new, history }

    private func beginHeldHistoryDelete(_ chat: AIChatStore, api: WeijiAPIClient,
                                        wire: StyleHTTP) async throws -> (Task<Void, Never>, StyleProtocol) {
        wire.hold(historyPath, method: "DELETE")
        let removal = Task { await chat.remove("history", api: api) }
        try await eventually("历史会话删除等待回执") { wire.waiting(self.historyPath, method: "DELETE") == 1 }
        return (removal, try XCTUnwrap(wire.take(historyPath, method: "DELETE")))
    }

    private func beginHeldNoteSend(_ store: AppStore, api: WeijiAPIClient, wire: StyleHTTP, source: Note) async throws -> StyleProtocol {
        let chat = store.chat
        let expectedVersion = chat.session?.version
        chat.updateDraftFromUser(Self.firstDraft)
        wire.hold(chatPath)
        chat.send(api: api, options: store.options, profile: store.insights)
        try await eventually("笔记会话发送等待响应") { wire.waiting(self.chatPath) == 1 }
        let body = try XCTUnwrap(wire.requests(chatPath).first)
        XCTAssertEqual(body["sourceNoteId"] as? String, source.id)
        XCTAssertEqual(body["referencedNoteIds"] as? [String], [source.id])
        XCTAssertEqual(body["sessionId"] as? String, expectedVersion.map { _ in "history" })
        XCTAssertEqual(body["expectedVersion"] as? Int, expectedVersion)
        return try XCTUnwrap(wire.take(chatPath))
    }

    private func requestSwitchDuringDelete(_ target: DeleteSwitch, store: AppStore) {
        switch target {
        case .none: XCTAssertNil(store.pendingChatSwitch)
        case .new:
            store.requestNewChat()
            XCTAssertEqual(store.pendingChatSwitch?.isNewChat, true)
        case .history:
            store.requestSelectChatSession("history-a")
            guard case .session("history-a") = store.pendingChatSwitch else { return XCTFail("历史切换应等待确认") }
        }
    }

    private func assertMigratedDeleteDraft(_ expected: String, target: DeleteSwitch, store: AppStore, wire: StyleHTTP,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let chat = store.chat
        XCTAssertFalse(chat.sending, file: file, line: line)
        XCTAssertNil(chat.session, file: file, line: line)
        XCTAssertNil(chat.sourceNoteId, file: file, line: line)
        XCTAssertNil(chat.insight, file: file, line: line)
        XCTAssertTrue(chat.pins.isEmpty, file: file, line: line)
        XCTAssertFalse(chat.sessions.contains { $0.id == "history" }, file: file, line: line)
        XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new", file: file, line: line)
        XCTAssertNil(chat.recoverableDraftSnapshot.savedDrafts["new"], file: file, line: line)
        if target == .history {
            guard case .session("history-a") = store.pendingChatSwitch else {
                return XCTFail("未删除的历史切换仍应可确认", file: file, line: line)
            }
            wire.reply(rewriteHistoryPath, body: Self.rewriteHistoryA)
            store.confirmChatSwitch()
            try await eventually("打开未删除的历史", { !chat.loadingSession && chat.session?.id == "history-a" },
                                 file: file, line: line)
            XCTAssertEqual(chat.draft, "", file: file, line: line)
            store.requestNewChat()
        } else {
            XCTAssertNil(store.pendingChatSwitch, file: file, line: line)
            store.confirmChatSwitch()
        }
        XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), file: file, line: line)
    }

    private func beginHeldReportSend(_ store: AppStore, api: WeijiAPIClient, wire: StyleHTTP,
                                     saved: String = "") async throws -> StyleProtocol {
        let report = try await openInsightReport("report", store: store, wire: wire, cited: true, content: "报告正文片段")
        let chat = store.chat
        chat.updateDraftFromUser(saved)
        store.askAbout(report)
        chat.useWritingStyle = true
        chat.updateDraftFromUser(Self.firstDraft)
        wire.hold(chatPath)
        chat.send(api: api, options: store.options, profile: store.insights)
        try await eventually("报告追问已发送") { wire.waiting(self.chatPath) == 1 }
        let original = try XCTUnwrap(wire.requests(chatPath).first?["message"] as? String)
        XCTAssertEqual(original.utf8.count, 102)
        XCTAssertEqual(Array(original.utf8), Array(AIChatStore.message(Self.firstDraft, insight: report).utf8))
        let reply = try XCTUnwrap(wire.take(chatPath))
        reply.begin(stream: true)
        reply.write(Self.sse("status", #"{"stage":"writing","message":"回复中"}"#)
                    + Self.sse("delta", #"{"text":"部分回复"}"#))
        try await eventually("已显示流式回复") { chat.status == "回复中" && chat.streamedText == "部分回复" }
        return reply
    }

    private func deliverHeldChatDone(_ reply: StyleProtocol, chat: AIChatStore) async throws {
        reply.write(Self.sse("done", Self.history))
        try await eventually("done 已处理，流未关闭") { chat.status == nil }
    }

    private func listHistoryWhileSending(_ chat: AIChatStore, api: WeijiAPIClient, wire: StyleHTTP) async throws {
        let other = #"{"id":"other","title":"另一段对话","version":1,"updatedAt":"2026-11-28","origin":"global","turns":[]}"#
        wire.reply(sourcePath, body: #"{"sessions":[\#(Self.session),\#(other)],"nextCursor":null}"#)
        chat.refreshSessions(api: api)
        try await eventually("发送中历史列表已加载") { !chat.loadingList && chat.sessions.map(\.id) == ["history", "other"] }
    }

    private func assertOrdinaryChatSend(_ expected: String, store: AppStore, wire: StyleHTTP,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = wire.requests(chatPath).count
        let api = try XCTUnwrap(store.api, file: file, line: line)
        let result = #"{"session":{"id":"fresh","title":"新对话","version":1,"updatedAt":"2026-11-28","origin":"global","turns":[]}}"#
        wire.reply(chatPath, body: Self.sse("done", result), stream: true)
        store.chat.send(api: api, options: store.options, profile: store.insights)
        await store.chat.waitForIdle()
        let posts = wire.requests(chatPath)
        XCTAssertEqual(posts.count, before + (expected.isEmpty ? 0 : 1), file: file, line: line)
        if expected.isEmpty { return }
        let post = try XCTUnwrap(posts.dropFirst(before).first, file: file, line: line)
        let message = try XCTUnwrap(post["message"] as? String, file: file, line: line)
        XCTAssertEqual(Array(message.utf8), Array(expected.utf8), file: file, line: line)
        XCTAssertNil(post["sessionId"], file: file, line: line)
        XCTAssertNil(post["sourceNoteId"], file: file, line: line)
        XCTAssertNil(post["useWritingStyle"], file: file, line: line)
        XCTAssertEqual(post["referencedNoteIds"] as? [String], [], file: file, line: line)
    }

    func testConfirmedReportDeletionCancelsWaitingFollowUpAndRestoresBothDrafts() async throws {
        for route in ReportDeletionRoute.allCases {
            for cited in [false, true] {
                let label = "\(route), cited=\(cited)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, _) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                let report = try await openInsightReport("report", store: store, wire: wire, cited: cited)
                store.askAbout(report)
                XCTAssertEqual(chat.pins, cited ? ["note"] : [], label)
                let save = try await holdProfileSave(store, api: api, wire: wire)
                wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
                chat.updateDraftFromUser(Self.firstDraft)
                chat.send(api: api, options: store.options, profile: store.insights)
                XCTAssertTrue(chat.sending, label)
                XCTAssertEqual(chat.pendingQuestion, Self.firstDraft, label)
                chat.updateDraftFromUser(Self.nextDraft)

                try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
                let restored = Self.firstDraft + "\n\n" + Self.nextDraft
                XCTAssertFalse(chat.sending, label)
                XCTAssertNil(chat.insight, label)
                XCTAssertEqual(chat.error, AIChatStore.deletedInsightReportMessage, label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(restored.utf8), label)

                try await finishProfileSave(save, wire: wire)
                await chat.waitForIdle()
                XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
                XCTAssertNil(chat.session, label)
                XCTAssertEqual(chat.error, AIChatStore.deletedInsightReportMessage, label)
                store.requestNewChat()
                XCTAssertEqual(Array(chat.draft.utf8), Array(restored.utf8), label)
            }
        }
    }

    func testReportFollowUpContinuesAfterDispatchOrDeletionOfAnUnrelatedReport() async throws {
        for deleteOtherBeforeDispatch in [false, true] {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            let other = try await openInsightReport("other", store: store, wire: wire)
            let report = try await openInsightReport("report", store: store, wire: wire, cited: true)
            store.askAbout(report)
            let save = deleteOtherBeforeDispatch ? try await holdProfileSave(store, api: api, wire: wire) : nil
            wire.hold(chatPath)
            chat.updateDraftFromUser(Self.firstDraft)
            chat.send(api: api, options: store.options, profile: store.insights)
            if let save {
                try await confirmReportDeletion(other, via: .delete200, store: store, api: api, wire: wire)
                XCTAssertTrue(chat.sending)
                XCTAssertTrue(wire.requests(chatPath).isEmpty)
                try await finishProfileSave(save, wire: wire)
            }
            try await eventually("追问 POST 已发出") { wire.waiting(self.chatPath) == 1 }
            if !deleteOtherBeforeDispatch {
                try await confirmReportDeletion(report, via: .delete200, store: store, api: api, wire: wire)
                XCTAssertTrue(chat.sending)
            }
            let requests = wire.requests(chatPath)
            XCTAssertEqual(requests.count, 1)
            let message = try XCTUnwrap(requests.first?["message"] as? String)
            XCTAssertEqual(Array(message.utf8), Array(AIChatStore.message(Self.firstDraft, insight: report).utf8))
            XCTAssertEqual(requests.first?["referencedNoteIds"] as? [String], ["note"])
            try XCTUnwrap(wire.take(chatPath)).complete(body: Self.sse("done", Self.history), stream: true)
            await chat.waitForIdle()
            XCTAssertEqual(chat.session?.id, "history")
            XCTAssertEqual(chat.draft, "")
            XCTAssertNil(chat.error)
        }
    }

    func testReportDeletionCancelsFollowUpWhileTheAPIActorIsBusy() async throws {
        enum Scenario: CaseIterable { case queuedSameReport, queuedOtherReport, alreadySent }
        let typed = Self.firstDraft
        let body = "报告正文片段"
        let expected = "[洞察上下文：洞察（回顾）]\n\(body)\n\n[追问]\n" + typed
        XCTAssertEqual([typed, expected].map { $0.utf8.count }, [34, 102])
        for scenario in Scenario.allCases {
            let label = "\(scenario)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            let report = InsightReport(id: "report", title: "洞察", lensName: "回顾", content: body, excerpt: nil,
                                       citations: [.init(ref: "1", noteId: "note", excerpt: "原句")], createdAt: "2026-11-28")
            store.askAbout(report)
            chat.updateDraftFromUser(typed)
            chat.toggleWritingStyle(isRelayMode: false)
            wire.hold(chatPath)

            let queued = scenario != .alreadySent
            let encoder = HeldRequestBody()
            defer { encoder.release.signal() }
            var otherRequest: Task<ProfileResponse, Error>?
            if queued {
                let path = profilePath
                wire.reply(path, method: "POST", body: #"{"profile":null}"#)
                otherRequest = Task.detached { try await api.post(path, encoder) }
                try await eventually("API actor 正在编码另一条请求") { encoder.isEncoding }
            }
            var relayChecks = 0
            chat.send(api: api, options: store.options, profile: store.insights, isRelayMode: {
                relayChecks += 1
                return store.isRelayMode
            })
            if queued {
                try await eventually("聊天已结清保存并尝试交接 API actor") { relayChecks >= 2 }
            } else {
                try await eventually("聊天请求已抵达传输层") { wire.waiting(self.chatPath) == 1 }
            }
            let id = scenario == .queuedOtherReport ? "other" : report.id
            wire.reply("\(reportsPath)/\(id)", method: "DELETE", body: #"{"deleted":"\#(id)"}"#)
            // A separate connection can confirm the deletion while the chat client is occupied.
            let deleted = await store.insights.deleteReport(id, api: queued ? wire.api() : api)
            XCTAssertTrue(deleted, label)
            XCTAssertEqual(wire.requests(chatPath).count, queued ? 0 : 1, label)
            XCTAssertEqual(chat.sending, scenario != .queuedSameReport, label)

            encoder.release.signal()
            if let otherRequest { _ = try await otherRequest.value }
            try await eventually("聊天已取消或抵达传输层") { !chat.sending || wire.waiting(self.chatPath) == 1 }
            if let reply = wire.take(chatPath) { reply.complete(body: Self.sse("done", Self.history), stream: true) }
            await chat.waitForIdle()
            let posts = wire.requests(chatPath)
            if scenario == .queuedSameReport {
                XCTAssertTrue(posts.isEmpty, label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                XCTAssertEqual(chat.error, AIChatStore.deletedInsightReportMessage, label)
                XCTAssertNil(chat.session, label)
            } else {
                XCTAssertEqual(posts.count, 1, label)
                let message = try XCTUnwrap(posts.first?["message"] as? String)
                XCTAssertEqual(Array(message.utf8), Array(expected.utf8), label)
                XCTAssertEqual(posts.first?["referencedNoteIds"] as? [String], ["note"], label)
                XCTAssertEqual(chat.session?.id, "history", label)
            }
        }
    }

    func testSendDispatchGateLinearizesDeletedInsightAndQueuedSaves() async throws {
        enum DeletionTiming: CaseIterable { case firstQueue, retryQueue, alreadySent, unrelated }
        let report = InsightReport(id: "report", title: "洞察", lensName: "回顾", content: "报告正文片段", excerpt: nil,
                                   citations: [.init(ref: "1", noteId: "note", excerpt: "原句")], createdAt: "2026-11-28")
        let typed = Self.firstDraft
        let reportQuestion = AIChatStore.message(typed, insight: report)
        XCTAssertEqual([typed.utf8.count, reportQuestion.utf8.count], [34, 102])
        for timing in DeletionTiming.allCases {
            let label = "\(timing)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            store.askAbout(report)
            chat.updateDraftFromUser(typed)
            chat.toggleWritingStyle(isRelayMode: false)
            wire.hold(chatPath)

            let first = HeldRequestBody(), second = HeldRequestBody()
            defer { first.release.signal(); second.release.signal() }
            let firstJob = timing == .alreadySent ? nil : try await occupyAPIActor(api, wire: wire, encoder: first)
            var checks = 0
            chat.send(api: api, options: store.options, profile: store.insights, isRelayMode: {
                checks += 1
                return store.isRelayMode
            })
            try await eventually("首次聊天尝试已到达交接检查") { checks >= 2 }
            var secondJob: Task<ProfileResponse, Error>?
            if timing == .retryQueue {
                wire.hold(profilePath, method: "POST")
                let save = try XCTUnwrap(store.insights.saveProfile(.init(content: "新画像", enabled: true), api: wire.api()))
                try await eventually("新画像保存已发出") { wire.waiting(self.profilePath, method: "POST") == 1 }
                let profileReply = try XCTUnwrap(wire.take(profilePath, method: "POST"))
                first.release.signal()
                _ = try await firstJob?.value
                try await assertChatDeferredForSave(chat, wire: wire)
                secondJob = try await occupyAPIActor(api, wire: wire, encoder: second)
                profileReply.complete(body: #"{"profile":null}"#)
                let saved = await save.value
                XCTAssertTrue(saved)
                try await eventually("保存完成，聊天再次排队") { checks >= 3 }
            }
            if timing == .alreadySent {
                try await eventually("聊天已抵达传输层") { wire.waiting(self.chatPath) == 1 }
            } else {
                XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
            }

            let id = timing == .unrelated ? "other" : report.id
            wire.reply("\(reportsPath)/\(id)", method: "DELETE", body: #"{"deleted":"\#(id)"}"#)
            let removed = await store.insights.deleteReport(id, api: wire.api())
            XCTAssertTrue(removed, label)
            first.release.signal()
            second.release.signal()
            _ = try await firstJob?.value
            _ = try await secondJob?.value
            try await eventually("聊天取消或抵达传输层") { !chat.sending || wire.waiting(self.chatPath) == 1 }
            if let reply = wire.take(chatPath) { reply.complete(body: Self.sse("done", Self.history), stream: true) }
            await chat.waitForIdle()

            let posts = wire.requests(chatPath)
            if timing == .firstQueue || timing == .retryQueue {
                XCTAssertTrue(posts.isEmpty, label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                XCTAssertEqual(chat.error, AIChatStore.deletedInsightReportMessage, label)
                XCTAssertNil(chat.session, label)
            } else {
                XCTAssertEqual(posts.count, 1, label)
                let message = try XCTUnwrap(posts.first?["message"] as? String)
                XCTAssertEqual(Array(message.utf8), Array(reportQuestion.utf8), label)
                XCTAssertEqual(posts.first?["referencedNoteIds"] as? [String], ["note"], label)
                XCTAssertEqual(chat.session?.id, "history", label)
            }
        }

        for path in [profilePath, stylePath] {
            for succeeds in [true, false] {
                let label = "\(path), success=\(succeeds)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let api = wire.api(), insights = InsightsStore(), chat = AIChatStore()
                wire.reply(stylePath, body: Self.styleEnvelope)
                await insights.loadWritingStyle(api: api)
                chat.start(pins: ["note"], insight: report, useWritingStyle: true)
                chat.updateDraftFromUser(typed)
                wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)

                let encoder = HeldRequestBody()
                defer { encoder.release.signal() }
                let job = try await occupyAPIActor(api, wire: wire, encoder: encoder)
                var checks = 0
                chat.send(api: api, options: .init(), profile: insights, isRelayMode: { checks += 1; return false })
                try await eventually("初始保存检查通过，聊天已排队") { checks >= 2 }
                let save: Task<Bool, Never>
                if path == profilePath {
                    save = try XCTUnwrap(insights.saveProfile(.init(content: "新画像", enabled: true), api: api))
                } else {
                    save = try XCTUnwrap(insights.saveWritingStyle(.init(rules: "新规则"), api: api))
                }
                encoder.release.signal()
                _ = try await job.value
                try await eventually("排队期间启动的保存已出站") { wire.waiting(path, method: "POST") == 1 }
                try await assertChatDeferredForSave(chat, wire: wire)

                let successBody = path == profilePath ? #"{"profile":null}"# : Self.styleEnvelope
                try XCTUnwrap(wire.take(path, method: "POST")).complete(status: succeeds ? 200 : 503,
                      body: succeeds ? successBody : #"{"error":"保存失败"}"#)
                let saved = await save.value
                XCTAssertEqual(saved, succeeds, label)
                await chat.waitForIdle()
                let posts = wire.requests(chatPath)
                XCTAssertEqual(posts.count, succeeds ? 1 : 0, label)
                if succeeds {
                    let message = try XCTUnwrap(posts.first?["message"] as? String)
                    XCTAssertEqual(Array(message.utf8), Array(reportQuestion.utf8), label)
                    XCTAssertEqual(chat.session?.id, "history", label)
                } else {
                    XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                    XCTAssertTrue(chat.error?.contains("保存失败") == true, label)
                }
            }
        }
    }

    private func occupyAPIActor(_ api: WeijiAPIClient, wire: StyleHTTP, encoder: HeldRequestBody) async throws -> Task<ProfileResponse, Error> {
        let path = "/api/actor-fixture"
        wire.reply(path, method: "POST", body: #"{"profile":null}"#)
        let job = Task.detached { () throws -> ProfileResponse in try await api.post(path, encoder) }
        try await eventually("API actor 正在编码夹具请求") { encoder.isEncoding }
        return job
    }

    private func assertChatDeferredForSave(_ chat: AIChatStore, wire: StyleHTTP) async throws {
        // Observe the attempt retiring so the fixture keeps the save in flight at the handoff.
        try await eventually("聊天已尝试交接，仍等保存结清") {
            Mirror(reflecting: chat).descendant("pendingDispatchGate", "some") == nil || !wire.requests(self.chatPath).isEmpty
        }
        XCTAssertTrue(chat.sending)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
    }

    func testDeletedInsightConfirmationSurvivesReauthAndFailedDispatch() async throws {
        let typed = Self.firstDraft
        let warning = AIChatStore.deletedInsightReportMessage
        let modes: [(failure: Int?, switchToNew: Bool)] = [(nil, false), (401, false), (503, false), (409, false), (503, true)]
        for route in ReportDeletionRoute.allCases {
            for (failure, switchToNew) in modes {
                let label = "\(route), failure=\(String(describing: failure)), new=\(switchToNew)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, _) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                let report = try await openInsightReport("report", store: store, wire: wire, cited: true, content: "报告正文片段")
                store.askAbout(report)
                chat.updateDraftFromUser(typed)
                var firstReply: StyleProtocol?
                if failure != nil {
                    wire.hold(chatPath)
                    chat.send(api: api, options: store.options, profile: store.insights)
                    try await eventually("原报告追问已抵达传输层") { wire.waiting(self.chatPath) == 1 }
                    let post = try XCTUnwrap(wire.requests(chatPath).first)
                    let message = try XCTUnwrap(post["message"] as? String)
                    XCTAssertEqual(message.utf8.count, 102, label)
                    XCTAssertEqual(Array(message.utf8), Array(AIChatStore.message(typed, insight: report).utf8), label)
                    XCTAssertEqual(post["referencedNoteIds"] as? [String], ["note"], label)
                    firstReply = try XCTUnwrap(wire.take(chatPath))
                }
                try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
                if let failure {
                    XCTAssertTrue(chat.sending, label)
                    let body = failure == 409 ? #"{"error":"冲突","current":\#(Self.session)}"# : #"{"error":"暂时不可用"}"#
                    try XCTUnwrap(firstReply).complete(status: failure, body: body)
                    await chat.waitForIdle()
                } else {
                    try await rejectNotesRefresh(store, wire: wire)
                }
                if failure == nil || failure == 401 {
                    wire.reply("/api/notes", body: Self.initialNotes)
                    try await reauthenticate(store, wire: wire)
                }
                XCTAssertEqual(chat.error, warning, label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                let base = failure == nil ? 0 : 1
                XCTAssertEqual(wire.requests(chatPath).count, base, label)
                let currentAPI = try XCTUnwrap(store.api)
                wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
                if switchToNew {
                    store.requestNewChat()
                } else {
                    chat.send(api: currentAPI, options: store.options, profile: store.insights)
                    await chat.waitForIdle()
                    XCTAssertEqual(wire.requests(chatPath).count, base, label)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                    XCTAssertEqual(chat.error, warning, label)
                }
                chat.send(api: currentAPI, options: store.options, profile: store.insights)
                await chat.waitForIdle()
                let posts = wire.requests(chatPath)
                XCTAssertEqual(posts.count, base + 1, label)
                let ordinary = try XCTUnwrap(posts.last?["message"] as? String)
                XCTAssertEqual(Array(ordinary.utf8), Array(typed.utf8), label)
                XCTAssertNil(chat.error, label)
            }
        }
    }

    func testReauthDeletedInsightFirstNewChatPreservesDraft() async throws {
        enum Recovery: CaseIterable { case once, identity401, notes401, chat503, chat409, disconnect, otherAccount }
        enum Choice: CaseIterable { case newChat, retry, historyRoundTrip, newChatTwice }
        let typed = Self.firstDraft
        let savedNew = typed + "\n\n" + Self.nextDraft
        let warning = AIChatStore.deletedInsightReportMessage
        let scenarios: [(ReportDeletionRoute, Recovery, String)] = ReportDeletionRoute.allCases.flatMap {
            [($0, .once, ""), ($0, .notes401, "")]
        } + Recovery.allCases.map { (.delete200, $0, savedNew) }

        for (route, recovery, background) in scenarios {
            let choices: [Choice] = recovery == .otherAccount ? [.newChat]
                : (route == .delete200 && recovery == .once ? Choice.allCases : [.newChat, .retry])
            for choice in choices {
                let label = "\(route), \(recovery), \(choice), saved=\(background.utf8.count)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, _) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                let report = try await openInsightReport("report", store: store, wire: wire, cited: true, content: "报告正文片段")
                chat.updateDraftFromUser(background)
                store.askAbout(report)
                chat.updateDraftFromUser(typed)

                let dispatched = recovery == .chat503 || recovery == .chat409 || recovery == .disconnect
                if dispatched {
                    wire.hold(chatPath)
                    chat.send(api: api, options: store.options, profile: store.insights)
                    try await eventually("报告追问已出站") { wire.waiting(self.chatPath) == 1 }
                }
                try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
                if dispatched {
                    let original = try XCTUnwrap(wire.requests(chatPath).first?["message"] as? String, label)
                    XCTAssertEqual(original.utf8.count, 102, label)
                    XCTAssertEqual(Array(original.utf8), Array(AIChatStore.message(typed, insight: report).utf8), label)
                    let reply = try XCTUnwrap(wire.take(chatPath), label)
                    if recovery == .disconnect {
                        reply.begin(stream: true)
                        reply.fail(URLError(.networkConnectionLost))
                    } else {
                        reply.complete(status: recovery == .chat503 ? 503 : 409, body: #"{"error":"发送失败"}"#)
                    }
                    await chat.waitForIdle()
                }
                try await rejectNotesRefresh(store, wire: wire)
                if recovery == .identity401 || recovery == .notes401 {
                    let path = recovery == .identity401 ? "/api/session" : "/api/notes"
                    let before = wire.requests(path).count
                    wire.reply(path, status: 401, body: Self.expired)
                    let expired = try ServerConfiguration(address: wire.config.origin, token: "second-expired-test-token")
                    store.connect(expired, save: false)
                    try await eventually("重登途中第二次 401") {
                        wire.requests(path).count == before + 1 && store.authScreenState == .needsLogin && !store.syncing
                    }
                }

                let otherAccount = recovery == .otherAccount
                let userId = otherAccount ? "another-account" : "account"
                wire.reply("/api/session", body: #"{"user":{"id":"\#(userId)","name":"测试账户"},"codexAvailable":true,"codexMode":"gateway"}"#)
                wire.reply("/api/notes", body: Self.initialNotes)
                try await reauthenticate(store, wire: wire)

                let recovered = otherAccount ? "" : (background.isEmpty ? typed : background + "\n\n" + typed)
                let priorPosts = dispatched ? 1 : 0
                XCTAssertEqual(Array(chat.draft.utf8), Array(recovered.utf8), label)
                XCTAssertEqual(chat.error, otherAccount ? nil : warning, label)
                XCTAssertEqual(wire.requests(chatPath).count, priorPosts, label)
                let currentAPI = try XCTUnwrap(store.api, label)
                wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
                switch choice {
                case .newChat, .newChatTwice:
                    store.requestNewChat()
                    XCTAssertEqual(Array(chat.draft.utf8), Array(recovered.utf8), label)
                    XCTAssertNil(chat.error, label)
                    if choice == .newChatTwice {
                        store.requestNewChat()
                        XCTAssertEqual(chat.draft, "", label)
                        chat.send(api: currentAPI, options: store.options, profile: store.insights)
                        await chat.waitForIdle()
                        XCTAssertEqual(wire.requests(chatPath).count, priorPosts, label)
                        continue
                    }
                case .retry:
                    chat.send(api: currentAPI, options: store.options, profile: store.insights)
                    await chat.waitForIdle()
                    XCTAssertEqual(wire.requests(chatPath).count, priorPosts, label)
                    XCTAssertEqual(chat.error, warning, label)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(recovered.utf8), label)
                case .historyRoundTrip:
                    try await assertDraftSurvivesHistoryRoundTrip(recovered, store: store, wire: wire)
                    XCTAssertNil(chat.error, label)
                }
                if otherAccount { chat.updateDraftFromUser(Self.nextDraft) }
                chat.send(api: currentAPI, options: store.options, profile: store.insights)
                await chat.waitForIdle()
                let posts = wire.requests(chatPath)
                XCTAssertEqual(posts.count, priorPosts + 1, label)
                let post = try XCTUnwrap(posts.last, label)
                let message = try XCTUnwrap(post["message"] as? String, label)
                XCTAssertEqual(Array(message.utf8), Array((otherAccount ? Self.nextDraft : recovered).utf8), label)
                XCTAssertNil(post["sessionId"], label)
                XCTAssertNil(chat.error, label)
            }
        }
    }

    func testReauthDeletedInsightAfterBlockedTapFirstNewChatPreservesDraft() async throws {
        let saved = Self.firstDraft + "\n\n" + Self.nextDraft
        for route in ReportDeletionRoute.allCases {
            for background in ["", saved] {
                for reauthBeforeTap in [false, true] {
                    let label = "\(route), saved=\(background.utf8.count), relogBeforeTap=\(reauthBeforeTap)"
                    let wire = try StyleHTTP()
                    defer { wire.close() }
                    let (store, api, _) = try await connected(wire, mode: "gateway")
                    let chat = store.chat
                    let report = try await openInsightReport("report", store: store, wire: wire, cited: true)
                    chat.updateDraftFromUser(background)
                    store.askAbout(report)
                    chat.updateDraftFromUser(Self.firstDraft)
                    try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
                    if reauthBeforeTap {
                        try await rejectNotesRefresh(store, wire: wire)
                        wire.reply("/api/notes", body: Self.initialNotes)
                        try await reauthenticate(store, wire: wire)
                    }

                    chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
                    await chat.waitForIdle()
                    XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
                    XCTAssertEqual(chat.error, AIChatStore.deletedInsightReportMessage, label)
                    XCTAssertFalse(chat.recoverableDraftSnapshot.requiresDeletedInsightConfirmation, label)
                    try await rejectNotesRefresh(store, wire: wire)
                    wire.reply("/api/notes", body: Self.initialNotes)
                    try await reauthenticate(store, wire: wire)

                    let expected = background.isEmpty ? Self.firstDraft : background + "\n\n" + Self.firstDraft
                    XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), label)
                    store.requestNewChat()
                    XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new", label)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8), label)
                    XCTAssertNil(chat.error, label)
                    if route == .delete200 && reauthBeforeTap {
                        store.requestNewChat()
                        XCTAssertEqual(chat.draft, "", label)
                        try await assertOrdinaryChatSend("", store: store, wire: wire)
                    } else {
                        try await assertOrdinaryChatSend(expected, store: store, wire: wire)
                    }
                }
            }
        }

        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, _, _) = try await connected(wire, mode: "gateway")
        store.chat.updateDraftFromUser(saved)
        try await rejectNotesRefresh(store, wire: wire)
        wire.reply("/api/notes", body: Self.initialNotes)
        try await reauthenticate(store, wire: wire)
        XCTAssertEqual(Array(store.chat.draft.utf8), Array(saved.utf8))
        store.requestNewChat()
        XCTAssertEqual(store.chat.draft, "")
        try await assertOrdinaryChatSend("", store: store, wire: wire)
    }

    func testStoppedDispatchedDeletedInsightRequiresConfirmationBeforeRetry() async throws {
        enum Action { case retry, newAfterStop, reauthRetry, reauthNew, confirmNew, confirmHistory, waitingSave, unrelated }
        let scenarios: [(ReportDeletionRoute, Action, Bool)] = ReportDeletionRoute.allCases.flatMap {
            [($0, .retry, false), ($0, .retry, true), ($0, .waitingSave, true)]
        } + [(.delete200, .newAfterStop, false), (.delete200, .reauthRetry, false), (.delete200, .reauthNew, true),
             (.delete200, .confirmNew, true), (.delete200, .confirmHistory, true), (.delete200, .unrelated, false)]
        let warning = AIChatStore.deletedInsightReportMessage
        for (route, action, followUp) in scenarios {
            let label = "\(route), \(action), followUp=\(followUp)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            let report = try await openInsightReport("report", store: store, wire: wire, cited: true, content: "报告正文片段")
            let deleted = action == .unrelated ? try await openInsightReport("other", store: store, wire: wire) : report
            store.askAbout(report)
            let save = action == .waitingSave ? try await holdProfileSave(store, api: api, wire: wire) : nil
            wire.hold(chatPath)
            chat.updateDraftFromUser(Self.firstDraft)
            chat.send(api: api, options: store.options, profile: store.insights)
            if save != nil {
                XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
            } else {
                try await eventually("原报告追问已抵达传输层") { wire.waiting(self.chatPath) == 1 }
                let request = try XCTUnwrap(wire.requests(chatPath).first, label)
                let original = try XCTUnwrap(request["message"] as? String, label)
                XCTAssertEqual(original.utf8.count, 102, label)
                XCTAssertEqual(Array(original.utf8), Array(AIChatStore.message(Self.firstDraft, insight: report).utf8), label)
                XCTAssertEqual(request["referencedNoteIds"] as? [String], ["note"], label)
            }
            if followUp { chat.updateDraftFromUser(Self.nextDraft) }
            try await confirmReportDeletion(deleted, via: route, store: store, api: api, wire: wire)
            XCTAssertEqual(chat.sending, save == nil, label)

            let restored = followUp ? Self.firstDraft + "\n\n" + Self.nextDraft : Self.firstDraft
            switch action {
            case .confirmNew:
                store.requestNewChat()
                XCTAssertTrue(store.pendingChatSwitch?.isNewChat == true, label)
                store.confirmChatSwitch()
                XCTAssertNil(chat.error, label)
            case .confirmHistory:
                wire.reply(historyPath, body: Self.history)
                store.requestSelectChatSession("history")
                guard case .session("history") = store.pendingChatSwitch else {
                    XCTFail("应先确认切换历史会话：\(label)")
                    continue
                }
                store.confirmChatSwitch()
                XCTAssertNil(chat.error, label)
                try await eventually("历史会话已加载") { !chat.loadingSession && chat.session?.id == "history" }
                XCTAssertEqual(chat.draft, "", label)
                store.requestNewChat()
            case .waitingSave:
                try await finishProfileSave(try XCTUnwrap(save, label), wire: wire)
                XCTAssertEqual(chat.error, warning, label)
            default:
                chat.stop()
                XCTAssertEqual(chat.error, action == .unrelated ? nil : warning, label)
            }
            await chat.waitForIdle()
            XCTAssertFalse(chat.sending, label)
            XCTAssertEqual(Array(chat.draft.utf8), Array(restored.utf8), label)
            let priorPosts = save == nil ? 1 : 0
            XCTAssertEqual(wire.requests(chatPath).count, priorPosts, label)

            if action == .reauthRetry || action == .reauthNew {
                try await rejectNotesRefresh(store, wire: wire)
                wire.reply("/api/notes", body: Self.initialNotes)
                try await reauthenticate(store, wire: wire)
                XCTAssertEqual(Array(chat.draft.utf8), Array(restored.utf8), label)
                XCTAssertEqual(chat.error, warning, label)
            }
            if action == .newAfterStop || action == .reauthNew {
                store.requestNewChat()
                XCTAssertNil(chat.error, label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(restored.utf8), label)
            }
            let currentAPI = try XCTUnwrap(store.api, label)
            wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
            if action == .retry || action == .reauthRetry {
                chat.send(api: currentAPI, options: store.options, profile: store.insights)
                await chat.waitForIdle()
                XCTAssertEqual(wire.requests(chatPath).count, priorPosts, label)
                XCTAssertEqual(Array(chat.draft.utf8), Array(restored.utf8), label)
                XCTAssertEqual(chat.error, warning, label)
            }
            chat.send(api: currentAPI, options: store.options, profile: store.insights)
            await chat.waitForIdle()
            let posts = wire.requests(chatPath)
            XCTAssertEqual(posts.count, priorPosts + 1, label)
            let retry = try XCTUnwrap(posts.last, label)
            let message = try XCTUnwrap(retry["message"] as? String, label)
            let expected = action == .unrelated ? AIChatStore.message(restored, insight: report) : restored
            XCTAssertEqual(Array(message.utf8), Array(expected.utf8), label)
            XCTAssertNil(retry["sessionId"], label)
            XCTAssertNil(chat.error, label)
        }
    }

    func testDeletingReportBeforeFirstTapWarnsAndRequiresAnExplicitOrdinarySend() async throws {
        let typed = Self.firstDraft
        let warning = AIChatStore.deletedInsightReportMessage
        for route in ReportDeletionRoute.allCases {
            for cited in [false, true] {
                for startNew in [false, true] {
                    let label = "\(route), cited=\(cited), new=\(startNew)"
                    let wire = try StyleHTTP()
                    defer { wire.close() }
                    let (store, api, _) = try await connected(wire, mode: "gateway")
                    let chat = store.chat
                    let report = try await openInsightReport("report", store: store, wire: wire, cited: cited)
                    store.askAbout(report)
                    chat.updateDraftFromUser(typed)
                    wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
                    try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
                    XCTAssertNil(chat.insight, label)
                    XCTAssertEqual(chat.error, warning, label)
                    XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                    if startNew {
                        store.requestNewChat()
                        XCTAssertNil(chat.error, label)
                        XCTAssertEqual(chat.recoverableDraftSnapshot.activeContextKey, "new", label)
                        XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                    } else {
                        chat.send(api: api, options: store.options, profile: store.insights)
                        await chat.waitForIdle()
                        XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
                        XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), label)
                        XCTAssertEqual(chat.error, warning, label)
                        if route == .open404 {
                            try await confirmReportDeletion(report, via: .delete404, store: store, api: api, wire: wire)
                        }
                    }
                    chat.send(api: api, options: store.options, profile: store.insights)
                    await chat.waitForIdle()
                    let posts = wire.requests(chatPath)
                    XCTAssertEqual(posts.count, 1, label)
                    let message = try XCTUnwrap(posts.first?["message"] as? String)
                    XCTAssertEqual(Array(message.utf8), Array(typed.utf8), label)
                    XCTAssertNil(chat.error, label)
                }
            }
        }
    }

    func testLateInsightResultCannotRestoreAConfirmedDeletedReport() async throws {
        enum Outcome { case deleted(ReportDeletionRoute), failedDelete, differentID }
        let outcomes = ReportDeletionRoute.allCases.map(Outcome.deleted) + [.failedDelete, .differentID]
        for outcome in outcomes {
            let label = "\(outcome)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let insights = store.insights
            let report = try await openInsightReport("report", store: store, wire: wire)
            store.askAbout(report)
            store.chat.updateDraftFromUser(Self.firstDraft)
            store.requestNewChat()

            wire.hold(runReportPath, method: "POST")
            insights.run(api: api, options: store.options)
            try await eventually("洞察生成 POST 已发出") { wire.waiting(self.runReportPath, method: "POST") == 1 }
            let stream = try XCTUnwrap(wire.take(runReportPath, method: "POST"))
            stream.begin(stream: true)
            stream.write(Self.sse("delta", #"{"text":"部分内容"}"#))
            try await eventually("已显示流式内容") { insights.liveReportText == "部分内容" }

            var deleted = false
            let path = "\(reportsPath)/\(report.id)"
            switch outcome {
            case .deleted(let route):
                try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
                deleted = true
                XCTAssertFalse(insights.reports.contains { $0.id == report.id }, label)
            case .failedDelete:
                wire.reply(path, method: "DELETE", status: 500, body: #"{"error":"稍后再试"}"#)
                let success = await insights.deleteReport(report.id, api: api)
                XCTAssertFalse(success)
            case .differentID:
                wire.reply("\(reportsPath)/other", method: "DELETE", body: #"{"deleted":"other"}"#)
                let success = await insights.deleteReport("other", api: api)
                XCTAssertTrue(success)
            }
            let envelope = #"{"report":\#(Self.reportJSON(report.id))}"#
            stream.write(Self.sse("done", envelope))
            stream.finish()
            try await eventually("洞察生成流已结束") { !insights.running }
            XCTAssertEqual(insights.liveReport?.id, deleted ? nil : report.id, label)
            XCTAssertEqual(insights.liveReportText, deleted ? "" : "正文", label)
            XCTAssertEqual(insights.reports.map(\.id), deleted ? [] : [report.id], label)
            XCTAssertNil(insights.liveReportError, label)
        }
    }

    func testReportDoneFrameClearsDeletedPreviewEvenWhenTheStreamDisconnects() async throws {
        let preview = "部分内容预览 "
        let fullPreview = preview + "!"
        XCTAssertEqual(fullPreview.utf8.count, 20)
        let cases: [(route: ReportDeletionRoute?, matches: Bool, doneFirst: Bool)] =
            ReportDeletionRoute.allCases.flatMap { [(Optional($0), true, false), (Optional($0), true, true)] }
            + [(.delete200, false, true), (nil, true, true)]
        for (route, matches, doneFirst) in cases {
            let label = "\(String(describing: route)), matching=\(matches), doneFirst=\(doneFirst)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let insights = store.insights
            let report = try await openInsightReport("report", store: store, wire: wire)
            store.askAbout(report)
            store.chat.updateDraftFromUser(Self.firstDraft)
            wire.hold(runReportPath, method: "POST")
            insights.run(api: api, options: store.options)
            try await eventually("洞察生成 POST 已发出") { wire.waiting(self.runReportPath, method: "POST") == 1 }
            let stream = try XCTUnwrap(wire.take(runReportPath, method: "POST"))
            stream.begin(stream: true)
            stream.write(Self.sse("delta", #"{"text":"\#(preview)"}"#))
            try await eventually("已显示流式预览") { insights.liveReportText == preview }

            let id = matches ? report.id : "other"
            let done = Self.sse("done", #"{"report":\#(Self.reportJSON(id))}"#)
            if doneFirst {
                // A following frame makes receipt of done observable before the socket closes.
                stream.write(done + Self.sse("delta", #"{"text":"!"}"#))
                try await eventually("已处理 done 及紧随的帧") { insights.liveReportText == fullPreview }
            }
            if let route {
                try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
            }
            if !doneFirst { stream.write(done) }
            let deleted = route != nil && matches
            if deleted {
                try await eventually("断线前已清除已删报告预览") { insights.liveReportText.isEmpty }
            }
            stream.fail(URLError(.networkConnectionLost))
            try await eventually("洞察流已断线") { !insights.running }
            XCTAssertNil(insights.liveReport, label)
            let expectedError: String? = deleted
                ? (doneFirst && route != .delete200 ? "报告不存在" : nil)
                : WeijiAPIError.network(URLError(.networkConnectionLost)).localizedDescription
            XCTAssertEqual(insights.liveReportError, expectedError, label)
            XCTAssertEqual(Array(insights.liveReportText.utf8), Array((deleted ? "" : fullPreview).utf8), label)
            if deleted { XCTAssertFalse(insights.reports.contains { $0.id == report.id }, label) }
            XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
        }
    }

    func testLiveReportDeletionRetiresThePreviewAndPreservesThe404Reason() async throws {
        enum Timing: CaseIterable { case afterFailure, afterStop, beforeFailure, unknownSource, differentSource }
        let preview = "部分内容预览 !"
        XCTAssertEqual(preview.utf8.count, 20)
        let connectionLost = URLError(.networkConnectionLost)
        let networkMessage = WeijiAPIError.network(connectionLost).localizedDescription
        for route in ReportDeletionRoute.allCases {
            for timing in Timing.allCases {
                let label = "\(route), \(timing)"
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, _) = try await connected(wire, mode: "gateway")
                let insights = store.insights
                let report = try await openInsightReport("report", store: store, wire: wire)
                store.askAbout(report)
                store.chat.updateDraftFromUser(Self.firstDraft)
                wire.hold(runReportPath, method: "POST")
                insights.run(api: api, options: store.options)
                try await eventually("报告生成已出站") { wire.waiting(self.runReportPath, method: "POST") == 1 }
                let stream = try XCTUnwrap(wire.take(runReportPath, method: "POST"))
                stream.begin(stream: true)
                stream.write(Self.sse("delta", #"{"text":"\#(preview)"}"#))
                try await eventually("20 字节预览已经显示") { insights.liveReportText == preview }
                if timing != .unknownSource {
                    let id = timing == .differentSource ? "other" : report.id
                    stream.write(Self.sse("done", #"{"report":\#(Self.reportJSON(id))}"#))
                    // Wait for the terminal frame without ending the stream or injecting a later frame.
                    try await eventually("done 已关联预览来源") {
                        Mirror(reflecting: insights).descendant("liveRunReportId", "some") as? String == id
                    }
                }
                let deletionMessage = route == .delete200 ? nil : "报告不存在"
                if timing == .beforeFailure {
                    try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
                    XCTAssertEqual(insights.liveReportError, deletionMessage, label)
                    XCTAssertEqual(insights.liveReportText, "", label)
                    XCTAssertTrue(insights.running, label)
                }
                if timing == .afterStop {
                    insights.stopReport()
                    stream.finish()
                } else {
                    stream.fail(connectionLost)
                }
                try await eventually("报告生成已结束") { !insights.running }
                if timing != .beforeFailure {
                    XCTAssertEqual(Array(insights.liveReportText.utf8), Array(preview.utf8), label)
                    XCTAssertEqual(insights.liveReportError, timing == .afterStop ? nil : networkMessage, label)
                    try await confirmReportDeletion(report, via: route, store: store, api: api, wire: wire)
                }
                let keepPreview = timing == .differentSource || timing == .unknownSource
                XCTAssertEqual(Array(insights.liveReportText.utf8), keepPreview ? Array(preview.utf8) : [], label)
                XCTAssertEqual(insights.liveReportError, keepPreview ? networkMessage : deletionMessage, label)
                XCTAssertEqual(insights.viewedReportError, deletionMessage, label)
                XCTAssertNil(insights.liveReport, label)
                XCTAssertFalse(insights.reports.contains { $0.id == report.id }, label)
                XCTAssertEqual(wire.requests(runReportPath, method: "POST").count, 1, label)
                XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
            }
        }
    }

    func testStartingDeletedInsightDoesNotResetDraftOrStopChat() async throws {
        for sending in [false, true] {
            for pinned in [false, true] {
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, _) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                let report = try await openInsightReport("report", store: store, wire: wire)
                try await confirmReportDeletion(report, via: .delete200, store: store, api: api, wire: wire)
                chat.updateDraftFromUser(Self.newDraft)
                let save = sending ? try await holdProfileSave(store, api: api, wire: wire) : nil
                if sending {
                    wire.reply(chatPath, body: Self.sse("done", Self.history), stream: true)
                    chat.send(api: api, options: store.options, profile: store.insights)
                    XCTAssertTrue(chat.sending)
                    chat.updateDraftFromUser(Self.nextDraft)
                }
                let previous = chat.recoverableDraftSnapshot
                chat.start(pins: pinned ? ["note"] : [], insight: report)
                XCTAssertEqual(chat.recoverableDraftSnapshot, previous)
                XCTAssertEqual(chat.sending, sending)
                XCTAssertNil(chat.insight)
                XCTAssertEqual(chat.pins, [])
                if let save {
                    chat.stop()
                    try await finishProfileSave(save, wire: wire)
                    await chat.waitForIdle()
                }
                XCTAssertTrue(wire.requests(chatPath).isEmpty)
            }
        }
    }

    func testVerification404ReplacesMissingOrStaleErrorOnVisibleReport() async throws {
        enum DeleteTiming: CaseIterable { case none, before404, after404 }
        for timing in DeleteTiming.allCases {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let insights = store.insights
            let report = try await openInsightReport("report", store: store, wire: wire)
            let path = "\(reportsPath)/\(report.id)"
            wire.reply(runReportPath, method: "POST",
                       body: Self.sse("done", #"{"report":\#(Self.reportJSON(report.id))}"#), stream: true)
            insights.run(api: api, options: store.options)
            try await eventually("已显示生成结果") { !insights.running && insights.liveReport?.id == report.id }
            store.askAbout(report)
            store.chat.updateDraftFromUser(Self.firstDraft)
            store.requestNewChat()
            let priorFailure = timing == .before404
            if priorFailure {
                wire.reply(path, method: "DELETE", status: 500, body: #"{"error":"稍后再试"}"#)
                let success = await insights.deleteReport(report.id, api: api)
                XCTAssertFalse(success)
            }
            XCTAssertEqual(insights.viewedReportError, priorFailure ? "稍后再试" : nil)
            XCTAssertEqual(insights.liveReportError, priorFailure ? "稍后再试" : nil)

            var lateDelete: Task<Bool, Never>?
            if timing == .after404 {
                wire.hold(path, method: "DELETE")
                lateDelete = Task { await insights.deleteReport(report.id, api: api) }
                try await eventually("删除已经发出但尚未返回") { wire.waiting(path, method: "DELETE") == 1 }
            }
            try await confirmReportDeletion(report, via: .verify404, store: store, api: api, wire: wire)
            if let lateDelete {
                XCTAssertEqual(insights.viewedReportError, "报告不存在")
                XCTAssertEqual(insights.liveReportError, "报告不存在")
                try XCTUnwrap(wire.take(path, method: "DELETE")).complete(status: 500, body: #"{"error":"稍后再试"}"#)
                let success = await lateDelete.value
                XCTAssertFalse(success)
            }
            XCTAssertNil(insights.viewedReport)
            XCTAssertNil(insights.liveReport)
            XCTAssertEqual(insights.viewedReportText, "")
            XCTAssertEqual(insights.liveReportText, "")
            XCTAssertEqual(insights.viewedReportError, "报告不存在")
            XCTAssertEqual(insights.liveReportError, "报告不存在")
            XCTAssertEqual(wire.requests(path).count, 2)
        }
    }

    func testOpenReport404PropagatesToLiveReportOnlyWhenTheIDMatches() async throws {
        for id in ["report", "other"] {
            for priorFailure in [false, true] {
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, api, _) = try await connected(wire, mode: "gateway")
                let insights = store.insights
                let saved = try await openInsightReport("report", store: store, wire: wire)
                wire.reply(runReportPath, method: "POST",
                           body: Self.sse("done", #"{"report":\#(Self.reportJSON(id))}"#), stream: true)
                insights.run(api: api, options: store.options)
                try await eventually("已显示生成结果") { !insights.running && insights.liveReport?.id == id }
                if priorFailure {
                    wire.reply("\(reportsPath)/\(id)", method: "DELETE", status: 500, body: #"{"error":"稍后再试"}"#)
                    let success = await insights.deleteReport(id, api: api)
                    XCTAssertFalse(success)
                    XCTAssertEqual(insights.liveReportError, "稍后再试")
                }
                try await confirmReportDeletion(saved, via: .open404, store: store, api: api, wire: wire)
                XCTAssertNil(insights.viewedReport)
                XCTAssertEqual(insights.viewedReportText, "")
                XCTAssertEqual(insights.viewedReportError, "报告不存在")
                let matches = saved.id == id
                XCTAssertEqual(insights.liveReport?.id, matches ? nil : id)
                XCTAssertEqual(insights.liveReportText, matches ? "" : "正文")
                XCTAssertEqual(insights.liveReportError, matches ? "报告不存在" : priorFailure ? "稍后再试" : nil)
                XCTAssertEqual(wire.requests("\(reportsPath)/\(saved.id)").count, 2)
            }
        }
    }

    func testReportVerificationQueueSkipsDraftsAlreadySentOrDeleted() async throws {
        enum LaterDraft: CaseIterable { case sent, deleted, parked, inFlight }
        for laterDraft in LaterDraft.allCases {
            let label = "\(laterDraft)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            let first = try await openInsightReport("report-1", store: store, wire: wire)
            let second = try await openInsightReport("report-2", store: store, wire: wire)
            store.askAbout(first)
            chat.updateDraftFromUser(Self.firstDraft)
            store.askAbout(second)
            chat.updateDraftFromUser(Self.nextDraft)
            if laterDraft == .sent || laterDraft == .inFlight {
                wire.hold(chatPath)
                chat.send(api: api, options: store.options, profile: store.insights)
                try await eventually("第二份报告的追问已发出") { wire.waiting(self.chatPath) == 1 }
            } else {
                store.requestNewChat()
            }

            let firstPath = "\(reportsPath)/\(first.id)"
            let secondPath = "\(reportsPath)/\(second.id)"
            let before = wire.requests(secondPath).count
            let shouldProbe = laterDraft == .parked || laterDraft == .inFlight
            wire.reply(reportsPath, body: #"{"reports":[]}"#)
            wire.hold(firstPath)
            wire.reply(secondPath, status: shouldProbe ? 200 : 401,
                       body: shouldProbe ? #"{"report":\#(Self.reportJSON(second.id))}"# : Self.expired)
            let loading = Task { await store.insights.loadLibrary(api: api) }
            defer { loading.cancel() }
            try await eventually("第一份报告正在核实") { wire.waiting(firstPath) == 1 }
            XCTAssertEqual(wire.requests(secondPath).count, before, label)
            if laterDraft == .sent {
                try XCTUnwrap(wire.take(chatPath)).complete(body: Self.sse("done", Self.history), stream: true)
                await chat.waitForIdle()
                XCTAssertEqual(chat.session?.id, "history")
            } else if laterDraft == .deleted {
                try await confirmReportDeletion(second, via: .delete200, store: store, api: api, wire: wire)
                XCTAssertEqual(Array(chat.draft.utf8), Array(Self.nextDraft.utf8))
            }
            try XCTUnwrap(wire.take(firstPath)).complete(body: #"{"report":\#(Self.reportJSON(first.id))}"#)
            await loading.value
            XCTAssertEqual(wire.requests(secondPath).count - before, shouldProbe ? 1 : 0, label)
            XCTAssertEqual(store.authScreenState, .online, label)
            if laterDraft == .inFlight {
                try XCTUnwrap(wire.take(chatPath)).complete(body: Self.sse("done", Self.history), stream: true)
                await chat.waitForIdle()
            }
        }
    }

    func testUncancelledInsightProbeFromPreviousAccountDoesNotMoveNewAccountsDraft() async throws {
        let id = "shared-report"
        let path = "\(reportsPath)/\(id)"
        let bobDraft = " Bob 的草稿，保留这里\n🌱  "
        XCTAssertEqual(bobDraft.utf8.count, 36)
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, _, _) = try await connected(wire, mode: "gateway", userId: "alice")
        let chat = store.chat
        let aliceReport = try await openInsightReport(id, store: store, wire: wire)
        store.askAbout(aliceReport)
        chat.updateDraftFromUser("Alice 的草稿")
        store.requestNewChat()

        // This client is owned by the test, so swapping the store's connection won't cancel the request.
        let staleAPI = wire.api()
        wire.reply(reportsPath, body: #"{"reports":[]}"#)
        wire.hold(path)
        let staleLoad = Task { await store.insights.loadLibrary(api: staleAPI) }
        defer { staleLoad.cancel() }
        try await eventually("Alice 的详情核实请求已发出") { wire.waiting(path) == 1 }
        let lateResponse = try XCTUnwrap(wire.take(path))

        wire.reply("/api/session", body: #"{"user":{"id":"bob","name":"Bob"},"codexAvailable":true,"codexMode":"gateway"}"#)
        let bobConfig = try ServerConfiguration(address: wire.config.origin, token: "bob-test-token")
        store.connect(bobConfig, save: false)
        try await eventually("Bob 登录并同步") { store.identity?.user.id == "bob" && !store.syncing }
        let bobReport = try await openInsightReport(id, store: store, wire: wire)
        store.askAbout(bobReport)
        chat.updateDraftFromUser(bobDraft)
        store.requestNewChat()

        XCTAssertFalse(staleLoad.isCancelled)
        XCTAssertFalse(lateResponse.isStopped, "必须让旧账号的 404 真正返回")
        lateResponse.complete(status: 404, body: #"{"error":"Alice 的报告已删除"}"#)
        await staleLoad.value
        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(chat.recoverableDraftSnapshot.savedDrafts["insight:\(id)"].map { Array($0.utf8) },
                       Array(bobDraft.utf8))
        store.askAbout(bobReport)
        XCTAssertEqual(chat.insight?.id, id)
        XCTAssertEqual(Array(chat.draft.utf8), Array(bobDraft.utf8))
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
    }

    func testOnlyActiveInsightWithUserDraftProbesMissingReport() async throws {
        enum Draft: CaseIterable { case empty, whitespace, typed, sending }
        let id = "report-51"
        let path = "\(reportsPath)/\(id)"
        for state in Draft.allCases {
            let label = "\(state)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway")
            let report = try await openInsightReport(id, store: store, wire: wire)
            let chat = store.chat
            store.askAbout(report)
            let hasUserDraft = state == .typed || state == .sending
            if hasUserDraft { chat.updateDraftFromUser(Self.firstDraft) }
            if state == .whitespace { chat.updateDraftFromUser(" \t\n\u{3000}") }
            let save: Task<Bool, Never>?
            if state == .sending {
                save = try await holdWritingStyleSave(store, api: api, wire: wire)
                chat.toggleWritingStyle(isRelayMode: false)
                wire.reply(chatPath, status: 503, body: #"{"error":"等待保存不应发送"}"#)
                chat.send(api: api, options: store.options, profile: store.insights)
                XCTAssertTrue(chat.sending)
                XCTAssertEqual(chat.draft, "")
            } else {
                save = nil
            }
            let page = (1...50).map { Self.reportJSON("report-\($0)") }.joined(separator: ",")
            wire.reply(reportsPath, body: #"{"reports":[\#(page)]}"#)
            wire.reply(path, status: hasUserDraft ? 200 : 401,
                       body: hasUserDraft ? #"{"report":\#(Self.reportJSON(id))}"# : Self.expired)
            let before = wire.requests(path).count
            store.tab = .insights
            await store.insights.loadLibrary(api: api)
            XCTAssertEqual(wire.requests(path).count - before, hasUserDraft ? 1 : 0, label)
            XCTAssertEqual(store.authScreenState, .online, label)
            XCTAssertEqual(store.insights.reports.count, 50, label)

            if let save {
                chat.stop()
                try await finishWritingStyleSave(save, wire: wire)
                await chat.waitForIdle()
            }
            XCTAssertTrue(wire.requests(chatPath).isEmpty, label)
        }
    }

    func testReauthRestoresWalkDraftByFocusWhenRelatedNotesChange() async throws {
        let focus = "note"
        let initialRelated = ["b", "c"]
        let initialIds = [focus] + initialRelated
        let typed = " AI草稿含换行\n🙂下一行"
        XCTAssertEqual(typed.utf8.count, 32)
        let scenarios: [(name: String, notes: [String], related: [String]?)] = [
            ("关联不变", initialIds, initialRelated),
            ("关联换序", initialIds, ["c", "b"]),
            ("关联 B 删除", [focus, "c"], ["c"]),
            ("焦点 A 删除", initialRelated, nil),
        ]

        for scenario in scenarios {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, _, _) = try await connected(wire, mode: "gateway", notes: Self.notesJSON(initialIds))
            let chat = store.chat
            XCTAssertEqual(chat.draft.utf8.count, 0, scenario.name)
            let initial = try await pivotWalk(focus, related: initialRelated, store: store, wire: wire)
            store.askAbout(initial)
            XCTAssertEqual(chat.pins, initialIds, scenario.name)
            chat.updateDraftFromUser(typed)

            try await rejectNotesRefresh(store, wire: wire)
            wire.reply("/api/notes", body: Self.notesJSON(scenario.notes))
            try await reauthenticate(store, wire: wire)
            XCTAssertEqual(store.identity?.user.id, "account", scenario.name)
            XCTAssertEqual(Set(store.notesById.keys), Set(scenario.notes), scenario.name)
            if let related = scenario.related {
                XCTAssertEqual(chat.draft.utf8.count, 0, scenario.name)
                wire.reply(chatPath, status: 503, body: #"{"error":"空输入不应发送"}"#)
                chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
                await chat.waitForIdle()
                XCTAssertTrue(wire.requests(chatPath).isEmpty, scenario.name)

                let walk = try await pivotWalk(focus, related: related, store: store, wire: wire)
                store.askAbout(walk)
                XCTAssertEqual(chat.pins, [focus] + related, scenario.name)
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), scenario.name)
                store.requestNewChat()
                XCTAssertEqual(chat.draft.utf8.count, 0, scenario.name)
                XCTAssertEqual(wire.requests("/api/notes/\(focus)/related").count, 2, scenario.name)
            } else {
                XCTAssertFalse(chat.canReference(focus), scenario.name)
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), scenario.name)
                try await assertDraftSurvivesHistoryRoundTrip(typed, store: store, wire: wire)
            }
            XCTAssertTrue(wire.requests(chatPath).isEmpty, scenario.name)
        }
    }

    func testPendingWalkRequiresItsFocusButAllowsRelatedNotesToDisappear() async throws {
        let focus = "note"
        let related = ["b", "c"]
        let notes = "/api/notes"
        for remaining in [related, [], [focus, "c"]] {
            let scenario = "剩余笔记: \(remaining)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, _) = try await connected(wire, mode: "gateway", notes: Self.notesJSON([focus] + related))
            let chat = store.chat
            let walk = try await pivotWalk(focus, related: related, store: store, wire: wire)
            let save = try await holdWritingStyleSave(store, api: api, wire: wire)
            wire.reply(chatPath, status: 503, body: #"{"error":"聊天未完成"}"#)
            chat.updateDraftFromUser(Self.newDraft)
            chat.toggleWritingStyle(isRelayMode: false)
            chat.send(api: api, options: store.options, profile: store.insights)
            store.tab = .walk

            wire.hold(notes)
            store.refresh()
            try await eventually("笔记同步已发出") { wire.waiting(notes) == 1 }
            store.askAbout(walk)
            guard case .walk = store.pendingChatSwitch else { return XCTFail("发送中必须先确认漫步切换") }
            try XCTUnwrap(wire.take(notes)).complete(body: Self.notesJSON(remaining))
            try await eventually("笔记同步已完成") { !store.syncing && Set(store.notesById.keys) == Set(remaining) }

            if remaining.contains(focus) {
                XCTAssertNotNil(store.pendingChatSwitch, scenario)
                store.confirmChatSwitch()
                XCTAssertEqual(store.tab, .ai, scenario)
                XCTAssertEqual(chat.pins, [focus, "c"], scenario)
                try await finishWritingStyleSave(save, wire: wire)
                chat.updateDraftFromUser(Self.firstDraft)
                chat.send(api: api, options: store.options, profile: store.insights)
                await chat.waitForIdle()
                let posts = wire.requests(chatPath)
                XCTAssertEqual(posts.count, 1, scenario)
                XCTAssertEqual(posts.first?["referencedNoteIds"] as? [String], [focus, "c"], scenario)
                let message = try XCTUnwrap(posts.first?["message"] as? String)
                XCTAssertEqual(Array(message.utf8), Array(Self.firstDraft.utf8), scenario)
            } else {
                XCTAssertNil(store.walk.result, scenario)
                XCTAssertNil(store.pendingChatSwitch, scenario)
                store.confirmChatSwitch()
                store.askAbout(walk)
                XCTAssertNil(store.pendingChatSwitch, scenario)
                XCTAssertEqual(store.tab, .walk, scenario)
                XCTAssertTrue(chat.sending, scenario)
                XCTAssertEqual(chat.pendingQuestion, Self.newDraft, scenario)
                try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(status: 503, body: #"{"error":"保存失败"}"#)
                let saved = await save.value
                XCTAssertFalse(saved, scenario)
                await chat.waitForIdle()
                XCTAssertTrue(wire.requests(chatPath).isEmpty, scenario)
            }
        }
    }

    func testInterruptedWalkWithDeletedFocusRecoversQuestionAndFollowUp() async throws {
        enum Interruption: CaseIterable { case stop, profile503, style503, chat503, chat409, selectHistory, relay }
        let related = ["b", "c"]
        let profilePath = "/api/ai/profile"
        let bothParts = Self.firstDraft + "\n\n" + Self.nextDraft
        let merged = Self.newDraft + "\n\n" + bothParts
        XCTAssertEqual(merged.utf8.count, 105)

        for (interruption, deleteFocus) in Interruption.allCases.map({ ($0, true) }) + [(.chat503, false)] {
            let scenario = "\(interruption)，焦点已删: \(deleteFocus)"
            let wire = try StyleHTTP()
            defer { wire.close() }
            let initialNotes = Self.notesJSON(["note"] + related)
            let (store, api, note) = try await connected(wire, mode: interruption == .relay ? "relay" : "gateway", notes: initialNotes)
            let chat = store.chat
            chat.updateDraftFromUser(Self.newDraft)
            let walk = try await pivotWalk(note.id, related: related, store: store, wire: wire)
            store.askAbout(walk)
            XCTAssertEqual(chat.pins, [note.id] + related, scenario)
            chat.updateDraftFromUser(Self.firstDraft)

            let postsBeforeInterruption = interruption == .chat503 || interruption == .chat409
            let save: (path: String, task: Task<Bool, Never>)?
            if postsBeforeInterruption {
                save = nil
                wire.hold(chatPath)
            } else if interruption == .style503 {
                chat.toggleWritingStyle(isRelayMode: false)
                save = (stylePath, try await holdWritingStyleSave(store, api: api, wire: wire))
            } else {
                wire.hold(profilePath, method: "POST")
                save = (profilePath, try XCTUnwrap(store.insights.saveProfile(.init(enabled: false), api: api)))
                try await eventually("画像保存尚未返回") { wire.waiting(profilePath, method: "POST") == 1 }
            }
            if interruption == .relay {
                store.setProvider(.openai)
                chat.toggleWritingStyle(isRelayMode: false)
            }
            if !postsBeforeInterruption {
                wire.reply(chatPath, status: 503, body: #"{"error":"等待保存不应发送"}"#)
            }
            chat.send(api: api, options: store.options, profile: store.insights)
            XCTAssertTrue(chat.sending, scenario)
            if postsBeforeInterruption {
                try await eventually("聊天 POST 尚未返回") { wire.waiting(self.chatPath) == 1 }
            }
            chat.updateDraftFromUser(Self.nextDraft)

            let remainingNotes = deleteFocus ? Self.notesJSON(related) : initialNotes
            if deleteFocus {
                wire.reply("/api/notes", body: remainingNotes)
                store.refresh()
                try await eventually("笔记同步确认删除漫步焦点") { !store.syncing && !chat.canReference(note.id) }
                XCTAssertNil(store.walk.result, scenario)
                XCTAssertEqual(Array(chat.recoverableDraftSnapshot.activeDraft.utf8), Array(bothParts.utf8), scenario)
            }

            switch interruption {
            case .stop: chat.stop()
            case .relay: store.setProvider(.codex)
            case .selectHistory:
                try await assertDraftSurvivesHistoryRoundTrip(merged, store: store, wire: wire, confirmPendingSwitch: true)
            case .chat503, .chat409:
                try XCTUnwrap(wire.take(chatPath)).complete(status: interruption == .chat409 ? 409 : 503,
                                                            body: #"{"error":"聊天未完成"}"#)
            case .profile503, .style503: break
            }
            if let save {
                let failed = interruption == .profile503 || interruption == .style503
                let body = failed ? #"{"error":"保存未完成"}"# : #"{"profile":{"content":"画像","enabled":false,"noteCount":1}}"#
                try XCTUnwrap(wire.take(save.path, method: "POST")).complete(status: failed ? 503 : 200, body: body)
                let saved = await save.task.value
                XCTAssertEqual(saved, !failed, scenario)
            }
            await chat.waitForIdle()
            XCTAssertFalse(chat.sending, scenario)
            if interruption == .relay { XCTAssertEqual(chat.error, InsightsStore.writingStyleRelayMessage, scenario) }

            let home = deleteFocus ? merged : Self.newDraft
            if interruption != .selectHistory {
                XCTAssertEqual(Array(chat.draft.utf8), Array((deleteFocus ? bothParts : Self.nextDraft).utf8), scenario)
                try await assertDraftSurvivesHistoryRoundTrip(home, store: store, wire: wire)
            }
            if deleteFocus { XCTAssertNil(chat.recoverableDraftSnapshot.savedDrafts["walk:\(note.id)"], scenario) }
            try await rejectNotesRefresh(store, wire: wire)
            wire.reply("/api/notes", body: remainingNotes)
            try await reauthenticate(store, wire: wire)
            XCTAssertEqual(Array(chat.draft.utf8), Array(home.utf8), scenario)
            if !deleteFocus {
                store.askAbout(walk)
                XCTAssertEqual(Array(chat.draft.utf8), Array(Self.nextDraft.utf8), scenario)
            }
            let posts = wire.requests(chatPath)
            XCTAssertEqual(posts.count, postsBeforeInterruption ? 1 : 0, scenario)
            if postsBeforeInterruption {
                let sent = try XCTUnwrap(posts.first?["message"] as? String, scenario)
                XCTAssertEqual(Array(sent.utf8), Array(Self.firstDraft.utf8), scenario)
            }
        }
    }

    private enum ReportDeletionRoute: CaseIterable { case delete200, delete404, open404, verify404 }

    private func confirmReportDeletion(_ report: InsightReport, via route: ReportDeletionRoute, store: AppStore,
                                       api: WeijiAPIClient, wire: StyleHTTP) async throws {
        let path = "\(reportsPath)/\(report.id)"
        let missing = #"{"error":"报告不存在"}"#
        let insights = store.insights
        switch route {
        case .delete200, .delete404:
            let success = route == .delete200
            wire.reply(path, method: "DELETE", status: success ? 200 : 404,
                       body: success ? #"{"deleted":"\#(report.id)"}"# : missing)
            let deleted = await insights.deleteReport(report.id, api: api)
            XCTAssertEqual(deleted, success)
        case .open404:
            wire.reply(path, status: 404, body: missing)
            insights.openReport(report, api: api)
            try await eventually("打开报告返回 404") { !insights.loadingReport }
        case .verify404:
            wire.reply(reportsPath, body: #"{"reports":[]}"#)
            wire.reply(path, status: 404, body: missing)
            await insights.loadLibrary(api: api)
        }
    }

    private static func reportJSON(_ id: String, cited: Bool = false, content: String = "正文") -> String {
        let citations = cited ? #","citations":[{"ref":"1","noteId":"note","excerpt":"原句"}]"# : ""
        return #"{"id":"\#(id)","title":"洞察","lensName":"回顾","content":"\#(content)","createdAt":"2026-11-28"\#(citations)}"#
    }

    private func openInsightReport(_ id: String, store: AppStore, wire: StyleHTTP, cited: Bool = false,
                                   content: String = "正文") async throws -> InsightReport {
        let api = try XCTUnwrap(store.api)
        let insights = store.insights
        let report = Self.reportJSON(id, cited: cited, content: content)
        wire.reply("/api/insights/lenses", body: #"{"lenses":[]}"#)
        wire.reply(reportsPath, body: #"{"reports":[\#(report)]}"#)
        wire.reply("\(reportsPath)/\(id)", body: #"{"report":\#(report)}"#)
        await insights.loadLibrary(api: api)
        insights.openReport(try XCTUnwrap(insights.reports.first { $0.id == id }), api: api)
        try await eventually("报告详情已加载") { !insights.loadingReport }
        return try XCTUnwrap(insights.viewedReport)
    }

    private static func noteJSON(_ id: String) -> String {
        #"{"id":"\#(id)","body":"笔记原文","createdAt":"2026-11-28","turns":[],"revision":1}"#
    }

    private static func notesJSON(_ ids: [String]) -> String {
        #"{"notes":[\#(ids.map(noteJSON).joined(separator: ","))],"deleted":[]}"#
    }

    private func pivotWalk(_ focus: String, related ids: [String], store: AppStore, wire: StyleHTTP) async throws -> RelatedNotes {
        let related = ids.map { id in
            #"{"id":"\#(id)","score":0.5,"relevancePercent":50,"sharedTags":[],"note":\#(Self.noteJSON(id))}"#
        }.joined(separator: ",")
        wire.reply("/api/notes/\(focus)/related",
                   body: #"{"focus":\#(Self.noteJSON(focus)),"mode":"lexical","indexed":0,"total":3,"related":[\#(related)]}"#)
        let api = try XCTUnwrap(store.api)
        let task = try XCTUnwrap(store.walk.pivot(to: focus, api: api))
        await task.value
        let walk = try XCTUnwrap(store.walk.result)
        XCTAssertEqual(walk.focus.id, focus)
        XCTAssertEqual(walk.related.map(\.id), ids)
        return walk
    }

    private func assertWalkAndInsightDraftsRestore(savedNew: String) async throws {
        enum Entry: CaseIterable { case walk, insight }
        let typed = " AI草稿含换行\n🙂下一行"
        XCTAssertEqual(typed.utf8.count, 32)

        for entry in Entry.allCases {
            for activeAt401 in [false, true] {
                let wire = try StyleHTTP()
                defer { wire.close() }
                let (store, _, note) = try await connected(wire, mode: "gateway")
                let chat = store.chat
                let walk = RelatedNotes(focus: .init(id: note.id, body: note.body, createdAt: note.createdAt, reading: nil),
                                        mode: "test", indexed: 1, total: 1, related: [])
                let report = InsightReport(id: "report", title: "洞察", lensName: "回顾", content: "正文", excerpt: nil,
                                           citations: [.init(ref: "1", noteId: note.id, excerpt: note.body)], createdAt: note.createdAt)
                func openEntry() {
                    switch entry {
                    case .walk: store.askAbout(walk)
                    case .insight: store.askAbout(report)
                    }
                }
                let scenario = "\(entry)，401 时来源上下文在前台: \(activeAt401)"
                chat.updateDraftFromUser(savedNew)
                openEntry()
                chat.updateDraftFromUser(typed)
                if !activeAt401 { store.requestNewChat() }
                XCTAssertEqual(chat.draft, activeAt401 ? typed : savedNew, scenario)

                try await rejectNotesRefresh(store, wire: wire)
                wire.reply("/api/notes", body: Self.initialNotes)
                try await reauthenticate(store, wire: wire)

                XCTAssertEqual(Array(chat.draft.utf8), Array(savedNew.utf8), scenario)
                if savedNew.isEmpty {
                    wire.reply(chatPath, status: 503, body: #"{"error":"空输入不应发送"}"#)
                    chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
                    await chat.waitForIdle()
                    XCTAssertTrue(wire.requests(chatPath).isEmpty, scenario)
                }
                openEntry()
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), scenario)
                XCTAssertEqual(chat.pins, [note.id], scenario)
                XCTAssertEqual(chat.insight?.id, entry == .insight ? report.id : nil, scenario)
                store.requestNewChat()
                XCTAssertEqual(Array(chat.draft.utf8), Array(savedNew.utf8), scenario)
                XCTAssertTrue(wire.requests(chatPath).isEmpty, scenario)
            }
        }
    }

    func testRelayRestoredPromptIsRecoverableOnlyAfterUserReplacesIt() async throws {
        let template = AIChatStore.rewriteNotePrompt
        XCTAssertEqual(template.utf8.count, 144)
        let existingNew = Self.newDraft
        XCTAssertEqual(existingNew.utf8.count, 23)
        let cases: [(deleteFirst: Bool, paste: Bool, savedNew: String)] = [
            (true, true, ""), (true, false, ""), (false, true, ""), (false, false, ""),
            (true, true, existingNew), (true, false, existingNew), (false, true, existingNew), (false, false, existingNew),
        ]

        for (deleteFirst, paste, savedNew) in cases {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, note) = try await connected(wire, mode: "relay")
            let chat = store.chat
            chat.updateDraftFromUser(savedNew)
            store.setProvider(.openai)
            let save = try await beginAutomaticRewriteWaitingForSave(note, store: store, api: api, wire: wire)
            store.setProvider(.codex)
            XCTAssertTrue(store.isRelayMode)
            XCTAssertFalse(chat.sending)
            XCTAssertEqual(chat.draft, template)
            XCTAssertEqual(chat.recoverableDraft, "")

            if paste { chat.updateDraftFromUser(template) }
            let recovered = [savedNew, paste ? template : ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let expected = paste ? recovered : ""
            if paste && !savedNew.isEmpty { XCTAssertEqual(recovered.utf8.count, 169) }
            if deleteFirst {
                try await syncDeleteRewriteSource(note, store: store, wire: wire)
                assertDeletedRewrite(chat, draft: expected, savedNew: paste ? "" : savedNew)
                try await finishWritingStyleSave(save, wire: wire)
            } else {
                try await finishWritingStyleSave(save, wire: wire)
                wire.reply("/api/notes", status: 401, body: Self.expired)
                store.refresh()
                try await eventually("刷新笔记返回 401") { store.authScreenState == .needsLogin && !store.syncing }
                wire.reply("/api/notes", body: #"{"notes":[],"deleted":[]}"#)
                try await reauthenticate(store, wire: wire)
            }
            if paste {
                XCTAssertEqual(Array(chat.draft.utf8), Array(expected.utf8))
            } else {
                XCTAssertEqual(chat.draft, "")
                store.setProvider(.openai)
                chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
                await chat.waitForIdle()
                XCTAssertTrue(wire.requests(chatPath).isEmpty, "纯系统模板被抑制后直接发送应新增 0 个 POST")
                if !deleteFirst && !savedNew.isEmpty {
                    store.requestNewChat()
                    XCTAssertEqual(Array(chat.draft.utf8), Array(savedNew.utf8))
                }
            }
            if deleteFirst || paste { try await assertDraftSurvivesHistoryRoundTrip(recovered, store: store, wire: wire) }
            XCTAssertTrue(wire.requests(chatPath).isEmpty)
        }
    }

    func testDeletingRewriteSourceMergesCanonicallyEquivalentDraftsByteForByte() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "gateway")
        let savedNew = "Caf\u{00e9}\n\nok"
        store.chat.updateDraftFromUser(savedNew)
        let rescued = try await deleteRewriteSourceWithTwoDrafts(store, api: api, note: note, wire: wire,
                                                               first: "Cafe\u{0301}", next: "ok")
        XCTAssertEqual(savedNew, rescued, "Swift text equality must not decide whether to keep two independent drafts")
        XCTAssertEqual(savedNew.utf8.count, 9)
        XCTAssertEqual(rescued.utf8.count, 10)
        let expected = savedNew + "\n\n" + rescued
        XCTAssertEqual(store.chat.draft.utf8.count, 21)
        XCTAssertEqual(Array(store.chat.draft.utf8), Array(expected.utf8))
        try await assertDraftSurvivesHistoryRoundTrip(expected, store: store, wire: wire)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
    }

    func testDeletingRewriteSourcePreservesPastedCopyOfAutomaticPrompt() async throws {
        for restoreBeforePaste in [false, true] {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, note) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            let pasted = AIChatStore.rewriteNotePrompt
            wire.reply(stylePath, body: Self.styleEnvelope)
            await store.insights.loadWritingStyle(api: api)
            wire.hold(stylePath, method: "POST")
            let save = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
            try await eventually("风格保存已挂起") { wire.waiting(self.stylePath, method: "POST") == 1 }
            wire.reply(sourcePath, body: Self.rewriteHistoryA)
            wire.reply(chatPath, body: Self.sse("done", Self.rewriteHistoryA), stream: true)
            store.rewriteWithStyle(note)
            await store.awaitPendingRewrite()
            XCTAssertTrue(chat.sending)
            XCTAssertEqual(chat.pendingQuestion, pasted)
            XCTAssertEqual(chat.draft, "")
            XCTAssertEqual(chat.recoverableDraft, "")
            XCTAssertTrue(wire.requests(chatPath).isEmpty)

            if restoreBeforePaste {
                chat.stop()
                XCTAssertEqual(chat.draft, pasted)
                XCTAssertEqual(chat.recoverableDraft, "")
                chat.updateDraftFromUser("")
            }
            chat.updateDraftFromUser(pasted)
            XCTAssertEqual(chat.recoverableDraft, pasted)
            try await syncDeleteRewriteSource(note, store: store, wire: wire)
            try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(body: Self.styleEnvelope)
            let saved = await save.value
            XCTAssertTrue(saved)
            await chat.waitForIdle()

            assertDeletedRewrite(chat, draft: pasted)
            XCTAssertEqual(chat.draft.utf8.count, 144)
            try await assertDraftSurvivesHistoryRoundTrip(pasted, store: store, wire: wire)
            XCTAssertTrue(wire.requests(chatPath).isEmpty)
        }
    }

    private func holdProfileSave(_ store: AppStore, api: WeijiAPIClient, wire: StyleHTTP) async throws -> Task<Bool, Never> {
        wire.hold(profilePath, method: "POST")
        let save = try XCTUnwrap(store.insights.saveProfile(.init(content: "画像", enabled: true), api: api))
        try await eventually("画像保存已挂起") { wire.waiting(self.profilePath, method: "POST") == 1 }
        return save
    }

    private func finishProfileSave(_ save: Task<Bool, Never>, wire: StyleHTTP) async throws {
        try XCTUnwrap(wire.take(profilePath, method: "POST")).complete(body: #"{"profile":null}"#)
        let saved = await save.value
        XCTAssertTrue(saved)
    }

    private func holdWritingStyleSave(_ store: AppStore, api: WeijiAPIClient, wire: StyleHTTP) async throws -> Task<Bool, Never> {
        wire.reply(stylePath, body: Self.styleEnvelope)
        await store.insights.loadWritingStyle(api: api)
        wire.hold(stylePath, method: "POST")
        let save = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
        try await eventually("风格保存已挂起") { wire.waiting(self.stylePath, method: "POST") == 1 }
        return save
    }

    private func beginAutomaticRewriteWaitingForSave(_ note: Note, store: AppStore, api: WeijiAPIClient,
                                                     wire: StyleHTTP) async throws -> Task<Bool, Never> {
        let save = try await holdWritingStyleSave(store, api: api, wire: wire)
        wire.reply(sourcePath, body: Self.rewriteHistoryA)
        wire.reply(chatPath, body: Self.sse("done", Self.rewriteHistoryA), stream: true)
        store.rewriteWithStyle(note)
        await store.awaitPendingRewrite()
        XCTAssertTrue(store.chat.sending)
        XCTAssertEqual(store.chat.pendingQuestion, AIChatStore.rewriteNotePrompt)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
        return save
    }

    private func finishWritingStyleSave(_ save: Task<Bool, Never>, wire: StyleHTTP) async throws {
        try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(body: Self.styleEnvelope)
        let saved = await save.value
        XCTAssertTrue(saved)
    }

    private func reauthenticate(_ store: AppStore, wire: StyleHTTP) async throws {
        try await eventually("401 后回到登录页") { store.authScreenState == .needsLogin && !store.syncing }
        let renewed = try ServerConfiguration(address: wire.config.origin, token: "renewed-test-token")
        store.connect(renewed, save: false)
        try await eventually("重登并同步") { store.authScreenState == .online && !store.syncing }
    }

    private func beginReauthWithHeldNotes(_ store: AppStore, wire: StyleHTTP) async throws -> StyleProtocol {
        try await eventually("401 后回到登录页") { store.authScreenState == .needsLogin && !store.syncing }
        wire.hold("/api/notes")
        let renewed = try ServerConfiguration(address: wire.config.origin, token: "pending-notes-test-token")
        store.connect(renewed, save: false)
        try await eventually("重登后笔记列表尚未返回") { wire.waiting("/api/notes") == 1 }
        XCTAssertEqual(store.identity?.user.id, "account")
        return try XCTUnwrap(wire.take("/api/notes"))
    }

    private func rejectNotesRefresh(_ store: AppStore, wire: StyleHTTP) async throws {
        wire.reply("/api/notes", status: 401, body: Self.expired)
        store.refresh()
        try await eventually("刷新笔记返回 401") { store.authScreenState == .needsLogin && !store.syncing }
    }

    private func rejectSourceLoad(_ note: Note, draft: String, store: AppStore, wire: StyleHTTP) async throws {
        store.chat.updateDraftFromUser(Self.newDraft)
        wire.hold(sourcePath)
        store.askAbout(note)
        store.chat.updateDraftFromUser(draft)
        try await eventually("来源会话 GET 尚未返回") { wire.waiting(self.sourcePath) == 1 }
        try XCTUnwrap(wire.take(sourcePath)).complete(status: 401, body: Self.expired)
    }

    private func openSourceNote(_ note: Note, store: AppStore, wire: StyleHTTP) async throws {
        wire.reply(sourcePath, body: Self.rewriteHistoryA)
        store.askAbout(note)
        try await eventually("打开来源笔记") { !store.chat.loadingSession && store.chat.session?.id == "history-a" }
    }

    private func deleteRewriteSourceWithTwoDrafts(_ store: AppStore, api: WeijiAPIClient, note: Note, wire: StyleHTTP,
                                                  first: String = firstDraft, next: String = nextDraft) async throws -> String {
        let chat = store.chat
        wire.hold(sourcePath)
        wire.reply(chatPath, body: Self.sse("done", Self.rewriteHistoryA), stream: true)
        store.rewriteWithStyle(note)
        try await eventually("源会话读取已挂起") { wire.waiting(self.sourcePath) == 1 }
        chat.draft = first
        try XCTUnwrap(wire.take(sourcePath)).complete(body: Self.rewriteHistoryA)
        await store.awaitPendingRewrite()
        XCTAssertEqual(chat.session?.id, "history-a")
        XCTAssertEqual(chat.session?.turns?.first?.text, "之前的问题")
        XCTAssertEqual(chat.draft, first)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)

        wire.reply(stylePath, body: Self.styleEnvelope)
        await store.insights.loadWritingStyle(api: api)
        wire.hold(stylePath, method: "POST")
        let save = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
        chat.send(api: api, options: store.options, profile: store.insights)
        try await eventually("手动发送等待风格保存") { wire.waiting(self.stylePath, method: "POST") == 1 }
        XCTAssertTrue(chat.sending)
        XCTAssertEqual(chat.pendingQuestion, first)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
        chat.draft = next

        try await syncDeleteRewriteSource(note, store: store, wire: wire)
        try XCTUnwrap(wire.take(stylePath, method: "POST")).complete(body: Self.styleEnvelope)
        let saved = await save.value
        XCTAssertTrue(saved)
        await chat.waitForIdle()
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
        return first + "\n\n" + next
    }

    private func syncDeleteRewriteSource(_ note: Note, store: AppStore, wire: StyleHTTP) async throws {
        wire.reply("/api/notes", body: #"{"notes":[],"deleted":[{"id":"\#(note.id)","revision":2}]}"#)
        store.refresh()
        try await eventually("同步删除来源笔记") { !store.syncing && store.notesById[note.id] == nil }
    }

    private func assertDraftSurvivesHistoryRoundTrip(_ draft: String, store: AppStore, wire: StyleHTTP,
                                                     confirmPendingSwitch: Bool = false,
                                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        wire.reply("/api/ai/sessions/unrelated", body: #"{"session":{"id":"unrelated","title":"其他历史会话","version":1,"updatedAt":"2026-11-28","origin":"global","turns":[]}}"#)
        store.requestSelectChatSession("unrelated")
        if confirmPendingSwitch {
            guard case .session("unrelated") = store.pendingChatSwitch else {
                return XCTFail("发送中必须先确认切换历史会话", file: file, line: line)
            }
            store.confirmChatSwitch()
        }
        try await eventually("打开历史会话", {
            !store.chat.loadingSession && store.chat.session?.id == "unrelated"
        }, file: file, line: line)
        XCTAssertEqual(store.chat.draft, "", file: file, line: line)
        store.requestNewChat()
        XCTAssertEqual(Array(store.chat.draft.utf8), Array(draft.utf8), file: file, line: line)
    }

    func testRewriteRestoredByRelayCannotSendWithoutItsDeletedSource() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "relay")
        let existingNew = "已有新对话草稿"
        store.chat.draft = existingNew
        store.setProvider(.openai)
        wire.reply(stylePath, body: Self.styleEnvelope)
        await store.insights.loadWritingStyle(api: api)
        wire.hold(stylePath, method: "POST")
        let save = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
        try await eventually("风格保存已挂起") { wire.waiting(self.stylePath, method: "POST") == 1 }
        let response = try XCTUnwrap(wire.take(stylePath, method: "POST"))
        wire.reply(sourcePath, body: Self.rewriteHistoryA)
        wire.reply(chatPath, body: Self.sse("done", Self.rewriteHistoryA), stream: true)
        store.rewriteWithStyle(note)
        await store.awaitPendingRewrite()
        XCTAssertTrue(store.chat.sending)
        XCTAssertEqual(store.chat.session?.id, "history-a")

        store.setProvider(.codex)
        XCTAssertTrue(store.isRelayMode)
        XCTAssertFalse(store.chat.sending)
        XCTAssertEqual(store.chat.draft, AIChatStore.rewriteNotePrompt)
        XCTAssertEqual(store.chat.recoverableDraft, "")
        XCTAssertTrue(wire.requests(chatPath).isEmpty)

        await store.replace(with: [], persist: false)
        assertDeletedRewrite(store.chat, savedNew: existingNew)
        // Exit relay through the provider switch so the current chat is not reset.
        store.setProvider(.openai)
        XCTAssertFalse(store.isRelayMode)
        store.chat.send(api: api, options: store.options, profile: store.insights, isRelayMode: { store.isRelayMode })
        response.complete(body: Self.styleEnvelope)
        let saved = await save.value
        XCTAssertTrue(saved)
        await store.chat.waitForIdle()
        assertDeletedRewrite(store.chat, savedNew: existingNew)
        try await assertDraftSurvivesHistoryRoundTrip(existingNew, store: store, wire: wire)
        XCTAssertTrue(wire.requests(chatPath).isEmpty)
    }

    func testSameAccountReauthRestoresNoteDraftButNotAutomaticRewritePrompt() async throws {
        XCTAssertEqual(Self.newDraft.utf8.count, 23)
        for (draft, savedNew) in [("", ""), ("", Self.newDraft), ("已有笔记草稿", "")] {
            let wire = try StyleHTTP()
            defer { wire.close() }
            let (store, api, note) = try await connected(wire, mode: "gateway")
            let chat = store.chat
            let userId = try XCTUnwrap(store.identity?.user.id)
            if !draft.isEmpty {
                chat.start(source: note.id)
                chat.draft = draft
                store.requestNewChat()
            } else {
                chat.draft = savedNew
            }
            wire.reply(sourcePath, body: Self.rewriteHistoryA)
            wire.reply(chatPath, status: 401, body: Self.expired)
            store.rewriteWithStyle(note)
            if !draft.isEmpty {
                try await eventually("打开已有草稿的源会话") { !chat.loadingSession }
                XCTAssertTrue(wire.requests(chatPath).isEmpty)
                XCTAssertEqual(chat.draft, draft)
                chat.send(api: api, options: store.options, profile: store.insights)
            }
            try await eventually("401 后回到登录页") {
                store.authScreenState == .needsLogin && !store.syncing
            }
            await chat.waitForIdle()
            let originalPosts = wire.requests(chatPath)
            XCTAssertEqual(originalPosts.count, 1)
            let sent = try XCTUnwrap(originalPosts.first?["message"] as? String)
            XCTAssertEqual(Array(sent.utf8), Array((draft.isEmpty ? AIChatStore.rewriteNotePrompt : draft).utf8))
            XCTAssertEqual(originalPosts.first?["sourceNoteId"] as? String, note.id)
            XCTAssertEqual(originalPosts.first?["useWritingStyle"] as? Bool, true)

            wire.reply("/api/notes", body: #"{"notes":[],"deleted":[]}"#)
            let renewed = try ServerConfiguration(address: wire.config.origin, token: "renewed-test-token")
            store.connect(renewed, save: false)
            try await eventually("同账号重登并同步") { store.authScreenState == .online && !store.syncing }
            XCTAssertEqual(store.identity?.user.id, userId)
            XCTAssertNil(store.notesById[note.id])
            XCTAssertEqual(chat.draft, draft)
            XCTAssertNil(chat.sourceNoteId)
            XCTAssertNil(chat.session)
            XCTAssertFalse(chat.useWritingStyle)

            if draft.isEmpty {
                store.tab = .ai
                wire.reply(chatPath, status: 503, body: #"{"error":"不应发送自动改写草稿"}"#)
                chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
                await chat.waitForIdle()
                XCTAssertEqual(wire.requests(chatPath).count, originalPosts.count, "重登后直接点发送应新增 0 个 POST")
                if !savedNew.isEmpty {
                    store.requestNewChat()
                    XCTAssertEqual(Array(chat.draft.utf8), Array(savedNew.utf8))
                }
            }
        }
    }

    func testRescuingDeletedNoteDraftsDoesNotFillTheSuppressedComposer() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, _, source) = try await connected(wire, mode: "gateway")
        let chat = store.chat
        let orphanA = Note(id: "orphan-a", body: "笔记甲", createdAt: source.createdAt, revision: 1)
        let orphanB = Note(id: "orphan-b", body: "笔记乙", createdAt: source.createdAt, revision: 1)
        await store.replace(with: [source, orphanA, orphanB], persist: false)
        chat.updateDraftFromUser(Self.newDraft)
        for (note, draft) in [(orphanB, Self.nextDraft), (orphanA, Self.firstDraft)] {
            chat.start(source: note.id)
            chat.updateDraftFromUser(draft)
        }

        wire.reply(sourcePath, body: Self.rewriteHistoryA)
        wire.reply(chatPath, status: 401, body: Self.expired)
        store.rewriteWithStyle(source)
        try await eventually("自动改写返回 401") { store.authScreenState == .needsLogin && !store.syncing }
        wire.reply("/api/notes", body: #"{"notes":[],"deleted":[]}"#)
        try await reauthenticate(store, wire: wire)

        XCTAssertEqual(chat.draft, "")
        let postsBefore = wire.requests(chatPath)
        XCTAssertEqual(postsBefore.count, 1)
        let sent = try XCTUnwrap(postsBefore.first?["message"] as? String)
        XCTAssertEqual(Array(sent.utf8), Array(AIChatStore.rewriteNotePrompt.utf8))
        chat.send(api: try XCTUnwrap(store.api), options: store.options, profile: store.insights)
        await chat.waitForIdle()
        XCTAssertEqual(wire.requests(chatPath).count, postsBefore.count)

        let typed = "恢复后继续写"
        chat.updateDraftFromUser(typed)
        let merged = [Self.newDraft, Self.firstDraft, Self.nextDraft, typed].joined(separator: "\n\n")
        try await assertDraftSurvivesHistoryRoundTrip(merged, store: store, wire: wire)
        XCTAssertEqual(wire.requests(chatPath).count, postsBefore.count)
    }

    func testRewriteRetryStillRequiresItsSourceAfterAConflict() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, api, note) = try await connected(wire, mode: "gateway")
        let current = Self.session.replacingOccurrences(of: #""sourceNoteId":"note""#, with: #""sourceNoteId":null"#)
        wire.reply(sourcePath, body: Self.rewriteHistoryA)
        wire.reply(chatPath, status: 409, body: #"{"error":"版本冲突","current":\#(current)}"#)
        store.rewriteWithStyle(note)
        await store.awaitPendingRewrite()
        await store.chat.waitForIdle()
        let posts = wire.requests(chatPath)
        XCTAssertEqual(posts.count, 1)
        let sent = try XCTUnwrap(posts.first?["message"] as? String)
        XCTAssertEqual(Array(sent.utf8), Array(AIChatStore.rewriteNotePrompt.utf8))
        XCTAssertEqual(posts.first?["sourceNoteId"] as? String, note.id)
        XCTAssertNil(store.chat.sourceNoteId)
        XCTAssertEqual(store.chat.draft, AIChatStore.rewriteNotePrompt)
        XCTAssertEqual(store.chat.recoverableDraft, "")

        store.chat.send(api: api, options: store.options, profile: store.insights)
        await store.chat.waitForIdle()
        assertDeletedRewrite(store.chat)
        XCTAssertEqual(wire.requests(chatPath).count, 1)
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
        let taskA = try XCTUnwrap(store.currentRewriteTask)
        try await eventually("第一条笔记的会话读取已挂起") { wire.waiting(self.sourcePath) == 1 }
        let loadA = try XCTUnwrap(wire.take(sourcePath))
        store.rewriteWithStyle(noteB)
        let taskB = try XCTUnwrap(store.currentRewriteTask)
        try await eventually("第二条笔记的会话读取已挂起") { wire.waiting(self.sourcePath) == 1 }
        let loadB = try XCTUnwrap(wire.take(sourcePath))
        for (load, note) in [(loadA, noteA), (loadB, noteB)] {
            let query = try XCTUnwrap(load.request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
            XCTAssertEqual(query.first(where: { $0.name == "sourceNoteId" })?.value, note.id)
        }
        loadB.complete(body: #"{"session":null}"#)
        await taskB.value
        await store.chat.waitForIdle()
        loadA.complete(body: Self.history)
        try await eventually("旧读取已取消") { loadA.isStopped }
        await taskA.value
        await store.chat.waitForIdle()
        let posts = wire.requests(chatPath)
        XCTAssertEqual(posts.count, 1)
        let sent = try XCTUnwrap(posts.first?["message"] as? String)
        XCTAssertEqual(Array(sent.utf8), Array(AIChatStore.rewriteNotePrompt.utf8))
        XCTAssertEqual(posts.first?["sourceNoteId"] as? String, noteB.id)
        XCTAssertEqual(posts.first?["useWritingStyle"] as? Bool, true)
        XCTAssertEqual(store.chat.sourceNoteId, noteB.id)
    }

    func testRewriteIgnoresAnOlderDecisionAfterItsSourceLoadSucceeded() async throws {
        let wire = try StyleHTTP()
        defer { wire.close() }
        let (store, _, noteA) = try await connected(wire, mode: "gateway")
        let noteB = Note(id: "note-b", body: "另一条笔记", createdAt: "2026-11-28", revision: 1)
        await store.replace(with: [noteA, noteB], persist: false)
        wire.reply(sourcePath, body: Self.rewriteHistoryA)
        let historyB = Self.history.replacingOccurrences(of: #""sourceNoteId":"note""#, with: #""sourceNoteId":"note-b""#)
        wire.reply(chatPath, body: Self.sse("done", historyB), stream: true)
        var decisionA: CheckedContinuation<Void, Never>?
        store.onBeforeRewriteDecision = { id in
            guard id == noteA.id else { return }
            XCTAssertEqual(store.chat.session?.id, "history-a")
            XCTAssertFalse(store.chat.loadingSession)
            await withCheckedContinuation { decisionA = $0 }
        }
        defer {
            store.onBeforeRewriteDecision = nil
            decisionA?.resume()
        }

        store.rewriteWithStyle(noteA)
        let taskA = try XCTUnwrap(store.currentRewriteTask)
        try await eventually("A 成功读完历史，等待改写决策") { decisionA != nil }
        XCTAssertTrue(wire.requests(chatPath).isEmpty)

        wire.reply(sourcePath, body: #"{"session":null}"#)
        store.rewriteWithStyle(noteB)
        let taskB = try XCTUnwrap(store.currentRewriteTask)
        await taskB.value
        await store.chat.waitForIdle()
        let posts = wire.requests(chatPath)
        XCTAssertEqual(posts.count, 1)
        let sent = try XCTUnwrap(posts.first?["message"] as? String)
        XCTAssertEqual(Array(sent.utf8), Array(AIChatStore.rewriteNotePrompt.utf8))
        XCTAssertEqual(posts.first?["sourceNoteId"] as? String, noteB.id)

        decisionA?.resume()
        decisionA = nil
        await taskA.value
        await store.chat.waitForIdle()
        XCTAssertEqual(wire.requests(chatPath).count, 1)
        XCTAssertEqual(wire.requests(chatPath).first?["sourceNoteId"] as? String, noteB.id)
        XCTAssertEqual(store.chat.sourceNoteId, noteB.id)
    }

    private func assertDeletedRewrite(_ chat: AIChatStore, draft: String = "", savedNew: String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(chat.loadingSession || chat.sending, file: file, line: line)
        XCTAssertNil(chat.session, file: file, line: line)
        XCTAssertNil(chat.sourceNoteId, file: file, line: line)
        XCTAssertFalse(chat.useWritingStyle, file: file, line: line)
        XCTAssertEqual(chat.draft, draft, file: file, line: line)
        XCTAssertEqual(Array(chat.recoverableDraft.utf8), Array(draft.utf8), file: file, line: line)
        let snapshot = chat.recoverableDraftSnapshot
        XCTAssertEqual(snapshot.suppressedAutomaticPrompt, draft.isEmpty, file: file, line: line)
        XCTAssertEqual(snapshot.savedDrafts["new"].map { Array($0.utf8) },
                       savedNew.isEmpty ? nil : Array(savedNew.utf8), file: file, line: line)
        XCTAssertEqual(chat.error, AIChatStore.deletedRewriteSourceMessage, file: file, line: line)
    }

    private func connected(_ wire: StyleHTTP, mode: String, notes: String? = nil,
                           userId: String = "account") async throws -> (AppStore, WeijiAPIClient, Note) {
        wire.reply("/api/session", body: #"{"user":{"id":"\#(userId)","name":"测试账户"},"codexAvailable":true,"codexMode":"\#(mode)"}"#)
        wire.reply("/api/notes", body: notes ?? Self.initialNotes)
        wire.reply("/api/ai/models", body: #"{"models":[]}"#)
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

private final class HeldRequestBody: Encodable, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var encoding = false
    var isEncoding: Bool { lock.withLock { encoding } }

    func encode(to encoder: Encoder) throws {
        lock.withLock { encoding = true }
        guard release.wait(timeout: .now() + 8) == .success else { throw WeijiAPIError.interrupted }
        var body = encoder.singleValueContainer()
        try body.encode(["content": "fixture"])
    }
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

    func finish() {
        deliver { $0.urlProtocolDidFinishLoading(self) }
    }

    func fail(_ error: Error) {
        deliver { $0.urlProtocol(self, didFailWithError: error) }
    }

    func complete(status: Int = 200, body: String, stream: Bool = false) {
        begin(status: status, stream: stream)
        write(body)
        finish()
    }
}
