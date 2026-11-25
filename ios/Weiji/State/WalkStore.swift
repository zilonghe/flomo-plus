import Foundation
import Observation

enum WalkRelationKind: Equatable, Sendable {
    case memo, sameBook(String), crossBook(String)

    static func classify(focusBook: String?, candidateBook: String?) -> Self {
        guard let title = candidateBook?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return .memo }
        let focus = focusBook?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return focus == title.lowercased() ? .sameBook(title) : .crossBook(title)
    }

    var badgeText: String {
        switch self {
        case .memo: "随记呼应"
        case .sameBook: "同书"
        case .crossBook(let title): "跨书 · \(title)"
        }
    }
}

@Observable @MainActor
final class WalkStore {
    private(set) var result: RelatedNotes?
    private(set) var loading = false
    private(set) var error: String?
    private var history: [RelatedNotes] = []
    var previousFocus: RelatedNoteSummary? { history.last?.focus }
    @ObservationIgnored private var validNoteIds: Set<String>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func reset() {
        generation += 1
        task?.cancel()
        result = nil
        history = []
        validNoteIds = nil
        loading = false
        error = nil
    }

    func previous() {
        guard let previous = history.popLast() else { return }
        generation += 1
        task?.cancel()
        loading = false
        error = nil
        result = previous
    }

    func syncValidIds(_ ids: Set<String>) {
        validNoteIds = ids
        history = history.compactMap(validResult)
        if let result { self.result = validResult(result) ?? history.popLast() }
    }

    private func validResult(_ value: RelatedNotes) -> RelatedNotes? {
        guard let validNoteIds else { return value }
        guard validNoteIds.contains(value.focus.id) else { return nil }
        return RelatedNotes(focus: value.focus, mode: value.mode, indexed: value.indexed, total: value.total,
                            related: value.related.filter { validNoteIds.contains($0.id) })
    }

    @discardableResult
    func shuffle(notes: [Note], api: WeijiAPIClient) -> Task<Void, Never>? {
        let current = result?.focus.id
        guard let note = notes.lazy.filter({ $0.id != current }).randomElement() else { return nil }
        return pivot(to: note.id, api: api)
    }

    @discardableResult
    func pivot(to noteId: String, api: WeijiAPIClient) -> Task<Void, Never>? {
        guard noteId != result?.focus.id else { return nil }
        generation += 1
        let stamp = generation
        task?.cancel()
        loading = true
        error = nil
        let currentTask = Task {
            defer { if stamp == generation { loading = false } }
            do {
                let next: RelatedNotes = try await api.get("/api/notes/\(noteId)/related?limit=10")
                commitResponse(next, generation: stamp)
            } catch is CancellationError {
            } catch {
                if stamp == generation, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        task = currentTask
        return currentTask
    }

    private func commitResponse(_ next: RelatedNotes, generation stamp: Int) {
        guard stamp == generation, !Task.isCancelled, let sanitized = validResult(next) else { return }
        if let result, let previous = validResult(result) { history.append(previous) }
        result = sanitized
    }
}
