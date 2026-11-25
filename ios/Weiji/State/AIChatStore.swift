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
    var draft = ""
    var recoverableDraft: String { draft.isEmpty ? (inflightDraft ?? "") : draft }
    private(set) var composerResetCount = 0
    var useProfile = true
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
    private var source: String?
    @ObservationIgnored private var requestID = ChatRequestID()
    @ObservationIgnored private var inflightDraft: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var pendingDelta = ""
    @ObservationIgnored private var pendingReasoning = ""
    @ObservationIgnored private var reasoningLength = 0
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?

    func start(source: String? = nil, pins: [String] = [], insight: InsightReport? = nil) {
        stop()
        sessionTask?.cancel()
        loadingSession = false
        draft = ""
        session = nil
        self.source = source
        var seen = Set<String>()
        self.pins = Array(pins.filter { seen.insert($0).inserted }.prefix(10))
        self.insight = insight
        error = nil
    }

    func reset() {
        start()
        listGeneration += 1
        listTask?.cancel()
        sessions = []
        cursor = nil
        loadingList = false
        useProfile = true
    }

    func togglePin(_ id: String) {
        if pins.contains(id) { pins.removeAll { $0 == id } }
        else if pins.count < 10 { pins.append(id) }
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
        finishStreaming()
        streamedText = ""
        pendingQuestion = ""
        requestID.clear()
        if wasSending, draft.isEmpty, let unsent { draft = unsent }
    }

    func loadSource(_ source: String, api: WeijiAPIClient) {
        load(WeijiAPIClient.withQuery("/api/ai/sessions", [URLQueryItem(name: "sourceNoteId", value: source)]), api: api)
    }

    func select(_ id: String, api: WeijiAPIClient) {
        start()
        load("/api/ai/sessions/\(id)", api: api)
    }

    private func load(_ path: String, api: WeijiAPIClient) {
        generation += 1
        let stamp = generation
        sessionTask?.cancel()
        loadingSession = true
        sessionTask = Task {
            defer { if stamp == generation { loadingSession = false } }
            do {
                let response: ChatResponse = try await api.get(path)
                guard stamp == generation, !Task.isCancelled else { return }
                session = response.session
            } catch is CancellationError {
            } catch {
                if stamp == generation { self.error = error.localizedDescription }
            }
        }
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
            sessions.removeAll { $0.id == id }
        } catch is CancellationError {
        } catch {
            if stamp == listGeneration { self.error = error.localizedDescription }
        }
    }

    func send(api: WeijiAPIClient, options: AIOptions, profile: InsightsStore) {
        guard !sending, !loadingSession, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let typed = draft
        draft = ""
        composerResetCount += 1
        inflightDraft = typed
        pendingQuestion = typed
        generation += 1
        let stamp = generation
        sending = true
        error = nil
        task = Task {
            defer {
                if stamp == generation {
                    finishStreaming()
                    sending = false
                    pendingQuestion = ""
                    streamedText = ""
                    inflightDraft = nil
                }
            }
            do {
                try await profile.awaitProfileSave()
                try Task.checkCancellation()
                guard stamp == generation else { return }
                let message = Self.message(typed, insight: session == nil ? insight : nil)
                let signature = ChatSignature(sessionId: session?.id, expectedVersion: session?.version,
                                              sourceNoteId: session?.sourceNoteId ?? source, message: message,
                                              referencedNoteIds: pins, model: options.model, provider: options.provider,
                                              useProfile: useProfile, reasoningEffort: options.reasoningEffort)
                var fields = options.fields
                fields["message"] = .string(message)
                fields["referencedNoteIds"] = .strings(signature.referencedNoteIds)
                fields["useProfile"] = .bool(signature.useProfile)
                fields["clientRequestId"] = .string(requestID.resolve(signature))
                if let id = signature.sessionId { fields["sessionId"] = .string(id) }
                if let id = signature.sourceNoteId { fields["sourceNoteId"] = .string(id) }
                if let version = signature.expectedVersion { fields["expectedVersion"] = .number(version) }
                let response: ChatResponse = try await api.stream("/api/ai/chat", fields) { [weak self] frame in
                    await self?.receive(frame, generation: stamp)
                }
                guard stamp == generation, !Task.isCancelled, let latest = response.session else { return }
                session = latest
                insight = nil
                requestID.clear()
                inflightDraft = nil
            } catch is CancellationError {
            } catch let failure as WeijiAPIError where failure.status == 409 {
                guard stamp == generation else { return }
                if let current = failure.current(ChatSession.self) { session = current }
                else if let id = session?.id {
                    let latest: ChatResponse? = try? await api.get("/api/ai/sessions/\(id)")
                    guard stamp == generation else { return }
                    if let updated = latest?.session { session = updated }
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
