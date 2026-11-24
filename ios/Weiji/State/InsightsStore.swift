import Foundation
import Observation

@Observable @MainActor
final class InsightsStore {
    var scope = InsightScope()
    private(set) var lenses: [InsightLens] = []
    var lensId = "builtin:default"
    var useProfile = false
    private(set) var stats: InsightStats?
    private(set) var reports: [InsightReport] = []
    private(set) var report: InsightReport?
    private(set) var reportText = ""
    var showReport = false
    private(set) var running = false
    private(set) var deletingReport = false
    private(set) var error: String?
    private(set) var reportError: String?

    private(set) var profile: Profile?
    private(set) var profileText = ""
    private(set) var generatingProfile = false
    private(set) var savingProfile = false
    private(set) var profileError: String?
    @ObservationIgnored private var profileSaveError: Error?
    @ObservationIgnored private var profileSaveTask: Task<Bool, Never>?
    @ObservationIgnored private var profileTask: Task<Void, Never>?
    @ObservationIgnored private var profileGeneration = 0
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var reportGeneration = 0
    @ObservationIgnored private var reportsGeneration = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var contextGeneration = 0

    var selectedLens: InsightLens? { lenses.first { $0.id == lensId } }

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
        stopReport()
        deletingReport = false
        showReport = false
        report = nil
        reportText = ""
        reportError = nil
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
            if reportsStamp == reportsGeneration { self.reports = reports.reports }
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
        reportGeneration += 1
        reportTask?.cancel()
        running = false
    }

    func run(api: WeijiAPIClient, options: AIOptions) {
        stopReport()
        let stamp = reportGeneration
        report = nil
        reportText = ""
        reportError = nil
        running = true
        showReport = true
        var fields = options.fields
        fields["scope"] = .scope(scope)
        fields["lensId"] = .string(lensId)
        fields["useProfile"] = .bool(useProfile)
        fields["clientRequestId"] = .string(UUID().uuidString.lowercased())
        reportTask = Task {
            defer { if stamp == reportGeneration { running = false } }
            do {
                if useProfile { try await awaitProfileSave() }
                let result: ReportResponse = try await api.stream("/api/insights/run", fields) { [weak self] frame in
                    await self?.receiveReport(frame, generation: stamp)
                }
                guard stamp == reportGeneration, !Task.isCancelled else { return }
                report = result.report
                reportText = result.report.content ?? ""
                reportsGeneration += 1
                reports.removeAll { $0.id == result.report.id }
                reports.insert(result.report, at: 0)
            } catch is CancellationError {
            } catch {
                if stamp == reportGeneration { reportError = error.localizedDescription }
            }
        }
    }

    private func receiveReport(_ frame: SSEParser.Frame, generation stamp: Int) {
        guard stamp == reportGeneration, frame.event == "delta",
              let delta = try? JSONDecoder().decode(StreamDelta.self, from: Data(frame.data.utf8)) else { return }
        reportText += delta.text
    }

    func openReport(_ summary: InsightReport, api: WeijiAPIClient) {
        stopReport()
        let stamp = reportGeneration
        report = nil
        reportText = ""
        reportError = nil
        running = true
        showReport = true
        reportTask = Task {
            defer { if stamp == reportGeneration { running = false } }
            do {
                let response: ReportResponse = try await api.get("/api/insights/reports/\(summary.id)")
                guard stamp == reportGeneration, !Task.isCancelled else { return }
                report = response.report
                reportText = response.report.content ?? ""
            } catch is CancellationError {
            } catch {
                if stamp == reportGeneration { reportError = error.localizedDescription }
            }
        }
    }

    func deleteReport(_ id: String, api: WeijiAPIClient) async {
        guard !deletingReport else { return }
        let context = contextGeneration
        let stamp = reportGeneration
        deletingReport = true
        reportError = nil
        defer { if context == contextGeneration { deletingReport = false } }
        do {
            let _: DeletedResponse = try await api.delete("/api/insights/reports/\(id)")
            guard context == contextGeneration, !Task.isCancelled else { return }
            reportsGeneration += 1
            reports.removeAll { $0.id == id }
            if stamp == reportGeneration, report?.id == id {
                showReport = false
                report = nil
                reportText = ""
            }
        } catch is CancellationError {
        } catch {
            if stamp == reportGeneration { reportError = error.localizedDescription }
        }
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
            defer { if stamp == profileGeneration { savingProfile = false } }
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

    private func receiveProfile(_ frame: SSEParser.Frame, generation stamp: Int) {
        guard stamp == profileGeneration, frame.event == "delta",
              let delta = try? JSONDecoder().decode(StreamDelta.self, from: Data(frame.data.utf8)) else { return }
        profileText += delta.text
    }
}
