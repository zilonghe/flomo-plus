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

private final class SendDispatchGate: @unchecked Sendable {
    private enum State { case pending, dispatched, deferred, cancelled }
    private let lock = NSLock()
    private var state: State = .pending

    func commitIfReady(saveBarrier: InsightsStore.SaveBarrier, includeStyle: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending else { return false }
        // The save snapshot orders dispatch while the gate excludes cancellation.
        if saveBarrier.hasPendingOrFailed(includeStyle: includeStyle) {
            state = .deferred
            return false
        }
        state = .dispatched
        return true
    }

    func cancelIfPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending || state == .deferred else { return false }
        state = .cancelled
        return true
    }

    func deferIfPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending || state == .deferred else { return false }
        state = .deferred
        return true
    }

    var isDispatched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .dispatched
    }

    var wasDeferred: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .deferred
    }
}

@Observable @MainActor
final class AIChatStore {
    static let rewriteNotePrompt = "请基于这条笔记的真实内容，按我的写作风格改写成一段自然流畅的文字，保留原意和事实，不要编造经历。"
    static let deletedRewriteSourceMessage = "原笔记已删除，已取消按风格改写。"
    static let deletedInsightReportMessage = "原洞察报告已删除，已取消基于该报告继续追问。"
    private static let postDeleteDraftKey = "post-delete"

    struct RemovalSlot: Equatable, Sendable {
        let key: String
        var text: String

        static func record(_ text: String, for key: String, replacing previousKey: String? = nil,
                           in slots: inout [RemovalSlot]) {
            let slot = RemovalSlot(key: key, text: text)
            if let index = slots.firstIndex(where: { $0.key == (previousKey ?? key) }) {
                slots[index] = slot
            } else {
                slots.append(slot)
            }
        }
    }

    struct UnconfirmedRemoval: Equatable, Sendable {
        var historyDraft = ""
        var slots: [RemovalSlot] = []
    }

    struct RecoverableDraftSnapshot: Equatable, Sendable {
        let activeContextKey: String
        let activeDraft: String
        let savedDrafts: [String: String]
        let suppressedAutomaticPrompt: Bool
        let requiresDeletedInsightConfirmation: Bool
        var unconfirmedRemovals: [String: UnconfirmedRemoval] = [:]
        var withheldSavedKeys: Set<String> = []
        var withholdsActiveDraft = false
        var preservesHistoryOwnership = false
        var isEmpty: Bool { activeDraft.isEmpty && savedDrafts.isEmpty && unconfirmedRemovals.isEmpty }

        init(activeContextKey: String, activeDraft: String, savedDrafts: [String: String],
             suppressedAutomaticPrompt: Bool, requiresDeletedInsightConfirmation: Bool = false) {
            self.activeContextKey = activeContextKey
            self.activeDraft = activeDraft
            self.savedDrafts = savedDrafts
            self.suppressedAutomaticPrompt = suppressedAutomaticPrompt
            self.requiresDeletedInsightConfirmation = requiresDeletedInsightConfirmation
        }
    }

    private enum AutomaticPromptLocation {
        case none, inDraft, inFlight
    }

    private enum HeldNewChatMergeOrder {
        case appendHeld, prependHeld
    }

    private struct RewriteIntent {
        let sourceNoteId: String
        var introducedByRewrite: Bool
        var promptLocation: AutomaticPromptLocation
        var suppressBackgroundOnEmpty = false
    }

    private struct PendingSourceConflict {
        let sourceNoteId: String
        var draftKey: String { "note:\(sourceNoteId)" }
    }

    private struct ActiveRemoval {
        var token = UUID()
        let sourceNoteId: String?
        var baselineByKey: [String: String] = [:]
        var slots: [RemovalSlot] = []
        var quarantinedHistoryDraft: String?
        var pendingSourceConflict: PendingSourceConflict?
        var uncertainError: Error?
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        func hasFollowUp(_ text: String, for key: String) -> Bool {
            slots.contains { $0.key == key } || baselineByKey[key].map { $0 != text } == true
        }
    }

    var draft = ""
    var recoverableDraftSnapshot: RecoverableDraftSnapshot {
        let committedId = completedSendSessionId
        let destinationKey = committedId.map { "session:\($0)" } ?? draftContextKey
        let boundId = committedId ?? composerRemovalId
        let boundRemoval = boundId.flatMap { activeRemovals[$0] }
        let deletingFollowUp = boundRemoval.map {
            committedId != nil || hasQueuedUserDraft(for: boundId) || $0.hasFollowUp(userDraft, for: draftContextKey)
        } ?? false
        // This key also describes a follow-up whose destination is still undecided.
        let activeKey = deletingFollowUp || isDeletedDraftContext(destinationKey)
            ? Self.postDeleteDraftKey : destinationKey
        var activeDraft = activeUserText()
        var savedDrafts = draftsByKey
        if boundRemoval == nil, activeKey == destinationKey, activeKey != draftContextKey {
            activeDraft = Self.appendDraft(savedDrafts.removeValue(forKey: activeKey) ?? "", activeDraft)
        }
        if !deletingFollowUp, draftContextKey == "new", activeKey == "new" || activeKey == Self.postDeleteDraftKey,
           sending || holdingRescuedForPendingNewChat, let rescued = savedDrafts.removeValue(forKey: "new") {
            activeDraft = mergeHeldNewChatDraft(activeDraft, held: rescued)
        }
        let hasUserDraft = Self.hasDraftText(draft) && !isOwnedInDraft(draft)
        let suppressed = isOwnedInDraft(draft)
            || (!hasUserDraft && sending && inflightDraft.map(isOwnedInFlight) == true)
            || (!Self.hasDraftText(activeDraft)
                && (draftContextKey == Self.postDeleteDraftKey || rewriteIntent?.suppressBackgroundOnEmpty == true))
        savedDrafts = savedDrafts.filter { key, text in
            key != activeKey && (key != draftContextKey || key == "new")
                && key != Self.postDeleteDraftKey && Self.hasDraftText(text)
                && !isDeletedDraftContext(key)
        }
        let needsDeletedInsightConfirmation = requiresDeletedInsightConfirmation
            || (sending && committedId == nil && pendingRequiredInsightId.map { !canReferenceInsight($0) } == true)
        var snapshot = RecoverableDraftSnapshot(activeContextKey: activeKey, activeDraft: activeDraft,
                                                savedDrafts: savedDrafts, suppressedAutomaticPrompt: suppressed,
                                                requiresDeletedInsightConfirmation: needsDeletedInsightConfirmation)
        snapshot.preservesHistoryOwnership = composerSessionId != nil
        captureUnconfirmedRemovals(in: &snapshot, boundId: boundId, destinationKey: destinationKey,
                                   deletingFollowUp: deletingFollowUp)
        return snapshot
    }

    private func captureUnconfirmedRemovals(in snapshot: inout RecoverableDraftSnapshot, boundId: String?,
                                           destinationKey: String, deletingFollowUp: Bool) {
        snapshot.unconfirmedRemovals = unconfirmedRemovals
        for (id, removal) in activeRemovals {
            let key = "session:\(id)"
            var pending = snapshot.unconfirmedRemovals[id] ?? UnconfirmedRemoval()
            let ownsActiveDraft = boundId == id && (destinationKey == key || deletingFollowUp)
            var slots = removal.slots
            if ownsActiveDraft, deletingFollowUp {
                let slotKey = completedSendSessionId == id ? committedDraftKey(for: id, removal: removal) : draftContextKey
                let text = hasQueuedUserDraft(for: id) ? activeUserText() : userDraft
                RemovalSlot.record(text, for: slotKey, replacing: draftContextKey, in: &slots)
            }
            let archived = removal.quarantinedHistoryDraft
                ?? (removal.slots.contains { $0.key == key } ? "" : draftsByKey[key] ?? "")
            pending.historyDraft = Self.appendDraft(pending.historyDraft, archived)
            snapshot.withheldSavedKeys.insert(key)
            if ownsActiveDraft {
                snapshot.withholdsActiveDraft = true
                // A turn from before DELETE stays with the history unless it was still queued.
                let old = deletingFollowUp ? userInFlightDraft : snapshot.activeDraft
                if inflightDeletionFollowUpId != id { pending.historyDraft = Self.appendDraft(pending.historyDraft, old) }
            }
            for slot in slots {
                let earlier = pending.slots.first { $0.key == slot.key }?.text ?? ""
                RemovalSlot.record(Self.appendDraft(earlier, slot.text), for: slot.key, in: &pending.slots)
                snapshot.withheldSavedKeys.insert(slot.key)
            }
            if deletingFollowUp, ownsActiveDraft, draftContextKey != "new" {
                snapshot.withheldSavedKeys.insert(draftContextKey)
            }
            if !pending.historyDraft.isEmpty || !pending.slots.isEmpty { snapshot.unconfirmedRemovals[id] = pending }
        }
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
    @ObservationIgnored private var pendingRequiredInsightId: String?
    @ObservationIgnored private var pendingDispatchGate: SendDispatchGate?
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
    @ObservationIgnored private var deletedSessionIds: Set<String> = []
    @ObservationIgnored private var completedSendSession: ChatSession?
    private var completedSendSessionId: String? { completedSendSession?.id }
    @ObservationIgnored private var activeRemovals: [String: ActiveRemoval] = [:]
    @ObservationIgnored private var unconfirmedRemovals: [String: UnconfirmedRemoval] = [:]
    @ObservationIgnored private var verificationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var deletedInFlightSourceNoteId: String?
    @ObservationIgnored private var deletedInFlightSessionId: String?
    @ObservationIgnored private var requiresDeletedInsightConfirmation = false
    @ObservationIgnored var onSessionRemoved: (@MainActor (String, Bool) -> Void)?
    @ObservationIgnored private var pinsEditedDuringLoad = false
    @ObservationIgnored private var draftContextKey = "new"
    // Inactive drafts and rescues not yet shown in the active New Chat composer.
    @ObservationIgnored private var draftsByKey: [String: String] = [:]
    @ObservationIgnored private var holdingRescuedForPendingNewChat = false
    @ObservationIgnored private var heldNewChatOrder: HeldNewChatMergeOrder = .appendHeld
    @ObservationIgnored private var requestID = ChatRequestID()
    @ObservationIgnored private var inflightDraft: String?
    @ObservationIgnored private var inflightDeletionFollowUpId: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var resetGeneration = 0
    @ObservationIgnored private var pendingDelta = ""
    @ObservationIgnored private var pendingReasoning = ""
    @ObservationIgnored private var reasoningLength = 0
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sessionTask: Task<Bool, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?

    func updateDraftFromUser(_ text: String) {
        if rewriteIntent?.promptLocation == .inDraft { rewriteIntent?.promptLocation = .none }
        let hasText = Self.hasDraftText(text)
        if hasText { rewriteIntent?.suppressBackgroundOnEmpty = false }
        if inflightDeletionFollowUpId != nil, pendingDispatchGate?.cancelIfPending() ?? true {
            stop(commitCompletedSession: false)
        }
        draft = text
        if let id = composerRemovalId {
            recordFollowUp(text, for: draftContextKey, removalId: id)
        }
    }

    private var composerSessionId: String? { session?.id ?? Self.boundSessionId(forContextKey: draftContextKey) }

    private func removalForSource(_ source: String) -> String? {
        activeRemovals.first { $0.value.sourceNoteId == source }?.key
    }

    private var composerRemovalId: String? {
        if let id = composerSessionId, activeRemovals[id] != nil { return id }
        guard session == nil, let sourceNoteId else { return nil }
        return activeRemovals.first {
            $0.value.pendingSourceConflict?.sourceNoteId == sourceNoteId
                && $0.value.pendingSourceConflict?.draftKey == draftContextKey
        }?.key
    }

    private var blockingRemovalId: String? {
        if let id = inflightDeletionFollowUpId, activeRemovals[id] != nil { return id }
        return composerRemovalId
    }

    private func recordFollowUp(_ text: String, for key: String, removalId: String) {
        guard var removal = activeRemovals[removalId] else { return }
        RemovalSlot.record(text, for: key, in: &removal.slots)
        activeRemovals[removalId] = removal
    }

    func setPendingNewChatConfirmation(_ pending: Bool) {
        holdingRescuedForPendingNewChat = pending
        if !pending, draftContextKey == "new", !sending, let held = draftsByKey.removeValue(forKey: "new") {
            draft = mergeHeldNewChatDraft(draft, held: held)
        }
        heldNewChatOrder = .appendHeld
    }

    private func mergeHeldNewChatDraft(_ active: String, held: String) -> String {
        switch heldNewChatOrder {
        case .appendHeld: Self.appendDraft(active, held)
        case .prependHeld: Self.appendDraft(held, active)
        }
    }

    func restoreRecoverableDrafts(_ snapshot: RecoverableDraftSnapshot) {
        requiresDeletedInsightConfirmation = false
        draftsByKey = snapshot.savedDrafts
        unconfirmedRemovals = snapshot.unconfirmedRemovals
        for key in snapshot.withheldSavedKeys { draftsByKey.removeValue(forKey: key) }
        if snapshot.suppressedAutomaticPrompt {
            draftContextKey = Self.postDeleteDraftKey
            draft = ""
            return
        }
        let savedNew = draftsByKey.removeValue(forKey: "new") ?? ""
        draftContextKey = "new"
        let key = snapshot.withholdsActiveDraft ? "new" : snapshot.activeContextKey
        let active = snapshot.withholdsActiveDraft ? "" : snapshot.activeDraft
        let isSourceBoundContext = (key.hasPrefix("insight:") && !isDeletedDraftContext(key))
            || (key.hasPrefix("walk:") && isValidNoteDraftContext(key))
        let isIndependentContext = key != "new" && key != Self.postDeleteDraftKey && !isDeletedDraftContext(key)
        if Self.hasDraftText(active), isSourceBoundContext
            || (isIndependentContext && (snapshot.preservesHistoryOwnership || Self.hasDraftText(savedNew))) {
            draftsByKey[key] = active
            draft = savedNew
        } else {
            draft = Self.appendDraft(savedNew, active)
        }
        if Self.hasDraftText(draft), key == Self.postDeleteDraftKey || snapshot.requiresDeletedInsightConfirmation {
            draftContextKey = Self.postDeleteDraftKey
            if snapshot.requiresDeletedInsightConfirmation {
                requiresDeletedInsightConfirmation = true
                error = Self.deletedInsightReportMessage
            }
        }
    }

    func start(source: String? = nil, pins: [String] = [], insight: InsightReport? = nil,
               useWritingStyle: Bool = false, rewriteSourceNoteId: String? = nil) {
        if let insight, !canReferenceInsight(insight.id) { return }
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
        // Keep unseen rescues out of the composer being discarded by New Chat.
        let unseenRescued = resettingNew ? draftsByKey.removeValue(forKey: "new") : nil
        setPendingNewChatConfirmation(false)
        // A confirmed switch saves the follow-up in the context the user is leaving.
        stop(commitCompletedSession: false)
        // An abandoned automatic prompt must not come back as an ordinary saved draft.
        if isOwnedInDraft(draft) { draft = "" }
        rewriteIntent = nil
        requiresDeletedInsightConfirmation = false
        if nextKey != draftContextKey {
            // Stop can restore the interrupted question before the old context is saved.
            if draftContextKey == Self.postDeleteDraftKey || isDeletedDraftContext(draftContextKey) {
                draftsByKey.removeValue(forKey: draftContextKey)
                if Self.hasDraftText(draft) {
                    draftsByKey["new"] = Self.appendDraft(draftsByKey["new"] ?? "", draft)
                }
            } else {
                parkLeavingDraft()
            }
            draftContextKey = nextKey
            draft = takeDraft(for: nextKey) ?? ""
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

    private func parkLeavingDraft() {
        if let id = composerRemovalId ?? removalWithSlot(for: draftContextKey), let removal = activeRemovals[id] {
            if removal.hasFollowUp(draft, for: draftContextKey) {
                recordFollowUp(draft, for: draftContextKey, removalId: id)
            }
            if removal.quarantinedHistoryDraft != nil && draftContextKey == "session:\(id)" { return }
        }
        draftsByKey[draftContextKey] = Self.hasDraftText(draft) ? draft : nil
    }

    private func removalWithSlot(for key: String) -> String? {
        activeRemovals.first { $0.value.slots.contains { $0.key == key } }?.key
    }

    private func takeDraft(for key: String) -> String? {
        let saved = draftsByKey.removeValue(forKey: key)
        let id = Self.boundSessionId(forContextKey: key) ?? removalWithSlot(for: key)
        guard let id, let removal = activeRemovals[id] else { return saved }
        if let slot = removal.slots.first(where: { $0.key == key }) { return slot.text }
        if removal.baselineByKey[key] == nil { activeRemovals[id]?.baselineByKey[key] = saved ?? "" }
        return saved
    }

    func reset() {
        resetGeneration += 1
        validNoteIds = nil
        deletedInsightIds = []
        pinsEditedDuringLoad = false
        start()
        deletedSessionIds = []
        let removals = activeRemovals
        activeRemovals.removeAll()
        for removal in removals.values { resumeRemovalWaiters(removal.waiters) }
        for task in verificationTasks.values { task.cancel() }
        verificationTasks.removeAll()
        unconfirmedRemovals = [:]
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
        let shouldCancelSend = sending && pendingRequiredInsightId == id
            && (pendingDispatchGate?.cancelIfPending() ?? true)
        let wasActiveInsight = Self.boundInsightId(forContextKey: draftContextKey) == id || insight?.id == id
        let newlyDeleted = deletedInsightIds.insert(id).inserted
        if insight?.id == id { insight = nil }
        if shouldCancelSend {
            cancelDeletedInsightSend(id)
        } else if newlyDeleted, !sending, wasActiveInsight, Self.hasDraftText(draft) {
            requiresDeletedInsightConfirmation = true
            error = Self.deletedInsightReportMessage
        }
        rescueOrphanedDrafts()
    }

    func canReferenceInsight(_ id: String) -> Bool { !deletedInsightIds.contains(id) }

    func needsInsightVerification(_ id: String) -> Bool {
        guard canReferenceInsight(id) else { return false }
        if Self.boundInsightId(forContextKey: draftContextKey) == id, Self.hasDraftText(activeUserText()) {
            return true
        }
        return draftsByKey["insight:\(id)"].map(Self.hasDraftText) ?? false
    }

    var pendingInsightDraftIds: [String] {
        var ids = Set(draftsByKey.keys.compactMap(Self.boundInsightId(forContextKey:)))
        if let id = Self.boundInsightId(forContextKey: draftContextKey) { ids.insert(id) }
        return ids.filter { needsInsightVerification($0) }.sorted()
    }

    private func rescueOrphanedDrafts() {
        let orphanedKeys = draftsByKey.keys.filter { isDeletedDraftContext($0) }.sorted()
        for key in orphanedKeys {
            guard let rescued = draftsByKey.removeValue(forKey: key), Self.hasDraftText(rescued) else { continue }
            for id in activeRemovals.keys {
                activeRemovals[id]?.slots.removeAll { $0.key == key }
            }
            rescueToNewChat(rescued)
        }
    }

    private func rescueToNewChat(_ text: String) {
        guard Self.hasDraftText(text) else { return }
        if draftContextKey == "new" && !sending && !holdingRescuedForPendingNewChat {
            draft = Self.appendDraft(draft, text)
        } else {
            draftsByKey["new"] = Self.appendDraft(draftsByKey["new"] ?? "", text)
        }
    }

    private func isOwnedInDraft(_ text: String) -> Bool {
        rewriteIntent?.promptLocation == .inDraft && text == Self.rewriteNotePrompt
    }

    private func isOwnedInFlight(_ text: String) -> Bool {
        rewriteIntent?.promptLocation == .inFlight && text == Self.rewriteNotePrompt
    }

    private var userDraft: String { isOwnedInDraft(draft) ? "" : draft }
    private var userInFlightDraft: String { inflightDraft.flatMap { isOwnedInFlight($0) ? nil : $0 } ?? "" }

    private func activeUserText() -> String { Self.appendDraft(sending ? userInFlightDraft : "", userDraft) }

    private func hasQueuedUserDraft(for id: String?) -> Bool {
        sending && inflightDeletionFollowUpId == id && Self.hasDraftText(userInFlightDraft)
    }

    private func restoreInterruptedDraft(_ unsent: String?, preserveWithFollowUp: Bool = false,
                                         removalFollowUpId: String? = nil) {
        let unsentIsAuto = unsent.map(isOwnedInFlight) ?? false
        defer {
            if let removalFollowUpId, let unsent, !unsentIsAuto, Self.hasDraftText(unsent) {
                recordFollowUp(userDraft, for: draftContextKey, removalId: removalFollowUpId)
            }
        }
        let hasHeldRescue = draftContextKey == "new" && holdingRescuedForPendingNewChat && draftsByKey["new"] != nil
        let rescued = draftContextKey == "new" && !holdingRescuedForPendingNewChat
            ? draftsByKey.removeValue(forKey: "new") : nil
        if !Self.hasDraftText(draft), rescued == nil, let unsent {
            draft = unsent
            if unsentIsAuto {
                rewriteIntent?.promptLocation = .inDraft
                rewriteIntent?.suppressBackgroundOnEmpty = true
            }
            return
        }
        if rescued != nil || hasHeldRescue || preserveWithFollowUp || removalFollowUpId != nil
            || isDeletedDraftContext(draftContextKey) {
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
        stop(commitCompletedSession: false)
        if let id = composerRemovalId { activeRemovals[id]?.slots.removeAll { $0.key == draftContextKey } }
        draftsByKey.removeValue(forKey: "note:\(intent.sourceNoteId)")
        rewriteIntent = nil
        if intent.introducedByRewrite {
            if draftContextKey.hasPrefix("session:") { draftsByKey.removeValue(forKey: draftContextKey) }
            session = nil
            sourceNoteId = nil
            useWritingStyle = false
        }
        if Self.hasDraftText(preserved) {
            draftContextKey = "new"
            if holdingRescuedForPendingNewChat {
                draft = preserved
                heldNewChatOrder = .prependHeld
            } else {
                let savedNew = draftsByKey.removeValue(forKey: "new") ?? ""
                draft = Self.appendDraft(savedNew, preserved)
            }
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

    private func validateRequiredInsight(_ required: String?) -> Bool {
        guard let required, !canReferenceInsight(required) || insight?.id != required else { return true }
        cancelDeletedInsightSend(required)
        return false
    }

    private func cancelDeletedInsightSend(_ id: String) {
        if sending {
            stop()
        } else if let unsent = inflightDraft {
            restoreInterruptedDraft(unsent)
        }
        if insight?.id == id { insight = nil }
        error = Self.deletedInsightReportMessage
    }

    func canReference(_ id: String) -> Bool { isValidNote(id) }

    private static func boundNoteId(forContextKey key: String) -> String? {
        guard key.hasPrefix("note:") || key.hasPrefix("walk:") else { return nil }
        return String(key.dropFirst(5))
    }

    private static func boundInsightId(forContextKey key: String) -> String? {
        key.hasPrefix("insight:") ? String(key.dropFirst(8)) : nil
    }

    private static func boundSessionId(forContextKey key: String) -> String? {
        key.hasPrefix("session:") ? String(key.dropFirst(8)) : nil
    }

    private func isValidNoteDraftContext(_ key: String) -> Bool {
        guard let id = Self.boundNoteId(forContextKey: key) else { return false }
        return isValidNote(id)
    }

    private func isDeletedNoteDraftContext(_ key: String) -> Bool {
        Self.boundNoteId(forContextKey: key).map { !isValidNote($0) } ?? false
    }

    private func isDeletedDraftContext(_ key: String) -> Bool {
        isDeletedNoteDraftContext(key)
            || (Self.boundInsightId(forContextKey: key).map { !canReferenceInsight($0) } ?? false)
            || (Self.boundSessionId(forContextKey: key).map { deletedSessionIds.contains($0) } ?? false)
    }

    private func isValidNote(_ id: String) -> Bool { validNoteIds?.contains(id) ?? true }

    private func validSource(_ id: String?) -> String? { id.flatMap { isValidNote($0) ? $0 : nil } }

    func togglePin(_ id: String) {
        pinsEditedDuringLoad = true
        if pins.contains(id) { pins.removeAll { $0 == id } }
        else if isValidNote(id) && pins.count < 10 { pins.append(id) }
    }

    func stop(preserveInFlightWithDraft: Bool = false, commitCompletedSession: Bool = true) {
        _ = pendingDispatchGate?.cancelIfPending()
        let wasDispatched = pendingDispatchGate?.isDispatched ?? false
        let requiredInsightId = pendingRequiredInsightId
        let wasSending = sending
        let unsent = inflightDraft
        let removalFollowUpId = inflightDeletionFollowUpId
        let deletedHistory = deletedInFlightSessionId.flatMap { draftContextKey == "session:\($0)" ? $0 : nil }
        generation += 1
        task?.cancel()
        sessionTask?.cancel()
        loadingSession = false
        if commitCompletedSession, let completed = completedSendSession {
            applyCommittedSession(completed, styled: sendingWithStyle)
            if sending { finishSend() }
            return
        }
        finishSend()
        if wasSending {
            restoreInterruptedDraft(unsent, preserveWithFollowUp: preserveInFlightWithDraft,
                                    removalFollowUpId: removalFollowUpId)
            if let deletedHistory { moveDraftFromDeletedSession(deletedHistory, styled: true) }
            if wasDispatched, let requiredInsightId, !canReferenceInsight(requiredInsightId), Self.hasDraftText(draft) {
                requiresDeletedInsightConfirmation = true
                error = Self.deletedInsightReportMessage
            }
        }
    }

    func restorePendingSessionDraftIfPresent() -> Bool {
        guard let id = session?.id else { return false }
        let key = "session:\(id)"
        guard let pending = takeDraft(for: key), Self.hasDraftText(pending) else { return false }
        draftContextKey = key
        draft = pending
        return true
    }

    @discardableResult
    func loadSource(_ source: String, api: WeijiAPIClient) -> Task<Bool, Never> {
        let path = WeijiAPIClient.withQuery("/api/ai/sessions", [URLQueryItem(name: "sourceNoteId", value: source)])
        return load(path, api: api)
    }

    @discardableResult
    func select(_ id: String, api: WeijiAPIClient) -> Task<Void, Never> {
        guard !deletedSessionIds.contains(id) else { return Task {} }
        switchDraftContext(to: "session:\(id)")
        let loadTask = load("/api/ai/sessions/\(id)", api: api, detailId: id)
        return Task {
            await withTaskCancellationHandler { _ = await loadTask.value } onCancel: { loadTask.cancel() }
        }
    }

    private func load(_ path: String, api: WeijiAPIClient, detailId: String? = nil) -> Task<Bool, Never> {
        generation += 1
        let stamp = generation
        let baseline = draft
        sessionTask?.cancel()
        loadingSession = true
        let currentTask = Task {
            defer { if stamp == generation { loadingSession = false } }
            do {
                try Task.checkCancellation()
                let response: ChatResponse = try await api.get(path, expecting: detailId == nil ? nil : 200)
                guard stamp == generation, !Task.isCancelled else { return false }
                if let detailId {
                    guard response.session?.id == detailId else { throw WeijiAPIError.interrupted }
                    if activeRemovals[detailId]?.uncertainError != nil { finishRemoval(detailId, deleted: false) }
                    resolveUnconfirmedRemoval(detailId, exists: true)
                }
                if let loaded = response.session, deletedSessionIds.contains(loaded.id) { return false }
                session = response.session
                if let id = response.session?.id, var removal = activeRemovals[id] {
                    if removal.baselineByKey[draftContextKey] == nil { removal.baselineByKey[draftContextKey] = baseline }
                    if removal.hasFollowUp(userDraft, for: draftContextKey) {
                        RemovalSlot.record(userDraft, for: draftContextKey, in: &removal.slots)
                    }
                    activeRemovals[id] = removal
                }
                if let rawSource = response.session?.sourceNoteId {
                    let source = validSource(rawSource)
                    if detailId != nil {
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
                if stamp == generation, !Task.isCancelled {
                    if let detailId, (error as? WeijiAPIError)?.status == 404 {
                        if activeRemovals[detailId]?.uncertainError != nil {
                            finishRemoval(detailId, deleted: true)
                        } else {
                            resolveUnconfirmedRemoval(detailId, exists: false)
                        }
                    }
                    self.error = error.localizedDescription
                }
                return false
            }
        }
        sessionTask = currentTask
        return currentTask
    }

    func refreshSessions(api: WeijiAPIClient, more: Bool = false) {
        scheduleUnconfirmedRemovalVerification(api: api)
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
                let visible = page.sessions.filter { !deletedSessionIds.contains($0.id) }
                sessions = more ? sessions + visible.filter { item in !sessions.contains { $0.id == item.id } } : visible
                cursor = page.nextCursor
            } catch is CancellationError {
            } catch {
                if stamp == listGeneration { self.error = error.localizedDescription }
            }
        }
    }

    func remove(_ id: String, api: WeijiAPIClient) async {
        guard activeRemovals[id] == nil || activeRemovals[id]?.uncertainError != nil else { return }
        let accountStamp = resetGeneration
        let knownSource = (session?.id == id ? session?.sourceNoteId : nil)
            ?? (completedSendSessionId == id ? completedSendSession?.sourceNoteId : nil)
            ?? sessions.first(where: { $0.id == id })?.sourceNoteId
        var removal = activeRemovals[id] ?? ActiveRemoval(sourceNoteId: knownSource)
        removal.token = UUID()
        removal.uncertainError = nil
        if (composerSessionId == id || completedSendSessionId == id), removal.baselineByKey[draftContextKey] == nil {
            removal.baselineByKey[draftContextKey] = userDraft
        }
        let token = removal.token
        activeRemovals[id] = removal
        if sending, composerRemovalId == id {
            if pendingDispatchGate?.deferIfPending() ?? true { inflightDeletionFollowUpId = id }
            else if inflightDeletionFollowUpId == id { inflightDeletionFollowUpId = nil }
        }
        do {
            let _: DeletedResponse = try await api.delete("/api/ai/sessions/\(id)", onAuthenticationRejected: { [weak self] in
                await self?.markRemovalRefused(id, token: token, accountStamp: accountStamp)
            })
            guard accountStamp == resetGeneration, activeRemovals[id]?.token == token else { return }
            finishRemoval(id, deleted: true)
        } catch let failure as WeijiAPIError where failure.status == 404 {
            guard accountStamp == resetGeneration, activeRemovals[id]?.token == token else { return }
            finishRemoval(id, deleted: true)
        } catch {
            guard accountStamp == resetGeneration, var active = activeRemovals[id], active.token == token else { return }
            if Task.isCancelled || error is CancellationError {
                if inflightDeletionFollowUpId == id { stop(commitCompletedSession: false) }
            } else {
                let status = (error as? WeijiAPIError)?.status ?? 0
                if sending, inflightDeletionFollowUpId == id, status == 0 || status >= 500 {
                    // A lost receipt cannot tell a waiting send whether its target still exists.
                    let waiters = active.waiters
                    active.waiters.removeAll()
                    active.uncertainError = error
                    activeRemovals[id] = active
                    resumeRemovalWaiters(waiters)
                    return
                }
                self.error = error.localizedDescription
            }
            finishRemoval(id, deleted: false)
        }
    }

    private func applySessionRemoval(_ id: String, removal: ActiveRemoval?) {
        let removedSource = (session?.id == id ? session?.sourceNoteId : nil)
            ?? sessions.first(where: { $0.id == id })?.sourceNoteId ?? removal?.sourceNoteId
        let deletedKey = "session:\(id)"
        let conflict = removal?.pendingSourceConflict
        let activeConflict = conflict?.draftKey == draftContextKey && (composerSessionId == nil || composerSessionId == id)
        let completed = completedSendSessionId == id
        let removedActive = composerSessionId == id || completed || activeConflict
        let sendingFollowUp = hasQueuedUserDraft(for: id)
        let preserveFollowUp = sendingFollowUp || completed || activeConflict
            || removal?.hasFollowUp(userDraft, for: draftContextKey) == true
            || (removal == nil && Self.hasDraftText(userDraft))
        let awaitingHistoryPost = draftContextKey == deletedKey && !completed && pendingDispatchGate?.isDispatched == true
        var slots = removal?.slots ?? []
        if removedActive, preserveFollowUp {
            RemovalSlot.record(sendingFollowUp ? activeUserText() : userDraft, for: draftContextKey, in: &slots)
        }
        let pending = unconfirmedRemovals.removeValue(forKey: id)
        for slot in slots where slot.key != "new" { draftsByKey.removeValue(forKey: slot.key) }
        deletedSessionIds.insert(id)
        sessions.removeAll { $0.id == id }
        draftsByKey.removeValue(forKey: deletedKey)

        if awaitingHistoryPost {
            // Keep watching a pre-DELETE POST for DONE or an explicit rejection.
            slots.removeAll { $0.key == deletedKey }
            deletedInFlightSessionId = id
            session = nil
            if !preserveFollowUp {
                draft = ""
                moveDraftFromDeletedSession(id, styled: true)
            }
        } else if removedActive, preserveFollowUp {
            inflightDraft = nil
            draft = ""
            stop(commitCompletedSession: false)
            session = nil
            error = nil
            moveDraftFromDeletedSession(id, styled: true)
        } else if removedActive {
            if draftContextKey == deletedKey {
                draft = ""
                inflightDraft = nil
            }
            start()
        } else if sending, let removedSource, !removedSource.isEmpty, sourceNoteId == removedSource {
            deletedInFlightSourceNoteId = removedSource
            deletedInFlightSessionId = id
        }
        for slot in pending?.slots ?? [] { rescueToNewChat(slot.text) }
        for slot in slots { rescueToNewChat(slot.text) }
        onSessionRemoved?(id, removedActive)
    }

    private func finishRemoval(_ id: String, deleted: Bool) {
        guard let removal = activeRemovals.removeValue(forKey: id) else { return }
        defer { resumeRemovalWaiters(removal.waiters) }
        if deleted {
            applySessionRemoval(id, removal: removal)
            return
        }
        let key = "session:\(id)"
        if let quarantined = removal.quarantinedHistoryDraft {
            if draftContextKey == key {
                draft = Self.appendDraft(quarantined, draft)
            } else {
                let followUp = removal.slots.first { $0.key == key }?.text ?? ""
                draftsByKey[key] = Self.appendDraft(quarantined, followUp)
            }
        }
    }

    private func resumeRemovalWaiters(_ waiters: [UUID: CheckedContinuation<Void, Never>]) {
        for waiter in waiters.values { waiter.resume() }
    }

    private func waitForRemoval(_ id: String) async {
        let waiter = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, let removal = activeRemovals[id], removal.uncertainError == nil else {
                    continuation.resume()
                    return
                }
                activeRemovals[id]?.waiters[waiter] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.activeRemovals[id]?.waiters.removeValue(forKey: waiter)?.resume() }
        }
    }

    private func markRemovalRefused(_ id: String, token: UUID, accountStamp: Int) {
        guard accountStamp == resetGeneration, activeRemovals[id]?.token == token else { return }
        if inflightDeletionFollowUpId == id || completedSendSessionId == id { stop() }
        finishRemoval(id, deleted: false)
    }

    private func verifySession(_ id: String, api: WeijiAPIClient) async throws -> ChatSession? {
        do {
            let response: ChatResponse = try await api.get("/api/ai/sessions/\(id)", expecting: 200)
            guard let detail = response.session, detail.id == id else { throw WeijiAPIError.interrupted }
            return detail
        } catch let failure as WeijiAPIError where failure.status == 404 {
            return nil
        }
    }

    func scheduleUnconfirmedRemovalVerification(api: WeijiAPIClient) {
        let stamp = resetGeneration
        for id in unconfirmedRemovals.keys where verificationTasks[id] == nil {
            verificationTasks[id] = Task {
                defer { if stamp == resetGeneration { verificationTasks[id] = nil } }
                do {
                    try Task.checkCancellation()
                    let detail = try await verifySession(id, api: api)
                    guard stamp == resetGeneration, !Task.isCancelled else { return }
                    resolveUnconfirmedRemoval(id, exists: detail != nil)
                } catch {
                    // Leaving the snapshot pending lets the next sync retry this ID.
                }
            }
        }
    }

    func waitForUnconfirmedVerifications() async {
        for task in Array(verificationTasks.values) { await task.value }
    }

    private func resolveUnconfirmedRemoval(_ id: String, exists: Bool) {
        guard unconfirmedRemovals[id] != nil else { return }
        if !exists {
            if activeRemovals[id] != nil { finishRemoval(id, deleted: true) }
            else { applySessionRemoval(id, removal: nil) }
        } else {
            guard activeRemovals[id] == nil, let removal = unconfirmedRemovals.removeValue(forKey: id) else { return }
            restoreUnconfirmedDraft(removal.historyDraft, to: "session:\(id)")
            for slot in removal.slots { restoreUnconfirmedDraft(slot.text, to: slot.key) }
        }
    }

    private func restoreUnconfirmedDraft(_ text: String, to key: String) {
        guard Self.hasDraftText(text) else { return }
        if isDeletedDraftContext(key) {
            rescueToNewChat(text)
        } else if key == draftContextKey, !sending {
            draft = Self.appendDraft(draft, text)
        } else {
            draftsByKey[key] = Self.appendDraft(draftsByKey[key] ?? "", text)
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
        rewriteIntent = RewriteIntent(sourceNoteId: sourceNoteId, introducedByRewrite: true, promptLocation: .inDraft,
                                      suppressBackgroundOnEmpty: true)
        draft = Self.rewriteNotePrompt
        send(api: api, options: options, profile: profile, requiredSourceNoteId: sourceNoteId, isRelayMode: isRelayMode)
    }

    func send(api: WeijiAPIClient, options: AIOptions, profile: InsightsStore,
              requiredSourceNoteId: String? = nil,
              isRelayMode: @escaping @MainActor () -> Bool = { false }) {
        let effectiveRequiredSource = requiredSourceNoteId ?? (isOwnedInDraft(draft) ? rewriteIntent?.sourceNoteId : nil)
        guard validateRequiredSource(effectiveRequiredSource) else { return }
        let requiredInsightId = session == nil ? insight?.id : nil
        guard validateRequiredInsight(requiredInsightId) else { return }
        let styled = useWritingStyle
        guard !(styled && isRelayMode()) else { error = InsightsStore.writingStyleRelayMessage; return }
        guard !sending, !loadingSession, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if requiresDeletedInsightConfirmation {
            requiresDeletedInsightConfirmation = false
            error = Self.deletedInsightReportMessage
            return
        }
        inflightDeletionFollowUpId = composerRemovalId
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
        pendingRequiredInsightId = requiredInsightId
        completedSendSession = nil
        deletedInFlightSourceNoteId = nil
        deletedInFlightSessionId = nil
        error = nil
        task = Task {
            defer { if stamp == generation { finishSend() } }
            var sentSourceNoteId: String?
            var sentSessionId: String?
            do {
                let response: ChatResponse
                let saveBarrier = profile.saveBarrier
                while true {
                    if let id = blockingRemovalId, let removal = activeRemovals[id] {
                        inflightDeletionFollowUpId = id
                        if removal.uncertainError != nil {
                            let detail = try await verifySession(id, api: api)
                            try Task.checkCancellation()
                            guard stamp == generation, !deletedSessionIds.contains(id) else { return }
                            guard activeRemovals[id]?.token == removal.token else { continue }
                            finishRemoval(id, deleted: detail == nil)
                            guard let detail else { return }
                            // Pin a verified source retry to H so a later remote delete cannot create a new session.
                            updateSession(detail)
                            resolveUnconfirmedRemoval(id, exists: true)
                        } else {
                            await waitForRemoval(id)
                            try Task.checkCancellation()
                            guard stamp == generation, !deletedSessionIds.contains(id) else { return }
                        }
                        continue
                    }
                    // Either save can start while the chat is waiting for the other.
                    repeat {
                        try await profile.awaitProfileSave()
                        if styled { try await profile.awaitWritingStyleSave() }
                    } while saveBarrier.hasPendingOrFailed(includeStyle: styled)
                    try Task.checkCancellation()
                    guard stamp == generation else { return }
                    if blockingRemovalId != nil { continue }
                    guard validateRequiredSource(effectiveRequiredSource) else { return }
                    guard validateRequiredInsight(requiredInsightId) else { return }
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
                    // The server only resolves a session by source when no session ID was sent.
                    sentSourceNoteId = signature.sessionId == nil ? signature.sourceNoteId : nil
                    sentSessionId = signature.sessionId
                    var fields = options.fields
                    fields["message"] = .string(message)
                    fields["referencedNoteIds"] = .strings(signature.referencedNoteIds)
                    fields["useProfile"] = .bool(signature.useProfile)
                    if styled { fields["useWritingStyle"] = .bool(true) }
                    fields["clientRequestId"] = .string(requestID.resolve(signature))
                    if let id = signature.sessionId { fields["sessionId"] = .string(id) }
                    if let id = signature.sourceNoteId { fields["sourceNoteId"] = .string(id) }
                    if let version = signature.expectedVersion { fields["expectedVersion"] = .number(version) }

                    let gate = SendDispatchGate()
                    pendingDispatchGate = gate
                    do {
                        response = try await api.stream("/api/ai/chat", fields, beforeDispatch: {
                            gate.commitIfReady(saveBarrier: saveBarrier, includeStyle: styled)
                        }) { [weak self] frame in
                            await self?.receive(frame, generation: stamp)
                        }
                        break
                    } catch is CancellationError where stamp == generation && !Task.isCancelled && gate.wasDeferred {
                        pendingDispatchGate = nil
                    }
                }
                guard stamp == generation, !Task.isCancelled else { return }
                guard let latest = response.session else { throw WeijiAPIError.interrupted }
                applyCommittedSession(latest, styled: styled)
            } catch {
                guard stamp == generation else { return }
                if let completed = completedSendSession {
                    applyCommittedSession(completed, styled: styled)
                    return
                }
                if error is CancellationError {
                    restoreInterruptedDraft(inflightDraft, removalFollowUpId: inflightDeletionFollowUpId)
                    return
                }
                guard let failure = error as? WeijiAPIError, pendingDispatchGate?.isDispatched == true else {
                    restoreFailedSend(error.localizedDescription, requiredInsightId: requiredInsightId)
                    return
                }
                if let id = deletedInFlightSessionId, sentSessionId == id {
                    if failure.status != 404 { inflightDraft = nil }
                    else if draftContextKey == "new" {
                        draft = Self.appendDraft(draft, userInFlightDraft)
                        inflightDraft = nil
                    }
                    detachDeletedConflictToNew(id, styled: styled, message: failure.message,
                                               requiredInsightId: requiredInsightId, preserveInFlight: true)
                    return
                }
                if failure.status == 404, let id = sentSessionId, draftContextKey == "session:\(id)", activeRemovals[id] != nil {
                    restoreInterruptedDraft(inflightDraft, preserveWithFollowUp: true)
                    recordFollowUp(userDraft, for: draftContextKey, removalId: id)
                    setFailedSendError(failure.message, requiredInsightId: requiredInsightId)
                    return
                }
                guard failure.status == 409 else {
                    restoreFailedSend(failure.localizedDescription, requiredInsightId: requiredInsightId)
                    return
                }
                let current = failure.current(ChatSession.self)
                let deletedId = [current?.id, session?.id].compactMap { $0 }.first { deletedSessionIds.contains($0) }
                    ?? (current == nil && sentSourceNoteId != nil && deletedInFlightSourceNoteId == sentSourceNoteId
                        ? deletedInFlightSessionId : nil)
                if let deletedId {
                    detachDeletedConflictToNew(deletedId, styled: styled, message: failure.message,
                                               requiredInsightId: requiredInsightId)
                    return
                }
                if let current {
                    updateSession(current)
                } else if let id = session?.id {
                    let latest: ChatResponse? = try? await api.get("/api/ai/sessions/\(id)")
                    guard stamp == generation else { return }
                    if deletedSessionIds.contains(id) {
                        inflightDraft = nil
                        detachDeletedConflictToNew(id, styled: styled, message: failure.message, requiredInsightId: requiredInsightId)
                        return
                    }
                    if let updated = latest?.session, !deletedSessionIds.contains(updated.id) { updateSession(updated) }
                }
                restoreFailedSend(failure.message, requiredInsightId: requiredInsightId)
                if let current, sentSessionId == nil {
                    recordFollowUp(userDraft, for: draftContextKey, removalId: current.id)
                } else if current == nil, session == nil, let source = sentSourceNoteId, let id = removalForSource(source) {
                    let conflict = PendingSourceConflict(sourceNoteId: source)
                    activeRemovals[id]?.pendingSourceConflict = conflict
                    if draftContextKey == conflict.draftKey { recordFollowUp(userDraft, for: draftContextKey, removalId: id) }
                }
            }
        }
    }

    private func committedDraftKey(for id: String, removal: ActiveRemoval) -> String {
        let key = "session:\(id)"
        // Both entrances may already hold independent edits.
        if draftContextKey.hasPrefix("note:"), removal.slots.contains(where: { $0.key == key }) {
            return draftContextKey
        }
        return key
    }

    private func applyCommittedSession(_ latest: ChatSession, styled: Bool) {
        guard !deletedSessionIds.contains(latest.id) else {
            settleDeletedInFlightSend(latest.id)
            return
        }
        updateSession(latest)
        if let index = sessions.firstIndex(where: { $0.id == latest.id }) {
            sessions[index] = latest
        } else {
            sessions.insert(latest, at: 0)
        }
        pendingQuestion = ""
        streamedText = ""
        error = nil
        rewriteIntent = nil
        if styled { useWritingStyle = false }
        let removal = activeRemovals[latest.id]
        let nextKey = removal.map { committedDraftKey(for: latest.id, removal: $0) } ?? "session:\(latest.id)"
        if nextKey != draftContextKey {
            // Keep any background New Chat draft and merge only drafts for this session.
            if draftContextKey != "new" { draftsByKey.removeValue(forKey: draftContextKey) }
            if var removal {
                if let old = draftsByKey.removeValue(forKey: nextKey) {
                    removal.quarantinedHistoryDraft = old
                }
                if Self.hasDraftText(draft) || removal.slots.contains(where: { $0.key == draftContextKey }) {
                    RemovalSlot.record(draft, for: nextKey, replacing: draftContextKey, in: &removal.slots)
                }
                removal.baselineByKey[nextKey] = ""
                activeRemovals[latest.id] = removal
            } else {
                draft = Self.appendDraft(draftsByKey.removeValue(forKey: nextKey) ?? "", draft)
            }
            draftContextKey = nextKey
        }
        insight = nil
        requestID.clear()
    }

    private func finishSend() {
        finishStreaming()
        pendingQuestion = ""
        streamedText = ""
        inflightDraft = nil
        inflightDeletionFollowUpId = nil
        sending = false
        sendingWithStyle = false
        pendingRequiredSourceNoteId = nil
        pendingRequiredInsightId = nil
        pendingDispatchGate = nil
        completedSendSession = nil
        deletedInFlightSourceNoteId = nil
        deletedInFlightSessionId = nil
    }

    private func settleDeletedInFlightSend(_ id: String) {
        let styled = sendingWithStyle
        // The server already committed the question, so there is no interrupted draft to restore.
        _ = pendingDispatchGate?.cancelIfPending()
        generation += 1
        task?.cancel()
        finishSend()
        if session?.id == id { session = nil }
        moveDraftFromDeletedSession(id, styled: styled)
        onSessionRemoved?(id, true)
    }

    private func detachDeletedConflictToNew(_ id: String, styled: Bool, message: String, requiredInsightId: String?,
                                            preserveInFlight: Bool = false) {
        restoreInterruptedDraft(inflightDraft, preserveWithFollowUp: preserveInFlight, removalFollowUpId: inflightDeletionFollowUpId)
        session = nil
        moveDraftFromDeletedSession(id, styled: styled)
        setFailedSendError(message, requiredInsightId: requiredInsightId)
        if requiresDeletedInsightConfirmation { draftContextKey = Self.postDeleteDraftKey }
        onSessionRemoved?(id, true)
    }

    private func moveDraftFromDeletedSession(_ id: String, styled: Bool) {
        sourceNoteId = nil
        pins = []
        pinsEditedDuringLoad = false
        // An automatic rewrite prompt has no meaning once it loses its source.
        if isOwnedInDraft(draft) { draft = "" }
        rewriteIntent = nil
        if styled { useWritingStyle = false }
        insight = nil
        requestID.clear()
        draftsByKey.removeValue(forKey: "session:\(id)")
        if draftContextKey != "new" {
            draftsByKey.removeValue(forKey: draftContextKey)
            let savedNew = draftsByKey.removeValue(forKey: "new") ?? ""
            draftContextKey = "new"
            draft = Self.appendDraft(savedNew, draft)
        } else if let rescued = draftsByKey.removeValue(forKey: "new") {
            draft = mergeHeldNewChatDraft(draft, held: rescued)
        }
    }

    private func restoreFailedSend(_ message: String, requiredInsightId: String?) {
        restoreInterruptedDraft(inflightDraft, removalFollowUpId: inflightDeletionFollowUpId)
        setFailedSendError(message, requiredInsightId: requiredInsightId)
    }

    private func setFailedSendError(_ message: String, requiredInsightId: String?) {
        if let requiredInsightId, !canReferenceInsight(requiredInsightId), Self.hasDraftText(draft) {
            requiresDeletedInsightConfirmation = true
            error = Self.deletedInsightReportMessage
        } else {
            error = message
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
            if let latest = (try? decoder.decode(ChatResponse.self, from: data))?.session {
                completedSendSession = latest
                // Only the new composer text is unsent once the server commits this turn.
                inflightDeletionFollowUpId = nil
                inflightDraft = nil
                if deletedSessionIds.contains(latest.id) {
                    settleDeletedInFlightSend(latest.id)
                    return
                }
            }
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
