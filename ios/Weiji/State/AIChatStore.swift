import Foundation
import Observation

struct ChatSignature: Equatable {
    var sessionId: String?
    var expectedVersion: Int?
    var sourceNoteId: String?
    var message: String
    var referencedNoteIds: [String]
    var model: String
    var provider: AIProvider
    var useProfile: Bool
    var reasoningEffort = ""
    var useWritingStyle = false
}

struct ChatRequestID {
    private var previous: ChatSignature?
    private var id = ""

    mutating func resolve(_ signature: ChatSignature) -> String {
        if previous != signature {
            id = UUID().uuidString.lowercased()
            previous = signature
        }
        return id
    }

    mutating func clear() { previous = nil; id = "" }
}

@Observable @MainActor
final class AIChatStore {
    static let rewriteNotePrompt = "请基于这条笔记的真实内容，按我的写作风格改写成一段自然流畅的文字，保留原意和事实，不要编造经历。"

    var draft = ""
    var recoverableDraft: String { draft.isEmpty ? (inflightDraft ?? "") : draft }
    private(set) var composerResetCount = 0
    var useProfile = true
    var useWritingStyle = false
    @ObservationIgnored private var sendingWithStyle = false
    private(set) var pins: [String] = []
    private(set) var session: ChatSession?
    private(set) var insight: InsightReport?
    private(set) var streamedText = ""
    private(set) var liveSteps: [ChatStep] = []
    private(set) var liveReasoning = ""
    private(set) var liveCitations: [Citation] = []
    private(set) var pendingQuestion = ""
    private(set) var status: String?
    private(set) var error: String?
    private(set) var sending = false
    private(set) var loadingSession = false
    private(set) var sessions: [ChatSession] = []
    private(set) var cursor: String?
    private(set) var loadingList = false
    private(set) var sourceNoteId: String?
    @ObservationIgnored private var validNoteIds: Set<String>?
    @ObservationIgnored private var pinsEditedDuringLoad = false
    @ObservationIgnored private var draftContextKey = "new"
    @ObservationIgnored private var draftsByKey: [String: String] = [:]
    @ObservationIgnored private var requestID = ChatRequestID()
    @ObservationIgnored private var inflightDraft: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var pendingDelta = ""
    @ObservationIgnored private var pendingReasoning = ""
    @ObservationIgnored private var reasoningLength = 0
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sessionTask: Task<Bool, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?

    func start(source: String? = nil, pins: [String] = [], insight: InsightReport? = nil, useWritingStyle: Bool = false) {
        let source = source.flatMap { $0.isEmpty ? nil : $0 }
        let nextKey = source.map { "note:\($0)" }
            ?? insight.map { "insight:\($0.id)" }
            ?? (pins.isEmpty ? "new" : "pins:" + pins.joined(separator: ","))
        switchDraftContext(to: nextKey, resetNew: true)
        sourceNoteId = validSource(source)
        var seen = Set<String>()
        let candidates = (source.map { [$0] } ?? []) + pins
        self.pins = Array(candidates.filter { isValidNote($0) && seen.insert($0).inserted }.prefix(10))
        self.insight = insight
        self.useWritingStyle = useWritingStyle
    }

    private func switchDraftContext(to nextKey: String, resetNew: Bool = false) {
        stop()
        // Stop can restore the interrupted question; save it under the context it came from.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftsByKey.removeValue(forKey: draftContextKey)
        } else {
            draftsByKey[draftContextKey] = draft
        }
        if nextKey != draftContextKey {
            draftContextKey = nextKey
            draft = draftsByKey[nextKey] ?? ""
        } else if resetNew && nextKey == "new" {
            draft = ""
            draftsByKey.removeValue(forKey: nextKey)
        }
        requestID.clear()
        useWritingStyle = false
        sendingWithStyle = false
        session = nil
        sourceNoteId = nil
        pins = []
        pinsEditedDuringLoad = false
        insight = nil
        error = nil
    }

    func reset() {
        validNoteIds = nil
        pinsEditedDuringLoad = false
        start()
        draftsByKey = [:]
        draftContextKey = "new"
        draft = ""
        listGeneration += 1
        listTask?.cancel()
        sessions = []
        cursor = nil
        loadingList = false
        useProfile = true
    }

    func syncValidIds(_ ids: Set<String>) {
        validNoteIds = ids
        pins.removeAll { !ids.contains($0) }
        sourceNoteId = validSource(sourceNoteId)
    }

    func canReference(_ id: String) -> Bool { isValidNote(id) }

    private func isValidNote(_ id: String) -> Bool { validNoteIds?.contains(id) ?? true }

    private func validSource(_ id: String?) -> String? { id.flatMap { isValidNote($0) ? $0 : nil } }

    func togglePin(_ id: String) {
        pinsEditedDuringLoad = true
        if pins.contains(id) { pins.removeAll { $0 == id } }
        else if isValidNote(id) && pins.count < 10 { pins.append(id) }
    }

    func stop() {
        let wasSending = sending
        let unsent = inflightDraft
        inflightDraft = nil
        generation += 1
        task?.cancel()
        sessionTask?.cancel()
        loadingSession = false
        sending = false
        sendingWithStyle = false
        finishStreaming()
        streamedText = ""
        pendingQuestion = ""
        if wasSending, draft.isEmpty, let unsent { draft = unsent }
    }

    func restorePendingSessionDraftIfPresent() -> Bool {
        guard let id = session?.id else { return false }
        let key = "session:\(id)"
        guard let pending = draftsByKey[key], !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        draftContextKey = key
        draft = pending
        return true
    }

    @discardableResult
    func loadSource(_ source: String, api: WeijiAPIClient) -> Task<Bool, Never> {
        let path = WeijiAPIClient.withQuery("/api/ai/sessions", [URLQueryItem(name: "sourceNoteId", value: source)])
        return load(path, api: api, restoreSourcePin: false)
    }

    @discardableResult
    func select(_ id: String, api: WeijiAPIClient) -> Task<Void, Never> {
        switchDraftContext(to: "session:\(id)")
        let loadTask = load("/api/ai/sessions/\(id)", api: api, restoreSourcePin: true)
        return Task {
            await withTaskCancellationHandler { _ = await loadTask.value } onCancel: { loadTask.cancel() }
        }
    }

    private func load(_ path: String, api: WeijiAPIClient, restoreSourcePin: Bool) -> Task<Bool, Never> {
        generation += 1
        let stamp = generation
        sessionTask?.cancel()
        loadingSession = true
        let currentTask = Task {
            defer { if stamp == generation { loadingSession = false } }
            do {
                try Task.checkCancellation()
                let response: ChatResponse = try await api.get(path)
                guard stamp == generation, !Task.isCancelled else { return false }
                session = response.session
                if let rawSource = response.session?.sourceNoteId {
                    let source = validSource(rawSource)
                    if restoreSourcePin {
                        sourceNoteId = source
                        if !pinsEditedDuringLoad, let source, !pins.contains(source), pins.count < 10 {
                            pins.insert(source, at: 0)
                        }
                    } else if sourceNoteId == nil {
                        sourceNoteId = source
                    }
                }
                return true
            } catch is CancellationError {
                return false
            } catch {
                if stamp == generation, !Task.isCancelled { self.error = error.localizedDescription }
                return false
            }
        }
        sessionTask = currentTask
        return currentTask
    }

    func refreshSessions(api: WeijiAPIClient, more: Bool = false) {
        guard !more || (!loadingList && cursor != nil) else { return }
        listGeneration += 1
        let stamp = listGeneration
        listTask?.cancel()
        loadingList = true
        var query = [URLQueryItem(name: "limit", value: "20")]
        if more { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let path = WeijiAPIClient.withQuery("/api/ai/sessions", query)
        listTask = Task {
            defer { if stamp == listGeneration { loadingList = false } }
            do {
                let page: ChatPage = try await api.get(path)
                guard stamp == listGeneration else { return }
                sessions = more ? sessions + page.sessions.filter { item in !sessions.contains { $0.id == item.id } } : page.sessions
                cursor = page.nextCursor
            } catch is CancellationError {
            } catch {
                if stamp == listGeneration { self.error = error.localizedDescription }
            }
        }
    }

    func remove(_ id: String, api: WeijiAPIClient) async {
        let stamp = listGeneration
        do {
            let _: DeletedResponse = try await api.delete("/api/ai/sessions/\(id)")
            guard stamp == listGeneration else { return }
            if session?.id == id { start() }
            draftsByKey.removeValue(forKey: "session:\(id)")
            sessions.removeAll { $0.id == id }
        } catch is CancellationError {
        } catch {
            if stamp == listGeneration { self.error = error.localizedDescription }
        }
    }

    func toggleWritingStyle(isRelayMode: Bool) {
        guard !sending else { return }
        if useWritingStyle {
            useWritingStyle = false
            if error == InsightsStore.writingStyleRelayMessage { error = nil }
        } else if isRelayMode {
            error = InsightsStore.writingStyleRelayMessage
        } else {
            useWritingStyle = true
        }
    }

    func reconcileRelayMode(_ isRelay: Bool) {
        guard isRelay else {
            if error == InsightsStore.writingStyleRelayMessage { error = nil }
            return
        }
        guard useWritingStyle || sendingWithStyle else { return }
        if sending && sendingWithStyle {
            let unsent = inflightDraft
            let next = draft
            stop()
            if let unsent, !next.isEmpty { draft = unsent + "\n\n" + next }
        }
        useWritingStyle = true
        error = InsightsStore.writingStyleRelayMessage
    }

    func send(api: WeijiAPIClient, options: AIOptions, profile: InsightsStore,
              isRelayMode: @escaping @MainActor () -> Bool = { false }) {
        let styled = useWritingStyle
        guard !(styled && isRelayMode()) else { error = InsightsStore.writingStyleRelayMessage; return }
        guard !sending, !loadingSession, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let typed = draft
        draft = ""
        composerResetCount += 1
        inflightDraft = typed
        pendingQuestion = typed
        generation += 1
        let stamp = generation
        sending = true
        sendingWithStyle = styled
        error = nil
        task = Task {
            defer {
                if stamp == generation {
                    finishStreaming()
                    sending = false
                    sendingWithStyle = false
                    pendingQuestion = ""
                    streamedText = ""
                    inflightDraft = nil
                }
            }
            do {
                try await profile.awaitProfileSave()
                if styled { try await profile.awaitWritingStyleSave() }
                try Task.checkCancellation()
                guard stamp == generation else { return }
                if styled && isRelayMode() {
                    reconcileRelayMode(true)
                    return
                }
                let message = Self.message(typed, insight: session == nil ? insight : nil)
                let signature = ChatSignature(sessionId: session?.id, expectedVersion: session?.version,
                                              sourceNoteId: validSource(sourceNoteId), message: message,
                                              referencedNoteIds: pins, model: options.model, provider: options.provider,
                                              useProfile: useProfile, reasoningEffort: options.reasoningEffort,
                                              useWritingStyle: styled)
                var fields = options.fields
                fields["message"] = .string(message)
                fields["referencedNoteIds"] = .strings(signature.referencedNoteIds)
                fields["useProfile"] = .bool(signature.useProfile)
                if styled { fields["useWritingStyle"] = .bool(true) }
                fields["clientRequestId"] = .string(requestID.resolve(signature))
                if let id = signature.sessionId { fields["sessionId"] = .string(id) }
                if let id = signature.sourceNoteId { fields["sourceNoteId"] = .string(id) }
                if let version = signature.expectedVersion { fields["expectedVersion"] = .number(version) }
                let response: ChatResponse = try await api.stream("/api/ai/chat", fields) { [weak self] frame in
                    await self?.receive(frame, generation: stamp)
                }
                guard stamp == generation, !Task.isCancelled else { return }
                guard let latest = response.session else { throw WeijiAPIError.interrupted }
                updateSession(latest)
                if styled { useWritingStyle = false }
                let previousKey = draftContextKey
                let nextKey = "session:\(latest.id)"
                draftsByKey.removeValue(forKey: previousKey)
                draftContextKey = nextKey
                // Sending from a note/walk/insight entry can converge into an existing session that already holds an unsent draft.
                if previousKey != nextKey,
                   draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let preserved = draftsByKey[nextKey] {
                    draft = preserved
                }
                insight = nil
                requestID.clear()
                inflightDraft = nil
            } catch is CancellationError {
                if stamp == generation, draft.isEmpty, let unsent = inflightDraft { draft = unsent }
            } catch let failure as WeijiAPIError where failure.status == 409 {
                guard stamp == generation else { return }
                if let current = failure.current(ChatSession.self) { updateSession(current) }
                else if let id = session?.id {
                    let latest: ChatResponse? = try? await api.get("/api/ai/sessions/\(id)")
                    guard stamp == generation else { return }
                    if let updated = latest?.session { updateSession(updated) }
                }
                if draft.isEmpty, let unsent = inflightDraft { draft = unsent }
                error = failure.message
            } catch {
                if stamp == generation {
                    if draft.isEmpty, let unsent = inflightDraft { draft = unsent }
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func updateSession(_ latest: ChatSession) {
        session = latest
        sourceNoteId = validSource(latest.sourceNoteId)
    }

    func receive(_ frame: SSEParser.Frame, generation stamp: Int) {
        guard stamp == generation, sending else { return }
        let data = Data(frame.data.utf8)
        let decoder = JSONDecoder()
        switch frame.event {
        case "step":
            guard let step = try? decoder.decode(ChatStep.self, from: data) else { return }
            if let index = liveSteps.firstIndex(where: { $0.id == step.id }) { liveSteps[index] = step }
            else { liveSteps.append(step) }
        case "citations":
            if let frame = try? decoder.decode(StreamCitations.self, from: data) { liveCitations = frame.citations }
        case "reasoning":
            let remaining = 20_000 - reasoningLength
            guard remaining > 0, let frame = try? decoder.decode(StreamReasoning.self, from: data) else { return }
            let chunk = frame.text.prefix(remaining)
            pendingReasoning += chunk
            reasoningLength += chunk.count
            scheduleFlush()
        case "delta":
            guard let delta = try? decoder.decode(StreamDelta.self, from: data) else { return }
            pendingDelta += delta.text
            scheduleFlush()
        case "status":
            status = (try? decoder.decode(StreamStatus.self, from: data))?.message
        case "done":
            finishStreaming()
        default: break
        }
    }

    private func scheduleFlush() {
        guard streamingTask == nil else { return }
        streamingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            self?.flushStreaming()
        }
    }

    func flushStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        if !pendingDelta.isEmpty {
            streamedText += pendingDelta
            pendingDelta = ""
        }
        if !pendingReasoning.isEmpty {
            liveReasoning += pendingReasoning
            pendingReasoning = ""
        }
    }

    private func finishStreaming() {
        flushStreaming()
        liveSteps = []
        liveReasoning = ""
        reasoningLength = 0
        liveCitations = []
        status = nil
    }

    static func message(_ typed: String, insight: InsightReport?) -> String {
        guard let insight else { return typed }
        let before = "[洞察上下文：\(insight.title)（\(insight.lensName)）]\n"
        let after = "\n\n[追问]\n" + clippedUTF16(typed, to: 7900 - before.utf16.count - 8)
        return before + clippedUTF16(insight.content ?? "", to: 7900 - before.utf16.count - after.utf16.count) + after
    }
}
