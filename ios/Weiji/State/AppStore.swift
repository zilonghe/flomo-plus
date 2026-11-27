import Foundation
import Observation

enum AuthScreenState: Equatable {
    case restoring, needsLogin, online, offline
}

enum DetailSource: Hashable, Sendable {
    case notes, walk, ai, insights

    var supportsZoom: Bool { self == .notes || self == .walk }
}

@Observable @MainActor
final class AppStore {
    enum Tab: String, CaseIterable { case notes, walk, ai, insights }
    enum SettingsSection: String, Identifiable {
        case general, ai
        var id: String { rawValue }
    }

    enum PendingChatSwitch {
        case note(Note), walk(RelatedNotes), report(InsightReport), session(String), new
    }

    struct Detail: Identifiable, Hashable {
        let note: Note
        let source: DetailSource
        var id: String { note.id }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.source == rhs.source
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(source)
        }
    }

    let walk = WalkStore()
    let chat = AIChatStore()
    let insights = InsightsStore()

    var tab: Tab = .notes
    var detail: Detail?
    var settingsSection: SettingsSection?
    var showComposer = false
    private(set) var pendingChatSwitch: PendingChatSwitch?
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
    private(set) var signingOut = false
    private(set) var isOffline = false
    private(set) var options = AIOptions()
    private(set) var gatewayModelMeta: [ModelMeta] = []
    private(set) var gatewayDefault: String?

    var selectedModelMeta: ModelMeta? {
        if let selectedGatewayModel { return selectedGatewayModel }
        return options.model.isEmpty ? nil : .inferred(from: options.model)
    }

    var selectedGatewayModel: ModelMeta? {
        guard options.provider == .codex, identity?.codexMode == "gateway" else { return nil }
        let selected = options.model.isEmpty ? gatewayDefault : options.model
        return gatewayModelMeta.first { $0.id == selected }
    }
    var notesById: [String: Note] { index.byId }
    var authScreenState: AuthScreenState {
        if identity != nil { return .online }
        if isOffline { return .offline }
        if syncing && configuration != nil { return .restoring }
        return .needsLogin
    }

    @ObservationIgnored private let cache: NoteCacheStore
    @ObservationIgnored private let temporary: Bool
    @ObservationIgnored private let initial: ServerConfiguration?
    @ObservationIgnored private let credentials: KeychainStore
    @ObservationIgnored private let makeTransport: () -> URLSession?
    @ObservationIgnored private let runSearch: @Sendable (NoteIndex, String, NoteFilter) -> [Note]
    @ObservationIgnored private var accountKey: NoteCacheStore.Key?
    @ObservationIgnored private var rejectedChatDraft: (key: NoteCacheStore.Key, text: String)?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var dataGeneration = 0
    @ObservationIgnored private var notesETag: String?
    @ObservationIgnored private var workingNotes: [String: Note] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var offlineFallbackAllowed = true

    init(initial: ServerConfiguration? = nil, temporary: Bool = false, reset: Bool = false,
         cache: NoteCacheStore? = nil, credentials: KeychainStore? = nil,
         makeTransport: @escaping () -> URLSession? = { nil },
         runSearch: @escaping @Sendable (NoteIndex, String, NoteFilter) -> [Note] = { index, query, filter in
             index.search(query, filter: filter)
         }) {
        self.initial = initial
        self.temporary = temporary
        self.credentials = credentials ?? .live
        self.makeTransport = makeTransport
        self.runSearch = runSearch
        self.cache = cache ?? (reset ? NoteCacheStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) : NoteCacheStore())
    }

    func start() {
        guard !started else { return }
        started = true
        if let initial { connect(initial, save: false); return }
        if let origin = UserDefaults.standard.string(forKey: "weiji.origin"),
           let token = credentials.serverToken(for: origin),
           let config = try? ServerConfiguration(address: origin, token: token) {
            connect(config, save: false)
        }
    }

    func connect(_ config: ServerConfiguration, save: Bool) {
        guard !signingOut else { return }
        let previousKey = accountKey
        let previous = configuration
        if let previous, previous != config { offlineFallbackAllowed = false }
        let canPreload = !save && offlineFallbackAllowed && (previous == nil || previous == config)
        if let rejectedChatDraft, rejectedChatDraft.key.origin != config.origin { self.rejectedChatDraft = nil }
        resetConnection(to: config)
        settingsSection = nil
        let stamp = connectionGeneration
        syncing = true

        connectionTask = Task { [self] in
            let probe = WeijiAPIClient(configuration: config, transport: makeTransport())
            defer {
                if stamp == connectionGeneration { syncing = false }
                Task { await probe.cancel() }
            }
            do {
                if let previousKey, previous?.origin != config.origin { try? await cache.invalidate(previousKey) }
                var preloadedKey: NoteCacheStore.Key?
                if canPreload, let entry = try? await cache.loadOfflineSnapshot(config) {
                    guard stamp == connectionGeneration, !Task.isCancelled else { return }
                    preloadedKey = entry.key
                    isOffline = true
                    await replace(with: entry.snapshot.notes, etag: entry.snapshot.etag, persist: false)
                }
                guard stamp == connectionGeneration, !Task.isCancelled else { return }
                let session: SessionInfo = try await probe.get("/api/session")
                try Task.checkCancellation()
                guard stamp == connectionGeneration else { return }
                let key = NoteCacheStore.Key(origin: config.origin, userId: session.user.id)
                if let previousKey, previousKey != key { try? await cache.invalidate(previousKey) }
                if let preloadedKey, preloadedKey != key {
                    clearLoadedState()
                    try? await cache.invalidate(preloadedKey)
                }
                try Task.checkCancellation()
                guard stamp == connectionGeneration else { return }
                if save && !temporary {
                    try credentials.saveServerToken(config.token, for: config.origin)
                    UserDefaults.standard.set(config.origin, forKey: "weiji.origin")
                }
                let confirmedSnapshot: NoteCacheStore.Snapshot?
                if save, preloadedKey == nil, previous == nil || previous == config,
                   let entry = try? await cache.loadOfflineSnapshot(config), entry.key == key {
                    confirmedSnapshot = entry.snapshot
                } else {
                    confirmedSnapshot = nil
                }
                guard stamp == connectionGeneration, !Task.isCancelled else { return }
                try? await cache.bind(config, userId: session.user.id)
                guard stamp == connectionGeneration, !Task.isCancelled else { return }
                offlineFallbackAllowed = true
                isOffline = false
                accountKey = key
                identity = session
                options.provider = session.defaultProvider
                restoreModelPreferences()
                if !temporary && !key.userId.isEmpty {
                    options.apiKey = credentials.openAIKey(origin: key.origin, userId: key.userId) ?? ""
                }
                let client = WeijiAPIClient(configuration: config, account: session.user.id, transport: makeTransport(),
                                            onObsidianNotesChanged: { [weak self] in
                    await self?.invalidateNotesETag(connection: stamp)
                }, onAuthenticationRejected: { [weak self] failure in
                    await self?.rejectConnection(config, failure: failure, generation: stamp)
                })
                api = client
                if let rejectedChatDraft, rejectedChatDraft.key == key { chat.draft = rejectedChatDraft.text }
                rejectedChatDraft = nil
                settingsSection = nil
                if let confirmedSnapshot {
                    await replace(with: confirmedSnapshot.notes, etag: confirmedSnapshot.etag, persist: false)
                } else if preloadedKey != key, let cached = try? await cache.loadSnapshot(key),
                          stamp == connectionGeneration, !Task.isCancelled, workingNotes.isEmpty {
                    // A validator can only come from a snapshot bound to this credential before authentication.
                    await replace(with: cached.notes, persist: false)
                }
                guard stamp == connectionGeneration else { return }
                await fetchNotes()
                guard stamp == connectionGeneration else { return }
                if session.codexMode == "gateway" {
                    let models: ModelOptions? = try? await client.get("/api/ai/models")
                    if stamp == connectionGeneration, let models {
                        gatewayModelMeta = models.resolvedMeta
                        gatewayDefault = models.defaultModel
                        if options.provider == .codex {
                            restoreModelPreferences()
                            if !gatewayModelMeta.isEmpty, !options.model.isEmpty, selectedGatewayModel == nil {
                                setModel("")
                            }
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                guard stamp == connectionGeneration, !Task.isCancelled else { return }
                if let failure = error as? WeijiAPIError, failure.rejectsAuthentication {
                    await rejectConnection(config, failure: failure, generation: stamp)
                    return
                }
                if offlineFallbackAllowed, Self.isNetworkUnavailable(error) {
                    if !isOffline, let cached = try? await cache.loadOfflineSnapshot(config) {
                        guard stamp == connectionGeneration, !Task.isCancelled else { return }
                        isOffline = true
                        await replace(with: cached.snapshot.notes, etag: cached.snapshot.etag, persist: false)
                    }
                    guard stamp == connectionGeneration, !Task.isCancelled else { return }
                    if isOffline { return }
                }
                clearLoadedState()
                self.error = error.localizedDescription
                settingsSection = nil
            }
        }
    }

    private func resetConnection(to config: ServerConfiguration?) {
        connectionTask?.cancel()
        if let api { Task { await api.cancel() } }
        connectionGeneration += 1
        tab = .notes
        identity = nil
        api = nil
        accountKey = nil
        configuration = config
        query = ""
        filter = NoteFilter()
        clearLoadedState()
        error = nil
        gatewayModelMeta = []
        gatewayDefault = nil
        options = AIOptions()
    }

    private func clearLoadedState() {
        refreshTask?.cancel()
        searchTask?.cancel()
        searchGeneration += 1
        dataGeneration += 1
        detail = nil
        showComposer = false
        pendingChatSwitch = nil
        isOffline = false
        notesETag = nil
        workingNotes = [:]
        index = NoteIndex()
        results = []
        pageSize = 50
        walk.reset()
        chat.reset()
        insights.reset()
    }

    func finishOAuth(origin: String, callback: URL, pkce: OAuthPKCE, deviceLabel: String) async throws {
        let generation = connectionGeneration
        let config = try ServerConfiguration(address: origin, token: "")
        let client = WeijiAPIClient(configuration: config, transport: makeTransport())
        defer { Task { await client.cancel() } }
        let exchange = try await client.exchangeOAuthCallback(callback, pkce: pkce, deviceLabel: deviceLabel)
        try Task.checkCancellation()
        guard generation == connectionGeneration, !signingOut else { throw CancellationError() }
        connect(try ServerConfiguration(address: origin, token: exchange.token), save: true)
    }

    func logout() async {
        guard let config = configuration, !signingOut else { return }
        let key = accountKey
        let mode = identity?.authMode
        signingOut = true
        defer { signingOut = false }
        offlineFallbackAllowed = false
        rejectedChatDraft = nil
        resetConnection(to: nil)
        syncing = false
        settingsSection = nil
        var failure: String?
        if !temporary {
            if UserDefaults.standard.string(forKey: "weiji.origin") == config.origin {
                UserDefaults.standard.removeObject(forKey: "weiji.origin")
            }
            do { try credentials.saveServerToken("", for: config.origin) }
            catch { failure = error.localizedDescription }
        }
        do { try await cache.clearSession(config, key: key) }
        catch { failure = failure ?? "未能清除本地笔记缓存。" }
        if mode == "oauth" || (mode == nil && !config.token.isEmpty) {
            // A separate client avoids re-entering the store's authentication rejection handler.
            let client = WeijiAPIClient(configuration: config, transport: makeTransport())
            do { try await client.logout() }
            catch let error as WeijiAPIError where error.status == 401 {}
            catch { failure = failure ?? "已退出本机，但无法确认服务端会话已退出。" }
            await client.cancel()
        }
        error = failure
    }

    private func rejectConnection(_ config: ServerConfiguration, failure: WeijiAPIError, generation: Int) async {
        guard generation == connectionGeneration else { return }
        offlineFallbackAllowed = false
        let key = accountKey
        let recoverable = chat.recoverableDraft
        if let key, !recoverable.isEmpty { rejectedChatDraft = (key, recoverable) }
        resetConnection(to: config)
        settingsSection = nil
        error = failure.localizedDescription
        let stamp = connectionGeneration
        try? await cache.clearSession(config, key: key)
        guard stamp == connectionGeneration else { return }
        syncing = false
        error = failure.localizedDescription
    }

    private static func isNetworkUnavailable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    func setProvider(_ provider: AIProvider) {
        guard options.provider != provider else { return }
        options.provider = provider
        restoreModelPreferences()
    }

    func setModel(_ model: String) {
        guard options.model != model else { return }
        options.model = model
        setReasoningEffort(options.reasoningEffort)
    }

    func setReasoningEffort(_ effort: String) {
        options.reasoningEffort = selectedGatewayModel?.selectableEfforts.contains(effort) == true ? effort : ""
        guard let key = modelPreferencesKey else { return }
        UserDefaults.standard.set(options.model, forKey: key + ".model")
        UserDefaults.standard.set(options.reasoningEffort, forKey: key + ".effort")
    }

    private var modelPreferencesKey: String? {
        guard !temporary, let accountKey else { return nil }
        return "weiji.ai." + accountKey.filename + "." + options.provider.rawValue
    }

    private func restoreModelPreferences() {
        let key = modelPreferencesKey
        options.model = key.flatMap { UserDefaults.standard.string(forKey: $0 + ".model") }
            ?? (options.provider == .openai ? "gpt-4.1-mini" : "")
        let effort = key.flatMap { UserDefaults.standard.string(forKey: $0 + ".effort") } ?? ""
        options.reasoningEffort = selectedGatewayModel?.selectableEfforts.contains(effort) == true ? effort : ""
    }

    private func invalidateNotesETag(connection: Int) {
        guard connection == connectionGeneration else { return }
        notesETag = nil
        refreshGeneration += 1
        refreshTask?.cancel()
        syncing = false
    }

    func savedConnectionToken(for origin: String) -> String? {
        credentials.serverToken(for: origin)
    }

    func setAPIKey(_ key: String) throws {
        guard let accountKey, !accountKey.userId.isEmpty else {
            throw WeijiAPIError(status: 0, message: "请先连接微记账号。")
        }
        if !temporary { try credentials.saveOpenAIKey(key, origin: accountKey.origin, userId: accountKey.userId) }
        options.apiKey = key
    }

    func refresh() {
        if isOffline, !syncing, let configuration {
            connect(configuration, save: false)
            return
        }
        guard api != nil else { return }
        refreshTask?.cancel()
        syncing = true
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
            let result = try await api.fetchNotes(ifNoneMatch: notesETag)
            guard connection == connectionGeneration, stamp == refreshGeneration, !Task.isCancelled else { return }
            if case .updated(let notes, let etag) = result {
                await replace(with: notes, etag: etag)
            }
        } catch is CancellationError {
        } catch {
            if connection == connectionGeneration, stamp == refreshGeneration { self.error = error.localizedDescription }
        }
    }

    private func replace(with notes: [Note], etag: String? = nil, persist: Bool = true) async {
        notesETag = nil
        let refresh = refreshGeneration
        dataGeneration += 1
        let stamp = dataGeneration
        let connection = connectionGeneration
        workingNotes = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let job = Task.detached(priority: .userInitiated) { NoteIndex(notes) }
        let updated = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        guard connection == connectionGeneration, stamp == dataGeneration else { return }
        index = updated
        let validIds = Set(updated.byId.keys)
        walk.syncValidIds(validIds)
        chat.syncValidIds(validIds)
        if refresh == refreshGeneration { notesETag = etag }
        scheduleSearch()
        if persist, let key = accountKey {
            do { try await cache.save(updated.entries.map(\.note), etag: notesETag, for: key) }
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
        let execute = self.runSearch
        searchTask = Task {
            let job = Task.detached(priority: .userInitiated) { execute(index, query, filter) }
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

    func openNote(_ id: String, from source: DetailSource) async {
        if let note = await resolveNote(id) { detail = Detail(note: note, source: source) }
    }

    func openTag(_ tag: String) {
        detail = nil
        query = ""
        filter = NoteFilter(tag: tag.lowercased())
        tab = .notes
    }

    func canPerformReaderPrimaryAction(for noteId: String, source: DetailSource) -> Bool {
        if source == .ai {
            return chat.pins.contains(noteId) || (chat.canReference(noteId) && chat.pins.count < 10)
        }
        return api != nil && chat.canReference(noteId)
    }

    func performReaderPrimaryAction(for note: Note, source: DetailSource) {
        if source == .ai {
            chat.togglePin(note.id)
        } else {
            askAbout(note)
        }
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
        invalidateNotesETag(connection: connectionGeneration)
        workingNotes[id] = record?.note
        await replace(with: Array(workingNotes.values))
    }

    func openSettings(_ section: SettingsSection = .general) { settingsSection = section }

    func askAbout(_ note: Note) { requestChatSwitch(.note(note)) }
    func askAbout(_ walk: RelatedNotes) { requestChatSwitch(.walk(walk)) }
    func askAbout(_ report: InsightReport) { requestChatSwitch(.report(report)) }
    func requestSelectChatSession(_ id: String) { requestChatSwitch(.session(id)) }
    func requestNewChat() { requestChatSwitch(.new) }

    func cancelChatSwitch() { pendingChatSwitch = nil }

    func confirmChatSwitch() {
        guard let target = pendingChatSwitch else { return }
        pendingChatSwitch = nil
        switchChat(to: target)
    }

    private func requestChatSwitch(_ target: PendingChatSwitch) {
        if chat.sending { pendingChatSwitch = target }
        else { switchChat(to: target) }
    }

    private func switchChat(to target: PendingChatSwitch) {
        switch target {
        case .note(let note):
            detail = nil
            chat.start(source: note.id)
            if let api { chat.loadSource(note.id, api: api) }
        case .walk(let walk):
            chat.start(pins: [walk.focus.id] + walk.related.map(\.id))
        case .report(let report):
            chat.start(pins: report.citations?.map(\.noteId) ?? [], insight: report)
        case .session(let id):
            guard let api else { return }
            chat.select(id, api: api)
        case .new:
            chat.start()
        }
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
