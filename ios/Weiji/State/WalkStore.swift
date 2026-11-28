import Foundation
import Observation

struct WalkCardBadge: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case tag(root: String), book }

    let text: String
    let kind: Kind

    static func accent(for kind: Kind) -> ThemeAccent {
        guard case let .tag(root) = kind else { return .graphite }
        var h: UInt32 = 2_166_136_261
        for byte in root.lowercased().utf8 {
            h = (h ^ UInt32(byte)) &* 16_777_619
        }
        return [ThemeAccent.pine, .indigo, .clay, .plum][Int(h % 4)]
    }

    static func badges(for item: RelatedNotes.Item) -> [Self] {
        let bodyTags = TagParser.tags(in: item.note.body)
        let bodyTagSet = Set(bodyTags)
        let shared = item.sharedTags.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var badges: [Self] = []
        if let tag = shared.first(where: bodyTagSet.contains) ?? bodyTags.first {
            let root = String(tag.split(separator: "/").first ?? Substring(tag))
            badges.append(Self(text: "#" + tag, kind: .tag(root: root)))
        }
        if let book = item.note.reading?.bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !book.isEmpty {
            badges.append(Self(text: book, kind: .book))
        }
        return badges
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
    @ObservationIgnored private var requestedNoteID: String?
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

    func randomNote(in index: NoteIndex, excluding id: String? = nil) -> Note? {
        index.entries.lazy.filter { $0.note.id != id }.randomElement()?.note
    }

    @discardableResult
    func shuffle(notes: [Note], api: WeijiAPIClient) -> Task<Void, Never>? {
        let current = result?.focus.id
        guard let note = notes.lazy.filter({ $0.id != current }).randomElement() else { return nil }
        return pivot(to: note.id, api: api)
    }

    @discardableResult
    func pivot(to noteId: String, api: WeijiAPIClient, keepHistory: Bool = true) -> Task<Void, Never>? {
        if noteId == result?.focus.id {
            generation += 1
            task?.cancel()
            loading = false
            error = nil
            return nil
        }
        if loading && requestedNoteID == noteId { return task }
        requestedNoteID = noteId
        generation += 1
        let stamp = generation
        task?.cancel()
        loading = true
        error = nil
        let currentTask = Task {
            defer { if stamp == generation { loading = false } }
            do {
                let next: RelatedNotes = try await api.get("/api/notes/\(noteId)/related?limit=10")
                commitResponse(next, generation: stamp, keepHistory: keepHistory)
            } catch is CancellationError {
            } catch {
                if stamp == generation, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        task = currentTask
        return currentTask
    }

    private func commitResponse(_ next: RelatedNotes, generation stamp: Int, keepHistory: Bool) {
        guard stamp == generation, !Task.isCancelled, let sanitized = validResult(next) else { return }
        if keepHistory, let result, let previous = validResult(result) { history.append(previous) }
        result = sanitized
    }
}
