import Foundation
import Observation

@Observable @MainActor
final class WalkStore {
    private(set) var result: RelatedNotes?
    private(set) var loading = false
    private(set) var error: String?
    private var history: [RelatedNotes] = []
    var hasPrevious: Bool { !history.isEmpty }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func reset() {
        generation += 1
        task?.cancel()
        result = nil
        history = []
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

    func shuffle(notes: [Note], api: WeijiAPIClient) {
        let current = result?.focus.id
        guard let note = notes.lazy.filter({ $0.id != current }).randomElement() else { return }
        generation += 1
        let stamp = generation
        task?.cancel()
        loading = true
        error = nil
        task = Task {
            defer { if stamp == generation { loading = false } }
            do {
                let next: RelatedNotes = try await api.get("/api/notes/\(note.id)/related?limit=10")
                guard stamp == generation, !Task.isCancelled else { return }
                if let result { history.append(result) }
                result = next
            } catch is CancellationError {
            } catch {
                if stamp == generation { self.error = error.localizedDescription }
            }
        }
    }
}
