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
    static let deletedRewriteSourceMessage = "原笔记已删除，已取消按风格改写。"
    private static let postDeleteDraftKey = "post-delete"

    struct RecoverableDraftSnapshot: Equatable, Sendable {
        let activeContextKey: String
        let activeDraft: String
        let savedDrafts: [String: String]
        let suppressedAutomaticPrompt: Bool
        var isEmpty: Bool { activeDraft.isEmpty && savedDrafts.isEmpty }
    }

    private enum AutomaticPromptLocation {
        case none, inDraft, inFlight
    }

    private struct RewriteIntent {
        let sourceNoteId: String
        var introducedByRewrite: Bool
        var promptLocation: AutomaticPromptLocation
    }

    var draft = ""
    var recoverableDraftSnapshot: RecoverableDraftSnapshot {
        var activeDraft = activeUserText()
        if draftContextKey == "new", sending, let rescued = draftsByKey["new"] {
            activeDraft = Self.appendDraft(activeDraft, rescued)
        }
        let hasUserDraft = Self.hasDraftText(draft) && !isOwnedInDraft(draft)
        let suppressed = isOwnedInDraft(draft)
            || (!hasUserDraft && sending && inflightDraft.map(isOwnedInFlight) == true)
            || (draftContextKey == Self.postDeleteDraftKey && !Self.hasDraftText(activeDraft))
        let savedDrafts = draftsByKey.filter { key, text in
            key != draftContextKey && key != Self.postDeleteDraftKey && Self.hasDraftText(text)
                && !isDeletedDraftContext(key)
        }
        let activeKey = isDeletedDraftContext(draftContextKey) ? Self.postDeleteDraftKey : draftContextKey
        return RecoverableDraftSnapshot(activeContextKey: activeKey, activeDraft: activeDraft,
                                        savedDrafts: savedDrafts, suppressedAutomaticPrompt: suppressed)
    }
    var recoverableDraft: String {
        let snapshot = recoverableDraftSnapshot
        if snapshot.suppressedAutomaticPrompt { return "" }
        return snapshot.activeDraft.isEmpty ? (snapshot.savedDrafts["new"] ?? "") : snapshot.activeDraft
    }
    private(set) var composerResetCount = 0
    var useProfile = true
    var useWritingStyle = false
    @ObservationIgnored private var sendingWithStyle = false
    @ObservationIgnored private var pendingRequiredSourceNoteId: String?
    @ObservationIgnored private var rewriteIntent: RewriteIntent?
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
    @ObservationIgnored private var deletedInsightIds: Set<String> = []
    @ObservationIgnored private var pinsEditedDuringLoad = false
    @ObservationIgnored private var draftContextKey = "new"
    // Inactive drafts and orphaned drafts rescued while New Chat is sending.
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

    func updateDraftFromUser(_ text: String) {
        if rewriteIntent?.promptLocation == .inDraft { rewriteIntent?.promptLocation = .none }
        draft = text
    }

    func restoreRecoverableDrafts(_ snapshot: RecoverableDraftSnapshot) {
        draftsByKey = snapshot.savedDrafts
        if snapshot.suppressedAutomaticPrompt {
            draftContextKey = Self.postDeleteDraftKey
            draft = ""
            return
        }
        let savedNew = draftsByKey.removeValue(forKey: "new") ?? ""
        draftContextKey = "new"
        let key = snapshot.activeContextKey
        let active = snapshot.activeDraft
        let isSourceBoundContext = (key.hasPrefix("insight:") && !isDeletedDraftContext(key))
            || (key.hasPrefix("walk:") && isValidNoteDraftContext(key))
        let isIndependentContext = key != "new" && key != Self.postDeleteDraftKey && !isDeletedDraftContext(key)
        if Self.hasDraftText(active), isSourceBoundContext || (isIndependentContext && Self.hasDraftText(savedNew)) {
            draftsByKey[key] = active
            draft = savedNew
        } else {
            draft = Self.appendDraft(savedNew, active)
        }
    }

    func start(source: String? = nil, pins: [String] = [], insight: InsightReport? = nil,
               useWritingStyle: Bool = false, rewriteSourceNoteId: String? = nil) {
        let source = source.flatMap { $0.isEmpty ? nil : $0 }
        let nextKey = source.map { "note:\($0)" }
            ?? insight.map { "insight:\($0.id)" }
            ?? pins.first.map { "walk:\($0)" }
            ?? "new"
        switchDraftContext(to: nextKey, resetNew: true)
        sourceNoteId = validSource(source)
        var seen = Set<String>()
        let candidates = (source.map { [$0] } ?? []) + pins
        self.pins = Array(candidates.filter { isValidNote($0) && seen.insert($0).inserted }.prefix(10))
        self.insight = insight
        self.useWritingStyle = useWritingStyle
        if let id = rewriteSourceNoteId {
            rewriteIntent = RewriteIntent(sourceNoteId: id, introducedByRewrite: true, promptLocation: .none)
        }
    }

    private func switchDraftContext(to nextKey: String, resetNew: Bool = false) {
        let resettingNew = resetNew && nextKey == "new" && draftContextKey == nextKey
        // Take unseen rescued drafts out before stop() merges them into the draft being discarded.
        let unseenRescued = resettingNew ? draftsByKey.removeValue(forKey: "new") : nil
        stop()
        // An abandoned automatic prompt must not come back as an ordinary saved draft.
        if isOwnedInDraft(draft) { draft = "" }
        rewriteIntent = nil
        if nextKey != draftContextKey {
            // Stop can restore the interrupted question before the old context is saved.
            if draftContextKey == Self.postDeleteDraftKey || isDeletedDraftContext(draftContextKey) {
                draftsByKey.removeValue(forKey: draftContextKey)
                if Self.hasDraftText(draft) {
                    draftsByKey["new"] = Self.appendDraft(draftsByKey["new"] ?? "", draft)
                }
            } else if Self.hasDraftText(draft) {
                draftsByKey[draftContextKey] = draft
            } else {
                draftsByKey.removeValue(forKey: draftContextKey)
            }
            draftContextKey = nextKey
            draft = draftsByKey.removeValue(forKey: nextKey) ?? ""
        } else if resettingNew {
            draft = unseenRescued ?? ""
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
        deletedInsightIds = []
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
        if let intent = rewriteIntent, !ids.contains(intent.sourceNoteId) {
            cancelDeletedRewrite(intent)
        } else {
            _ = validateRequiredSource(pendingRequiredSourceNoteId)
        }
        rescueOrphanedDrafts()
    }

    func markInsightDeleted(_ id: String) {
        deletedInsightIds.insert(id)
        if insight?.id == id { insight = nil }
        rescueOrphanedDrafts()
    }

    var pendingInsightDraftIds: [String] {
        var ids = Set(draftsByKey.compactMap { key, text in
            Self.hasDraftText(text) ? Self.boundInsightId(forContextKey: key) : nil
        })
        if let id = Self.boundInsightId(forContextKey: draftContextKey) { ids.insert(id) }
        return ids.subtracting(deletedInsightIds).sorted()
    }

    private func rescueOrphanedDrafts() {
        let orphanedKeys = draftsByKey.keys.filter { isDeletedDraftContext($0) }.sorted()
        for key in orphanedKeys {
            guard let rescued = draftsByKey.removeValue(forKey: key), Self.hasDraftText(rescued) else { continue }
            if draftContextKey == "new" && !sending {
                draft = Self.appendDraft(draft, rescued)
            } else {
                draftsByKey["new"] = Self.appendDraft(draftsByKey["new"] ?? "", rescued)
            }
        }
    }

    private func isOwnedInDraft(_ text: String) -> Bool {
        rewriteIntent?.promptLocation == .inDraft && text == Self.rewriteNotePrompt
    }

    private func isOwnedInFlight(_ text: String) -> Bool {
        rewriteIntent?.promptLocation == .inFlight && text == Self.rewriteNotePrompt
    }

    private func activeUserText() -> String {
        let unsent = sending ? inflightDraft : nil
        let keepUnsent = unsent.flatMap { isOwnedInFlight($0) ? nil : $0 } ?? ""
        let keepDraft = isOwnedInDraft(draft) ? "" : draft
        return Self.appendDraft(keepUnsent, keepDraft)
    }

    private func restoreInterruptedDraft(_ unsent: String?, preserveWithFollowUp: Bool = false) {
        let unsentIsAuto = unsent.map(isOwnedInFlight) ?? false
        let rescued = draftContextKey == "new" ? draftsByKey.removeValue(forKey: "new") : nil
        if !Self.hasDraftText(draft), rescued == nil, let unsent {
            draft = unsent
            if unsentIsAuto { rewriteIntent?.promptLocation = .inDraft }
            return
        }
        if rescued != nil || preserveWithFollowUp || isDeletedDraftContext(draftContextKey) {
            let keepUnsent = unsentIsAuto ? "" : (unsent ?? "")
            draft = Self.appendDraft(Self.appendDraft(keepUnsent, draft), rescued ?? "")
            if unsentIsAuto { rewriteIntent?.promptLocation = .none }
            return
        }
        if rewriteIntent?.promptLocation == .inFlight {
            rewriteIntent?.promptLocation = .none
        }
    }

    private func cancelDeletedRewrite(_ intent: RewriteIntent) {
        let preserved = activeUserText()
        stop()
        draftsByKey.removeValue(forKey: "note:\(intent.sourceNoteId)")
        rewriteIntent = nil
        if intent.introducedByRewrite {
            if draftContextKey.hasPrefix("session:") { draftsByKey.removeValue(forKey: draftContextKey) }
            session = nil
            sourceNoteId = nil
            useWritingStyle = false
        }
        if Self.hasDraftText(preserved) {
            let savedNew = draftsByKey.removeValue(forKey: "new") ?? ""
            draftContextKey = "new"
            draft = Self.appendDraft(savedNew, preserved)
        } else {
            draftContextKey = Self.postDeleteDraftKey
            draft = ""
        }
        error = Self.deletedRewriteSourceMessage
    }

    private static func hasDraftText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func appendDraft(_ earlier: String, _ later: String) -> String {
        let hasEarlier = hasDraftText(earlier)
        let hasLater = hasDraftText(later)
        if hasEarlier && hasLater { return earlier + "\n\n" + later }
        if hasEarlier { return earlier }
        return hasLater ? later : ""
    }

    private func validateRequiredSource(_ required: String?) -> Bool {
        guard let required, sourceNoteId != required || !canReference(required) else { return true }
        cancelDeletedRewrite(rewriteIntent ?? RewriteIntent(sourceNoteId: required, introducedByRewrite: false, promptLocation: .none))
        return false
    }

    func canReference(_ id: String) -> Bool { isValidNote(id) }

    private static func boundNoteId(forContextKey key: String) -> String? {
        guard key.hasPrefix("note:") || key.hasPrefix("walk:") else { return nil }
        return String(key.dropFirst(5))
    }

    private static func boundInsightId(forContextKey key: String) -> String? {
        key.hasPrefix("insight:") ? String(key.dropFirst(8)) : nil
    }

    private func isValidNoteDraftContext(_ key: String) -> Bool {
        guard let id = Self.boundNoteId(forContextKey: key) else { return false }
        return isValidNote(id)
    }

    private func isDeletedNoteDraftContext(_ key: String) -> Bool {
        Self.boundNoteId(forContextKey: key).map { !isValidNote($0) } ?? false
    }

    private func isDeletedDraftContext(_ key: String) -> Bool {
        isDeletedNoteDraftContext(key) || (Self.boundInsightId(forContextKey: key).map { deletedInsightIds.contains($0) } ?? false)
    }

    private func isValidNote(_ id: String) -> Bool { validNoteIds?.contains(id) ?? true }

    private func validSource(_ id: String?) -> String? { id.flatMap { isValidNote($0) ? $0 : nil } }

    func togglePin(_ id: String) {
        pinsEditedDuringLoad = true
        if pins.contains(id) { pins.removeAll { $0 == id } }
        else if isValidNote(id) && pins.count < 10 { pins.append(id) }
    }

    func stop(preserveInFlightWithDraft: Bool = false) {
        let wasSending = sending
        let unsent = inflightDraft
        inflightDraft = nil
        generation += 1
        task?.cancel()
        sessionTask?.cancel()
        loadingSession = false
        sending = false
        sendingWithStyle = false
        pendingRequiredSourceNoteId = nil
        finishStreaming()
        streamedText = ""
        pendingQuestion = ""
        if wasSending { restoreInterruptedDraft(unsent, preserveWithFollowUp: preserveInFlightWithDraft) }
    }

    func restorePendingSessionDraftIfPresent() -> Bool {
        guard let id = session?.id else { return false }
        let key = "session:\(id)"
        guard let pending = draftsByKey.removeValue(forKey: key), Self.hasDraftText(pending) else { return false }
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
            stop(preserveInFlightWithDraft: true)
        }
        useWritingStyle = true
        error = InsightsStore.writingStyleRelayMessage
    }

    func beginAutomaticRewriteSend(sourceNoteId: String, api: WeijiAPIClient, options: AIOptions, profile: InsightsStore,
                                   isRelayMode: @escaping @MainActor () -> Bool = { false }) {
        guard !isRelayMode(), self.sourceNoteId == sourceNoteId, canReference(sourceNoteId),
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rewriteIntent = RewriteIntent(sourceNoteId: sourceNoteId, introducedByRewrite: true, promptLocation: .inDraft)
        draft = Self.rewriteNotePrompt
        send(api: api, options: options, profile: profile, requiredSourceNoteId: sourceNoteId, isRelayMode: isRelayMode)
    }

    func send(api: WeijiAPIClient, options: AIOptions, profile: InsightsStore,
              requiredSourceNoteId: String? = nil,
              isRelayMode: @escaping @MainActor () -> Bool = { false }) {
        let effectiveRequiredSource = requiredSourceNoteId ?? (isOwnedInDraft(draft) ? rewriteIntent?.sourceNoteId : nil)
        guard validateRequiredSource(effectiveRequiredSource) else { return }
        let styled = useWritingStyle
        guard !(styled && isRelayMode()) else { error = InsightsStore.writingStyleRelayMessage; return }
        guard !sending, !loadingSession, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let typed = draft
        inflightDraft = typed
        if isOwnedInDraft(typed) { rewriteIntent?.promptLocation = .inFlight }
        draft = ""
        composerResetCount += 1
        pendingQuestion = typed
        generation += 1
        let stamp = generation
        sending = true
        sendingWithStyle = styled
        pendingRequiredSourceNoteId = effectiveRequiredSource
        error = nil
        task = Task {
            defer {
                if stamp == generation {
                    finishStreaming()
                    sending = false
                    sendingWithStyle = false
                    pendingRequiredSourceNoteId = nil
                    pendingQuestion = ""
                    streamedText = ""
                    inflightDraft = nil
                }
            }
            do {
                // Either save can start while the chat is waiting for the other.
                while true {
                    try await profile.awaitProfileSave()
                    if styled { try await profile.awaitWritingStyleSave() }
                    if !(profile.hasPendingOrFailedProfileSave || (styled && profile.hasPendingOrFailedWritingStyleSave)) {
                        break
                    }
                }
                try Task.checkCancellation()
                guard stamp == generation else { return }
                guard validateRequiredSource(effectiveRequiredSource) else { return }
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
                rewriteIntent = nil
                if styled { useWritingStyle = false }
                let previousKey = draftContextKey
                let nextKey = "session:\(latest.id)"
                if nextKey != previousKey {
                    // Note drafts rescued during this send still belong to New Chat.
                    if previousKey != "new" { draftsByKey.removeValue(forKey: previousKey) }
                    // The destination session can already have its own unsent draft.
                    let saved = draftsByKey.removeValue(forKey: nextKey) ?? ""
                    draftContextKey = nextKey
                    draft = Self.appendDraft(saved, draft)
                }
                insight = nil
                requestID.clear()
                inflightDraft = nil
            } catch is CancellationError {
                if stamp == generation { restoreInterruptedDraft(inflightDraft) }
            } catch let failure as WeijiAPIError where failure.status == 409 {
                guard stamp == generation else { return }
                if let current = failure.current(ChatSession.self) { updateSession(current) }
                else if let id = session?.id {
                    let latest: ChatResponse? = try? await api.get("/api/ai/sessions/\(id)")
                    guard stamp == generation else { return }
                    if let updated = latest?.session { updateSession(updated) }
                }
                restoreInterruptedDraft(inflightDraft)
                error = failure.message
            } catch {
                if stamp == generation {
                    restoreInterruptedDraft(inflightDraft)
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func waitForIdle() async {
        if let task { await task.value }
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
