import Foundation
import Observation

@Observable @MainActor
final class InsightsStore {
    static let writingStyleRelayMessage = "当前 Codex 中转暂不支持写作风格，请切换到服务端网关或 OpenAI 接口。"
    static let writingStyleMaxRules = 1500
    static let writingStyleMaxAnchors = 5
    static let blindTestMaxPrompt = 500

    var scope = InsightScope()
    private(set) var lenses: [InsightLens] = []
    var lensId = "builtin:default"
    var useProfile = false
    private(set) var stats: InsightStats?
    private(set) var reports: [InsightReport] = []
    private(set) var running = false
    private(set) var runningLensName: String?
    private(set) var liveReport: InsightReport?
    private(set) var liveReportText = ""
    private(set) var liveReportError: String?
    private(set) var loadingReport = false
    private(set) var viewedReport: InsightReport?
    private(set) var viewedReportText = ""
    private(set) var viewedReportError: String?
    private(set) var deletingReport = false
    private(set) var error: String?

    private(set) var profile: Profile?
    private(set) var profileText = ""
    private(set) var generatingProfile = false
    private(set) var savingProfile = false
    private(set) var profileError: String?
    @ObservationIgnored private var profileSaveError: Error?
    @ObservationIgnored private var profileSaveTask: Task<Bool, Never>?
    @ObservationIgnored private var profileTask: Task<Void, Never>?
    @ObservationIgnored private var profileGeneration = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var viewReportTask: Task<Void, Never>?
    @ObservationIgnored private var viewReportGeneration = 0
    private(set) var viewedReportID: String?
    @ObservationIgnored private var reportsGeneration = 0
    @ObservationIgnored var onReportDeleted: (@MainActor (String) -> Void)?
    @ObservationIgnored var onReportsLoaded: (@MainActor ([InsightReport], WeijiAPIClient) async -> Void)?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var contextGeneration = 0

    private(set) var writingStyle: WritingStyle?
    private(set) var writingStyleLoaded = false
    private(set) var writingStyleRulesText = ""
    var writingStyleScope = InsightScope()
    private(set) var suggestedAnchors: [WritingStyleAnchor] = []
    private(set) var loadingWritingStyle = false
    private(set) var generatingWritingStyle = false
    private(set) var savingWritingStyle = false
    private(set) var writingStyleStatus: String?
    private(set) var writingStyleError: String?
    private(set) var runningBlindTest = false
    private(set) var blindTest: BlindTestResponse?
    private(set) var blindTestVote: String?
    private(set) var blindTestError: String?
    @ObservationIgnored private var styleLoadTask: Task<Void, Never>?
    @ObservationIgnored private var styleSaveTask: Task<Bool, Never>?
    @ObservationIgnored private var styleSaveError: Error?
    @ObservationIgnored private var styleTask: Task<Void, Never>?
    @ObservationIgnored private var styleGeneration = 0
    @ObservationIgnored private var styleSaveGeneration = 0
    @ObservationIgnored private var blindTestTask: Task<Void, Never>?
    @ObservationIgnored private var blindTestGeneration = 0

    var selectedLens: InsightLens? { lenses.first { $0.id == lensId } }

    func prepareRecipe(_ lens: InsightLens, api: WeijiAPIClient?) {
        lensId = lens.id
        let suggested = lens.suggestedRange ?? "7d"
        var next = scope
        next.range = ["7d", "week", "month", "all"].contains(suggested) ? suggested : "7d"
        next.startDate = nil
        next.endDate = nil
        next.tags = []
        scope = next
        if let api { preview(api: api) }
    }

    func applyCustomDateRange(start: String, end: String, api: WeijiAPIClient?) {
        var next = scope
        next.range = "custom"
        next.startDate = start
        next.endDate = max(start, end)
        scope = next
        if let api { preview(api: api) }
    }

    static func filteredLenses(_ lenses: [InsightLens], category: String?) -> [InsightLens] {
        guard let category else { return lenses }
        return lenses.filter { category == "我的" ? !$0.builtin : $0.category == category }
    }

    static func resolvedCategory(_ selected: String?, for lenses: [InsightLens]) -> String? {
        if selected == "我的", !lenses.contains(where: { !$0.builtin }) { return nil }
        return selected
    }

    func reset() {
        contextGeneration += 1
        previewGeneration += 1
        profileGeneration += 1
        previewTask?.cancel()
        profileTask?.cancel()
        profileSaveTask?.cancel()
        profileSaveTask = nil
        profileSaveError = nil
        savingProfile = false
        generatingProfile = false
        profile = nil
        profileText = ""
        profileError = nil
        styleGeneration += 1
        styleSaveGeneration += 1
        styleTask?.cancel()
        styleTask = nil
        generatingWritingStyle = false
        writingStyleStatus = nil
        styleSaveTask?.cancel()
        styleSaveTask = nil
        styleSaveError = nil
        styleLoadTask?.cancel()
        styleLoadTask = nil
        loadingWritingStyle = false
        savingWritingStyle = false
        applyWritingStyle(nil)
        writingStyleLoaded = false
        suggestedAnchors = []
        writingStyleError = nil
        stopBlindTest()
        blindTest = nil
        blindTestVote = nil
        blindTestError = nil
        stopReport()
        deletingReport = false
        runningLensName = nil
        liveReport = nil
        liveReportText = ""
        liveReportError = nil
        clearViewedReport()
        error = nil
        scope = InsightScope()
        lensId = "builtin:default"
        useProfile = false
        lenses = []
        reports = []
        stats = nil
    }

    func loadLibrary(api: WeijiAPIClient) async {
        let stamp = contextGeneration
        let reportsStamp = reportsGeneration
        do {
            async let available: LensList = api.get("/api/insights/lenses")
            async let recent: ReportList = api.get("/api/insights/reports")
            let (lenses, reports) = try await (available, recent)
            guard stamp == contextGeneration, !Task.isCancelled else { return }
            self.lenses = lenses.lenses
            if !lenses.lenses.contains(where: { $0.id == lensId }) { lensId = lenses.lenses.first?.id ?? "builtin:default" }
            if reportsStamp == reportsGeneration {
                self.reports = reports.reports
                await onReportsLoaded?(reports.reports, api)
            }
        } catch is CancellationError {
        } catch {
            if stamp == contextGeneration { self.error = error.localizedDescription }
        }
    }

    func preview(api: WeijiAPIClient) {
        previewTask?.cancel()
        previewGeneration += 1
        let stamp = previewGeneration
        let scope = self.scope
        stats = nil
        error = nil
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let current: InsightStats = try await api.post("/api/insights/preview", ["scope": .scope(scope)] as [String: JSONValue])
                if stamp == previewGeneration, !Task.isCancelled { stats = current }
            } catch is CancellationError {
            } catch {
                if stamp == previewGeneration { self.error = error.localizedDescription }
            }
        }
    }

    func saveLens(_ input: LensEdit, api: WeijiAPIClient) async throws {
        let stamp = contextGeneration
        let response: LensResponse = try await api.post("/api/insights/lenses", input)
        guard stamp == contextGeneration, !Task.isCancelled else { throw CancellationError() }
        lenses.removeAll { $0.id == response.lens.id }
        lenses.append(response.lens)
        lensId = response.lens.id
    }

    func deleteLens(_ id: String, api: WeijiAPIClient) async throws {
        let stamp = contextGeneration
        let _: DeletedResponse = try await api.delete("/api/insights/lenses/\(id)")
        guard stamp == contextGeneration, !Task.isCancelled else { throw CancellationError() }
        lenses.removeAll { $0.id == id }
        if lensId == id { lensId = "builtin:default" }
    }

    func stopReport() {
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        running = false
    }

    func run(api: WeijiAPIClient, options: AIOptions) {
        guard !running else { return }
        runGeneration += 1
        let stamp = runGeneration
        liveReport = nil
        liveReportText = ""
        liveReportError = nil
        runningLensName = selectedLens?.name
        running = true
        let useProfile = self.useProfile
        var fields = options.fields
        fields["scope"] = .scope(scope)
        fields["lensId"] = .string(lensId)
        fields["useProfile"] = .bool(useProfile)
        fields["clientRequestId"] = .string(UUID().uuidString.lowercased())
        runTask = Task {
            defer { if stamp == runGeneration { running = false } }
            do {
                if useProfile { try await awaitProfileSave() }
                let result: ReportResponse = try await api.stream("/api/insights/run", fields) { [weak self] frame in
                    await self?.receiveReport(frame, generation: stamp)
                }
                guard stamp == runGeneration, !Task.isCancelled else { return }
                liveReport = result.report
                liveReportText = result.report.content ?? ""
                reportsGeneration += 1
                reports.removeAll { $0.id == result.report.id }
                reports.insert(result.report, at: 0)
            } catch is CancellationError {
            } catch {
                if stamp == runGeneration { liveReportError = error.localizedDescription }
            }
        }
    }

    private func receiveReport(_ frame: SSEParser.Frame, generation stamp: Int) {
        guard stamp == runGeneration, frame.event == "delta",
              let delta = try? JSONDecoder().decode(StreamDelta.self, from: Data(frame.data.utf8)) else { return }
        liveReportText += delta.text
    }

    private func clearViewedReport() {
        viewReportGeneration += 1
        viewReportTask?.cancel()
        viewReportTask = nil
        viewedReportID = nil
        loadingReport = false
        viewedReport = nil
        viewedReportText = ""
        viewedReportError = nil
    }

    func openReport(_ summary: InsightReport, api: WeijiAPIClient) {
        let context = contextGeneration
        clearViewedReport()
        let stamp = viewReportGeneration
        viewedReportID = summary.id
        loadingReport = true
        viewReportTask = Task {
            defer { if stamp == viewReportGeneration { loadingReport = false } }
            do {
                let response: ReportResponse = try await api.get("/api/insights/reports/\(summary.id)")
                guard stamp == viewReportGeneration, !Task.isCancelled else { return }
                viewedReport = response.report
                viewedReportText = response.report.content ?? ""
            } catch is CancellationError {
            } catch {
                if context == contextGeneration, (error as? WeijiAPIError)?.status == 404 {
                    onReportDeleted?(summary.id)
                }
                if stamp == viewReportGeneration { viewedReportError = error.localizedDescription }
            }
        }
    }

    func deleteReport(_ id: String, api: WeijiAPIClient) async -> Bool {
        guard !deletingReport else { return false }
        let context = contextGeneration
        deletingReport = true
        if liveReport?.id == id { liveReportError = nil }
        if viewedReportID == id { viewedReportError = nil }
        defer { if context == contextGeneration { deletingReport = false } }
        do {
            let _: DeletedResponse = try await api.delete("/api/insights/reports/\(id)")
            guard context == contextGeneration, !Task.isCancelled else { return false }
            reportsGeneration += 1
            reports.removeAll { $0.id == id }
            if liveReport?.id == id {
                liveReport = nil
                liveReportText = ""
                liveReportError = nil
            }
            if viewedReportID == id { clearViewedReport() }
            onReportDeleted?(id)
            return true
        } catch is CancellationError {
        } catch {
            if context == contextGeneration {
                if (error as? WeijiAPIError)?.status == 404 { onReportDeleted?(id) }
                if liveReport?.id == id { liveReportError = error.localizedDescription }
                if viewedReportID == id { viewedReportError = error.localizedDescription }
            }
        }
        return false
    }

    func loadProfile(api: WeijiAPIClient) async {
        guard !generatingProfile, !savingProfile else { return }
        let stamp = profileGeneration
        do {
            let response: ProfileResponse = try await api.get("/api/ai/profile")
            guard stamp == profileGeneration, !Task.isCancelled else { return }
            profile = response.profile
            profileText = response.profile?.content ?? ""
        } catch is CancellationError {
        } catch {
            if stamp == profileGeneration { profileError = error.localizedDescription }
        }
    }

    @discardableResult
    func saveProfile(_ input: ProfileEdit, api: WeijiAPIClient) -> Task<Bool, Never>? {
        guard !savingProfile, !generatingProfile else { return nil }
        profileGeneration += 1
        let stamp = profileGeneration
        savingProfile = true
        profileError = nil
        profileSaveError = nil
        let task = Task {
            defer {
                if stamp == profileGeneration {
                    savingProfile = false
                    profileSaveTask = nil
                }
            }
            do {
                let response: ProfileResponse = try await api.post("/api/ai/profile", input)
                guard stamp == profileGeneration, !Task.isCancelled else { return false }
                profile = response.profile
                profileText = response.profile?.content ?? ""
                return true
            } catch is CancellationError {
                return false
            } catch {
                if stamp == profileGeneration {
                    profileSaveError = error
                    profileError = error.localizedDescription
                }
                return false
            }
        }
        profileSaveTask = task
        return task
    }

    var hasPendingOrFailedProfileSave: Bool { profileSaveTask != nil || profileSaveError != nil }

    func awaitProfileSave() async throws {
        if let task = profileSaveTask { _ = await task.value }
        try Task.checkCancellation()
        if profileSaveError != nil {
            throw WeijiAPIError(status: 0, message: "个人画像保存失败。请重新保存画像后再发送。")
        }
    }

    func stopProfile() {
        guard generatingProfile else { return }
        profileGeneration += 1
        profileTask?.cancel()
        generatingProfile = false
        profileText = profile?.content ?? ""
    }

    func generateProfile(api: WeijiAPIClient, options: AIOptions) {
        guard !savingProfile, !generatingProfile else { return }
        profileGeneration += 1
        let stamp = profileGeneration
        generatingProfile = true
        profileText = ""
        profileError = nil
        profileTask = Task {
            defer { if stamp == profileGeneration { generatingProfile = false } }
            do {
                let response: ProfileResponse = try await api.stream("/api/ai/profile/generate", options.fields) { [weak self] frame in
                    await self?.receiveProfile(frame, generation: stamp)
                }
                guard stamp == profileGeneration, !Task.isCancelled else { return }
                profile = response.profile
                profileText = response.profile?.content ?? ""
                profileSaveError = nil
            } catch is CancellationError {
            } catch {
                if stamp == profileGeneration {
                    profileText = profile?.content ?? ""
                    profileError = error.localizedDescription
                }
            }
        }
    }

    func loadWritingStyle(api: WeijiAPIClient) async {
        let contextStamp = contextGeneration
        if let task = styleSaveTask { _ = await task.value }
        guard contextStamp == contextGeneration, !Task.isCancelled, !generatingWritingStyle,
              !savingWritingStyle, styleSaveError == nil else { return }
        if let active = styleLoadTask {
            await active.value
            return
        }
        let (genStamp, saveStamp) = (styleGeneration, styleSaveGeneration)
        loadingWritingStyle = true
        // The account's read must survive cancellation of a view's task.
        let task = Task {
            @MainActor func isCurrent() -> Bool {
                contextStamp == contextGeneration && genStamp == styleGeneration && saveStamp == styleSaveGeneration
            }
            defer {
                if isCurrent() {
                    loadingWritingStyle = false
                    styleLoadTask = nil
                }
            }
            do {
                let response: WritingStyleResponse = try await api.get("/api/ai/writing-style")
                guard isCurrent(), styleSaveError == nil, !Task.isCancelled else { return }
                applyWritingStyle(response.style)
                writingStyleLoaded = true
                writingStyleError = nil
            } catch is CancellationError {
            } catch {
                if isCurrent(), styleSaveError == nil, !Task.isCancelled { writingStyleError = error.localizedDescription }
            }
        }
        styleLoadTask = task
        await task.value
    }

    private func applyWritingStyle(_ style: WritingStyle?) {
        writingStyle = style
        writingStyleRulesText = style?.rules ?? ""
        writingStyleScope = style?.scope ?? InsightScope()
    }

    @discardableResult
    func saveWritingStyle(_ input: WritingStyleEdit, api: WeijiAPIClient) -> Task<Bool, Never>? {
        guard writingStyleLoaded else {
            writingStyleError = "尚未成功读取写作风格，请先重新加载。"
            return nil
        }
        guard !savingWritingStyle, !generatingWritingStyle else { return nil }
        styleSaveGeneration += 1
        styleGeneration += 1
        let stamp = styleSaveGeneration
        styleLoadTask = nil
        loadingWritingStyle = false
        savingWritingStyle = true
        writingStyleError = nil
        let task = Task {
            defer {
                if stamp == styleSaveGeneration {
                    savingWritingStyle = false
                    styleSaveTask = nil
                }
            }
            do {
                let response: WritingStyleResponse = try await api.post("/api/ai/writing-style", input)
                guard stamp == styleSaveGeneration, !Task.isCancelled else { return false }
                applyWritingStyle(response.style)
                writingStyleLoaded = true
                styleSaveError = nil
                return true
            } catch is CancellationError {
                return false
            } catch {
                if stamp == styleSaveGeneration, !Task.isCancelled {
                    styleSaveError = error
                    writingStyleError = error.localizedDescription
                }
                return false
            }
        }
        styleSaveTask = task
        return task
    }

    @discardableResult
    func addWritingStyleAnchor(_ id: String, api: WeijiAPIClient) -> Task<Bool, Never>? {
        guard writingStyleLoaded else {
            writingStyleError = "尚未成功读取写作风格，请先重新加载。"
            return nil
        }
        let ids = writingStyle?.anchors.map(\.id) ?? []
        guard ids.count < Self.writingStyleMaxAnchors, !ids.contains(id) else { return nil }
        return saveWritingStyle(.init(anchorNoteIds: ids + [id]), api: api)
    }

    var hasPendingOrFailedWritingStyleSave: Bool { styleSaveTask != nil || styleSaveError != nil }

    func awaitWritingStyleSave() async throws {
        let stamp = contextGeneration
        while let task = styleSaveTask {
            _ = await task.value
            try Task.checkCancellation()
            guard stamp == contextGeneration else { throw CancellationError() }
        }
        try Task.checkCancellation()
        if styleSaveError != nil {
            throw WeijiAPIError(status: 0, message: "写作风格保存失败。请重新保存写作风格后再发送。")
        }
    }

    func generateWritingStyle(api: WeijiAPIClient, options: AIOptions, isRelayMode: Bool) {
        guard !isRelayMode else { writingStyleError = Self.writingStyleRelayMessage; return }
        guard !generatingWritingStyle, !savingWritingStyle else { return }
        styleGeneration += 1
        let stamp = styleGeneration
        styleLoadTask = nil
        loadingWritingStyle = false
        generatingWritingStyle = true
        writingStyleError = nil
        writingStyleRulesText = ""
        var fields = options.fields
        fields["scope"] = .scope(writingStyleScope)
        styleTask = Task {
            defer {
                if stamp == styleGeneration {
                    generatingWritingStyle = false
                    writingStyleStatus = nil
                    styleTask = nil
                }
            }
            do {
                let response: WritingStyleGenerateResponse = try await api.stream("/api/ai/writing-style/generate", fields) { [weak self] frame in
                    await self?.receiveWritingStyle(frame, generation: stamp)
                }
                guard stamp == styleGeneration, !Task.isCancelled else { return }
                applyWritingStyle(response.style)
                writingStyleLoaded = true
                suggestedAnchors = response.suggestedAnchors
                styleSaveError = nil
            } catch {
                guard stamp == styleGeneration else { return }
                writingStyleRulesText = writingStyle?.rules ?? ""
                if !(error is CancellationError), !Task.isCancelled { writingStyleError = error.localizedDescription }
            }
        }
    }

    private func receiveWritingStyle(_ frame: SSEParser.Frame, generation stamp: Int) {
        guard stamp == styleGeneration, !Task.isCancelled else { return }
        let data = Data(frame.data.utf8)
        if frame.event == "status" {
            writingStyleStatus = (try? JSONDecoder().decode(StreamStatus.self, from: data))?.message
        } else if frame.event == "delta", let delta = try? JSONDecoder().decode(StreamDelta.self, from: data) {
            writingStyleRulesText = clippedUTF16(writingStyleRulesText + delta.text, to: Self.writingStyleMaxRules)
        }
    }

    func stopWritingStyle() {
        guard generatingWritingStyle else { return }
        styleGeneration += 1
        styleTask?.cancel()
        styleTask = nil
        generatingWritingStyle = false
        writingStyleStatus = nil
        writingStyleRulesText = writingStyle?.rules ?? ""
    }

    func runBlindTest(api: WeijiAPIClient, options: AIOptions, prompt: String, isRelayMode: Bool) {
        guard !isRelayMode else { blindTestError = Self.writingStyleRelayMessage; return }
        guard !runningBlindTest else { return }
        blindTestGeneration += 1
        let stamp = blindTestGeneration
        runningBlindTest = true
        blindTest = nil
        blindTestVote = nil
        blindTestError = nil
        var fields = options.nonStreamingFields
        let topic = clippedUTF16(prompt, to: Self.blindTestMaxPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { fields["prompt"] = .string(topic) }
        blindTestTask = Task {
            defer {
                if stamp == blindTestGeneration {
                    runningBlindTest = false
                    blindTestTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let response: BlindTestResponse = try await api.post("/api/ai/writing-style/blind-test", fields)
                guard stamp == blindTestGeneration, !Task.isCancelled else { return }
                blindTest = response
            } catch is CancellationError {
            } catch {
                if stamp == blindTestGeneration, !Task.isCancelled { blindTestError = error.localizedDescription }
            }
        }
    }

    func stopBlindTest() {
        blindTestGeneration += 1
        blindTestTask?.cancel()
        blindTestTask = nil
        runningBlindTest = false
    }

    func voteBlindTest(_ vote: String) {
        guard blindTest != nil, blindTestVote == nil, ["A", "B", "tie"].contains(vote) else { return }
        blindTestVote = vote
    }

    private func receiveProfile(_ frame: SSEParser.Frame, generation stamp: Int) {
        guard stamp == profileGeneration, frame.event == "delta",
              let delta = try? JSONDecoder().decode(StreamDelta.self, from: Data(frame.data.utf8)) else { return }
        profileText += delta.text
    }
}
