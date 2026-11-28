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
    private static let expired = #"{"error":"登录已过期"}"#
    private static let newDraft = " 原有新对话草稿 "
    private nonisolated static let firstDraft = " 第一段用户原文含换行\n🪴 "
    private nonisolated static let nextDraft = "第二段补充包含空格与表情🙂\t"
    private let stylePath = "/api/ai/writing-style"
    private let generatePath = "/api/ai/writing-style/generate"
    private let blindPath = "/api/ai/writing-style/blind-test"
    private let chatPath = "/api/ai/chat"
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
        XCTAssertEqual(wire.requests(chatPath).count, 1)
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
        XCTAssertEqual(posts.first?["message"] as? String, draft)
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
            assertDeletedRewrite(chat, recoverableDraft: savedNew)
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

    func testWalkAndInsightDraftsRestoreInTheirOriginalContextAfter401() async throws {
        enum Entry: CaseIterable { case walk, insight }
        let savedNew = Self.newDraft
        let typed = " AI草稿含换行\n🙂下一行"
        XCTAssertEqual(savedNew.utf8.count, 23)
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

                wire.reply("/api/notes", status: 401, body: Self.expired)
                store.refresh()
                try await eventually("刷新笔记返回 401") { store.authScreenState == .needsLogin && !store.syncing }
                wire.reply("/api/notes", body: Self.initialNotes)
                try await reauthenticate(store, wire: wire)

                XCTAssertEqual(Array(chat.draft.utf8), Array(savedNew.utf8), scenario)
                openEntry()
                XCTAssertEqual(Array(chat.draft.utf8), Array(typed.utf8), scenario)
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
                assertDeletedRewrite(chat, draft: expected, recoverableDraft: recovered)
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

    private func beginAutomaticRewriteWaitingForSave(_ note: Note, store: AppStore, api: WeijiAPIClient,
                                                     wire: StyleHTTP) async throws -> Task<Bool, Never> {
        wire.reply(stylePath, body: Self.styleEnvelope)
        await store.insights.loadWritingStyle(api: api)
        wire.hold(stylePath, method: "POST")
        let save = try XCTUnwrap(store.insights.saveWritingStyle(.init(rules: "正在保存"), api: api))
        try await eventually("风格保存已挂起") { wire.waiting(self.stylePath, method: "POST") == 1 }
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

    private func assertDraftSurvivesHistoryRoundTrip(_ draft: String, store: AppStore, wire: StyleHTTP, file: StaticString = #filePath, line: UInt = #line) async throws {
        wire.reply(rewriteHistoryPath, body: Self.rewriteHistoryA)
        store.requestSelectChatSession("history-a")
        try await eventually("打开历史会话", {
            !store.chat.loadingSession && store.chat.session?.id == "history-a"
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
        assertDeletedRewrite(store.chat, recoverableDraft: existingNew)
        // Exit relay through the provider switch so the current chat is not reset.
        store.setProvider(.openai)
        XCTAssertFalse(store.isRelayMode)
        store.chat.send(api: api, options: store.options, profile: store.insights, isRelayMode: { store.isRelayMode })
        response.complete(body: Self.styleEnvelope)
        let saved = await save.value
        XCTAssertTrue(saved)
        await store.chat.waitForIdle()
        assertDeletedRewrite(store.chat, recoverableDraft: existingNew)
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
            XCTAssertEqual(originalPosts.first?["message"] as? String, draft.isEmpty ? AIChatStore.rewriteNotePrompt : draft)
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
        XCTAssertEqual(postsBefore.first?["message"] as? String, AIChatStore.rewriteNotePrompt)
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
        XCTAssertEqual(wire.requests(chatPath).count, 1)
        XCTAssertEqual(wire.requests(chatPath).first?["sourceNoteId"] as? String, note.id)
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
        XCTAssertEqual(wire.requests(chatPath).count, 1)
        XCTAssertEqual(wire.requests(chatPath).first?["sourceNoteId"] as? String, noteB.id)

        decisionA?.resume()
        decisionA = nil
        await taskA.value
        await store.chat.waitForIdle()
        XCTAssertEqual(wire.requests(chatPath).count, 1)
        XCTAssertEqual(wire.requests(chatPath).first?["sourceNoteId"] as? String, noteB.id)
        XCTAssertEqual(store.chat.sourceNoteId, noteB.id)
    }

    private func assertDeletedRewrite(_ chat: AIChatStore, draft: String = "", recoverableDraft: String? = nil,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(chat.loadingSession || chat.sending, file: file, line: line)
        XCTAssertNil(chat.session, file: file, line: line)
        XCTAssertNil(chat.sourceNoteId, file: file, line: line)
        XCTAssertFalse(chat.useWritingStyle, file: file, line: line)
        XCTAssertEqual(chat.draft, draft, file: file, line: line)
        XCTAssertEqual(chat.recoverableDraft, recoverableDraft ?? draft, file: file, line: line)
        XCTAssertEqual(chat.error, AIChatStore.deletedRewriteSourceMessage, file: file, line: line)
    }

    private func connected(_ wire: StyleHTTP, mode: String) async throws -> (AppStore, WeijiAPIClient, Note) {
        wire.reply("/api/session", body: #"{"user":{"id":"account","name":"测试账户"},"codexAvailable":true,"codexMode":"\#(mode)"}"#)
        wire.reply("/api/notes", body: Self.initialNotes)
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
