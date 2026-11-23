import Foundation
import Observation

@Observable @MainActor
final class AppStore {
    enum Tab: String, CaseIterable { case notes, walk, ai, insights }
    struct Detail: Identifiable { let note: Note; var id: String { note.id } }

    let walk = WalkStore()
    let chat = AIChatStore()
    let insights = InsightsStore()

    var tab: Tab = .notes
    var detail: Detail?
    var showSettings = false
    var error: String?
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    var filter = NoteFilter() { didSet { if filter != oldValue { scheduleSearch() } } }
    private(set) var index = NoteIndex()
    private(set) var results: [Note] = []
    private(set) var pageSize = 50
    private(set) var identity: SessionInfo?
    private(set) var api: WeijiAPIClient?
    private(set) var configuration: ServerConfiguration?
    private(set) var syncing = false
    var options = AIOptions()
    var gatewayModels: [String] = []
    var gatewayDefault: String?
    var notesById: [String: Note] { index.byId }

    @ObservationIgnored private let cache: NoteCacheStore
    @ObservationIgnored private let temporary: Bool
    @ObservationIgnored private let initial: ServerConfiguration?
    @ObservationIgnored private var accountKey: NoteCacheStore.Key?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var dataGeneration = 0
    @ObservationIgnored private var workingNotes: [String: Note] = [:]
    @ObservationIgnored private var started = false

    init(initial: ServerConfiguration? = nil, temporary: Bool = false, reset: Bool = false) {
        self.initial = initial
        self.temporary = temporary
        cache = reset ? NoteCacheStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) : NoteCacheStore()
    }

    func start() {
        guard !started else { return }
        started = true
        if let initial { connect(initial, save: false); return }
        if let origin = UserDefaults.standard.string(forKey: "weiji.origin"),
           let token = KeychainStore.read(origin: origin),
           let config = try? ServerConfiguration(address: origin, token: token) {
            connect(config, save: false)
        } else {
            showSettings = true
        }
    }

    func connect(_ config: ServerConfiguration, save: Bool) {
        let previousKey = accountKey
        let oldClient = api
        let previousOrigin = configuration?.origin
        connectionTask?.cancel()
        refreshTask?.cancel()
        searchTask?.cancel()
        connectionGeneration += 1
        searchGeneration += 1
        dataGeneration += 1
        let stamp = connectionGeneration
        detail = nil
        tab = .notes
        identity = nil
        api = nil
        accountKey = nil
        workingNotes = [:]
        configuration = config
        index = NoteIndex()
        query = ""
        filter = NoteFilter()
        results = []
        pageSize = 50
        error = nil
        gatewayModels = []
        gatewayDefault = nil
        options = AIOptions()
        walk.reset()
        chat.reset()
        insights.reset()
        syncing = true

        connectionTask = Task {
            if let oldClient { await oldClient.cancel() }
            if let previousKey, previousOrigin != config.origin { try? await cache.invalidate(previousKey) }
            let probe = WeijiAPIClient(configuration: config)
            defer {
                if stamp == connectionGeneration { syncing = false }
                Task { await probe.cancel() }
            }
            do {
                let session: SessionInfo = try await probe.get("/api/session")
                try Task.checkCancellation()
                guard stamp == connectionGeneration else { return }
                let key = NoteCacheStore.Key(origin: config.origin, userId: session.user.id)
                if let previousKey, previousKey != key { try? await cache.invalidate(previousKey) }
                try Task.checkCancellation()
                guard stamp == connectionGeneration else { return }
                if save && !temporary {
                    try KeychainStore.write(config.token, origin: config.origin)
                    UserDefaults.standard.set(config.origin, forKey: "weiji.origin")
                }
                accountKey = key
                identity = session
                options.provider = session.defaultProvider
                options.model = session.defaultProvider == .openai ? "gpt-4.1-mini" : ""
                if !temporary { options.apiKey = KeychainStore.read(origin: config.origin, kind: "openai") ?? "" }
                let client = WeijiAPIClient(configuration: config, account: session.user.id)
                api = client
                showSettings = false
                if let cached = try? await cache.load(key), stamp == connectionGeneration, workingNotes.isEmpty {
                    await replace(with: cached, persist: false)
                }
                guard stamp == connectionGeneration else { return }
                refresh()
                if session.codexMode == "gateway" {
                    let models: ModelOptions? = try? await client.get("/api/ai/models")
                    if stamp == connectionGeneration {
                        gatewayModels = models?.models ?? []
                        gatewayDefault = models?.defaultModel
                    }
                }
            } catch is CancellationError {
            } catch {
                if stamp == connectionGeneration { self.error = error.localizedDescription; showSettings = true }
            }
        }
    }

    func setProvider(_ provider: AIProvider) {
        guard options.provider != provider else { return }
        options.provider = provider
        options.model = provider == .openai ? "gpt-4.1-mini" : ""
    }

    func setAPIKey(_ key: String) throws {
        if let origin = configuration?.origin, !temporary { try KeychainStore.write(key, origin: origin, kind: "openai") }
        options.apiKey = key
    }

    func refresh() {
        guard api != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { await fetchNotes() }
    }

    private func fetchNotes() async {
        guard let api else { return }
        refreshGeneration += 1
        let stamp = refreshGeneration
        let connection = connectionGeneration
        syncing = true
        defer { if connection == connectionGeneration && stamp == refreshGeneration { syncing = false } }
        do {
            let response: NotesResponse = try await api.get("/api/notes")
            guard connection == connectionGeneration, stamp == refreshGeneration, !Task.isCancelled else { return }
            await replace(with: response.notes)
        } catch is CancellationError {
        } catch {
            if connection == connectionGeneration, stamp == refreshGeneration { self.error = error.localizedDescription }
        }
    }

    private func replace(with notes: [Note], persist: Bool = true) async {
        dataGeneration += 1
        let stamp = dataGeneration
        let connection = connectionGeneration
        workingNotes = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let job = Task.detached(priority: .userInitiated) { NoteIndex(notes) }
        let updated = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard connection == connectionGeneration, stamp == dataGeneration else { return }
        index = updated
        scheduleSearch()
        if persist, let key = accountKey {
            do { try await cache.save(updated.entries.map(\.note), for: key) }
            catch is CancellationError {}
            catch { if connection == connectionGeneration { self.error = "无法更新本地笔记缓存。" } }
        }
    }

    func scheduleSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        let stamp = searchGeneration
        let index = self.index
        let query = self.query
        let filter = self.filter
        searchTask = Task {
            let job = Task.detached(priority: .userInitiated) { index.search(query, filter: filter) }
            let found = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled else { return }
            applySearch(found, generation: stamp)
        }
    }

    func applySearch(_ notes: [Note], generation: Int) {
        guard generation == searchGeneration else { return }
        results = notes
        pageSize = 50
    }

    func loadMore(after id: String) {
        guard pageSize < results.count, results[pageSize - 1].id == id else { return }
        pageSize += 50
    }

    func openNote(_ id: String) async {
        if let note = await resolveNote(id) { detail = Detail(note: note) }
    }

    func resolveNote(_ id: String) async -> Note? {
        let stamp = connectionGeneration
        if notesById[id] == nil { await fetchNotes() }
        guard stamp == connectionGeneration, !Task.isCancelled else { return nil }
        if let note = notesById[id] { return note }
        error = "找不到这条笔记，可能已在云端删除。"
        return nil
    }

    func create(_ body: String, id: String, createdAt: String) async throws {
        let payload = NotePayload(id: id, body: body, createdAt: createdAt, reading: nil, turns: [])
        try await mutate(NoteMutation(id: id, expectedRevision: 0, note: payload))
    }

    func update(_ note: Note, body: String) async throws {
        var draft = note
        draft.body = body
        try await mutate(NoteMutation(id: note.id, expectedRevision: note.revision, note: draft.writePayload))
    }

    func delete(_ note: Note) async throws {
        try await mutate(NoteMutation(id: note.id, expectedRevision: note.revision, delete: true))
    }

    private func mutate(_ input: NoteMutation) async throws {
        guard let api else { throw WeijiAPIError(status: 0, message: "请先连接服务。") }
        let stamp = connectionGeneration
        do {
            let result: NoteRecord = try await api.post("/api/notes", input)
            guard stamp == connectionGeneration else { throw CancellationError() }
            await applyRecord(result, id: input.id)
        } catch let failure as WeijiAPIError where failure.status == 409 && stamp == connectionGeneration {
            await applyRecord(failure.current(NoteRecord.self), id: input.id)
            throw failure
        }
    }

    func applyRecord(_ record: NoteRecord?, id: String) async {
        refreshGeneration += 1
        refreshTask?.cancel()
        syncing = false
        workingNotes[id] = record?.note
        await replace(with: Array(workingNotes.values))
    }

    func askAbout(_ note: Note) {
        detail = nil
        chat.start(source: note.id)
        tab = .ai
        if let api { chat.loadSource(note.id, api: api) }
    }

    func askAbout(_ walk: RelatedNotes) {
        chat.start(pins: [walk.focus.id] + walk.related.map(\.id))
        tab = .ai
    }

    func askAbout(_ report: InsightReport) {
        chat.start(pins: report.citations?.map(\.noteId) ?? [], insight: report)
        tab = .ai
    }

    static func timestamp() -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: .now)
    }
}

struct NoteDraft {
    var base: Note
    var body: String
    private(set) var conflict = false

    init(note: Note) { base = note; body = note.body }
    mutating func failed(_ error: Error) { conflict = (error as? WeijiAPIError)?.status == 409 }
    mutating func review(_ latest: Note) { base = latest; conflict = false }
}
