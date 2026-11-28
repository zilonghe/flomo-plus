import SwiftUI
import UIKit

struct ConnectionSettingsDraft {
    private(set) var address: String
    var token: String
    private var tokenOrigin: String?

    init(configuration: ServerConfiguration?) {
        address = configuration?.origin ?? ServerConfiguration.defaultOrigin
        token = configuration?.token ?? ""
        tokenOrigin = configuration?.origin
    }

    mutating func setAddress(_ address: String, savedToken: (String) -> String?) {
        self.address = address
        let origin = try? ServerConfiguration(address: address, token: "").origin
        guard origin != tokenOrigin else { return }
        tokenOrigin = origin
        token = origin.flatMap(savedToken) ?? ""
    }

    func configuration() throws -> ServerConfiguration {
        try ServerConfiguration(address: address, token: token)
    }
}

struct ConnectionSettingsView: View {
    let store: AppStore
    let section: AppStore.SettingsSection
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionSettingsDraft
    @State private var error: String?
    @State private var apiKey: String
    @State private var aiError: String?
    @State private var semantic: SemanticStatus?
    @State private var indexing = false
    @State private var oauth = OAuthSessionCoordinator()
    @State private var providers: OAuthProviders?
    @State private var loginBusy = false
    @State private var obsidian: ObsidianSyncStatus?
    @State private var obsidianBusy = false
    @State private var obsidianError: String?
    @State private var showModelPicker = false
    @State private var path: [Page]
    @State private var focusKeyAfterPicker = false
    @FocusState private var keyFocused: Bool

    private enum Page: Hashable { case account, ai, data, profile }

    private var modelTitle: String {
        store.selectedModelMeta?.label ?? store.options.provider.label
    }

    private var accountTitle: String {
        let host = store.configuration.flatMap { URL(string: $0.origin)?.host }
        return [store.identity?.user.name, host].compactMap { $0 }.joined(separator: " · ")
    }

    private var origin: String? {
        try? ServerConfiguration(address: draft.address, token: "").origin
    }

    init(store: AppStore, section: AppStore.SettingsSection) {
        self.store = store
        self.section = section
        _apiKey = State(initialValue: store.options.apiKey)
        _path = State(initialValue: section == .ai ? [.ai] : [])
        var draft = ConnectionSettingsDraft(configuration: store.configuration)
        draft.setAddress(draft.address, savedToken: store.savedConnectionToken(for:))
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    settingLink("账号", summary: accountTitle, destination: .account)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    settingLink("AI", summary: "\(modelTitle) · \(store.insights.profile?.enabled == true ? "画像已开启" : "画像未开启")", destination: .ai)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    settingLink("数据", summary: "Obsidian 同步 · 语义索引", destination: .data)
                }
                .padding(.horizontal, 24)
            }
            .background(Theme.canvas)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    IconAction(symbol: "xmark", label: "关闭设置", id: "settings-close", action: finish)
                }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .account: account
                case .ai: ai
                case .data: data
                case .profile: ProfileWorkspaceView(store: store).navigationTitle("个人画像")
                }
            }
        }
        .tint(Theme.ink)
        .presentationBackground(Theme.canvas)
        .task(id: store.api.map(ObjectIdentifier.init)) {
            if let api = store.api { await store.insights.loadProfile(api: api) }
        }
    }

    private func settingLink(_ title: String, summary: String, destination: Page) -> some View {
        NavigationLink(value: destination) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                    if !summary.isEmpty { Text(summary).font(.footnote).foregroundStyle(Theme.ink2) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.ink2).accessibilityHidden(true)
            }
            .padding(.vertical, 8).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var account: some View {
        List {
            Section("自托管服务") {
                TextField("服务器地址", text: Binding(get: { draft.address }, set: {
                    draft.setAddress($0, savedToken: store.savedConnectionToken(for:))
                }), prompt: Text("https://weiji.example.com"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(loginBusy || store.signingOut)
                if let providers, providers.authMode == "oauth", providers.publicOrigin == origin {
                    ForEach(providers.providers) { provider in
                        Button("用 \(provider.name) 登录") { login(provider.id) }
                            .disabled(loginBusy || store.syncing || store.signingOut)
                    }
                }
                SecureField("手动访问令牌", text: $draft.token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(loginBusy || store.signingOut)
                Button("测试并连接", action: connect).disabled(store.syncing || loginBusy || store.signingOut)
                if store.syncing || loginBusy || store.signingOut { ProgressView() }
                if let user = store.identity?.user { LabeledContent("账户", value: user.name) }
                if store.identity != nil || store.isOffline {
                    Button("退出登录", role: .destructive) {
                        error = nil
                        draft.token = ""
                        Task { await store.logout() }
                    }.disabled(loginBusy || store.signingOut)
                }
                InlineError(message: error ?? store.error)
            }
            .listRowBackground(Theme.canvas)
        }
        .listStyle(.plain)
        .weijiSheetBackground()
        .navigationTitle("账号")
        .task(id: origin) { await discoverProviders() }
    }

    private var ai: some View {
        List {
            Section {
                if store.identity?.codexAvailable == true {
                    Picker("模型来源", selection: Binding(get: { store.options.provider }, set: store.setProvider)) {
                        Text(AIProvider.codex.label).tag(AIProvider.codex)
                        Text(AIProvider.openai.label).tag(AIProvider.openai)
                    }.minTapHeight()
                }
                Button { showModelPicker = true } label: {
                    LabeledContent("默认模型与思考深度", value: modelTitle).minTapHeight()
                }
                if store.options.provider == .openai {
                    SecureField("OpenAI API Key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($keyFocused).minTapHeight()
                }
                NavigationLink("个人画像", value: Page.profile).minTapHeight()
                InlineError(message: aiError)
            }
            .listRowBackground(Theme.canvas)
        }
        .listStyle(.plain)
        .weijiSheetBackground()
        .navigationTitle("AI")
        .toolbar {
            if store.options.provider == .openai && apiKey != store.options.apiKey {
                ToolbarItem(placement: .confirmationAction) { Button("保存 Key") { saveKey() } }
            }
        }
        .sheet(isPresented: $showModelPicker, onDismiss: {
            if focusKeyAfterPicker { focusKeyAfterPicker = false; keyFocused = true }
        }) {
            ModelPickerSheet(store: store, choice: .init(model: store.options.model, effort: store.options.reasoningEffort),
                             onSelect: { choice in
                store.setModel(choice.model)
                store.setReasoningEffort(choice.effort)
            }, openSettings: {
                focusKeyAfterPicker = true
                showModelPicker = false
            })
            .presentationDetents([.medium, .large])
        }
    }

    private var data: some View {
        List {
            if store.api != nil {
                Section("语义索引") {
                    if let total = semantic?.total, let indexed = semantic?.indexed {
                        LabeledContent("已索引", value: "\(indexed) / \(total)")
                    }
                    Button("查询状态") { updateIndex(rebuild: false) }.disabled(indexing)
                    Button("重建索引") { updateIndex(rebuild: true) }.disabled(indexing)
                    if indexing { ProgressView() }
                }
            }
            if store.identity?.user.role == "admin", let obsidian, obsidian.configured {
                Section("Obsidian 同步") {
                    if let run = obsidian.lastRun {
                        if let at = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(run.at) {
                            LabeledContent("上次同步", value: at.formatted(date: .abbreviated, time: .shortened))
                        } else {
                            LabeledContent("上次同步", value: run.at)
                        }
                        if let stats = run.stats {
                            Text("新增 \(stats.created) · 更新 \(stats.updated) · 冲突 \(stats.conflicts)")
                                .font(.subheadline).foregroundStyle(Theme.ink2)
                        }
                        InlineError(message: run.ok ? run.indexWarning : (run.error ?? "同步失败"))
                    }
                    Button("立即同步 Obsidian", action: syncObsidian).disabled(obsidianBusy)
                    if obsidianBusy || obsidian.running == true { ProgressView().accessibilityLabel("正在同步 Obsidian") }
                    InlineError(message: obsidianError)
                }
            }
        }
        .listStyle(.plain)
        .weijiSheetBackground()
        .navigationTitle("数据")
        .safeAreaInset(edge: .bottom) { InlineError(message: error).padding(.horizontal, 24) }
        .task(id: store.api.map(ObjectIdentifier.init)) {
            obsidian = nil
            obsidianError = nil
            guard store.identity?.user.role == "admin", let api = store.api else { return }
            let status = try? await api.obsidianStatus()
            if !Task.isCancelled, store.api === api { obsidian = status }
        }
    }

    private func finish() {
        if saveKey() { dismiss() }
    }

    @discardableResult
    private func saveKey() -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if key != store.options.apiKey { try store.setAPIKey(key) }
            aiError = nil
            return true
        } catch {
            aiError = error.localizedDescription
            path = [.ai]
            return false
        }
    }

    private func discoverProviders() async {
        providers = nil
        guard let origin else { return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let config = try ServerConfiguration(address: origin, token: "")
            let client = WeijiAPIClient(configuration: config)
            defer { Task { await client.cancel() } }
            let result = try await client.authProviders()
            if !Task.isCancelled, self.origin == origin { providers = result }
        } catch {}
    }

    private func login(_ provider: String) {
        guard let origin else { return }
        error = nil
        loginBusy = true
        Task {
            defer { loginBusy = false }
            do {
                let pkce = try OAuthPKCE.generate()
                let url = try pkce.startURL(origin: origin, provider: provider)
                let callback = try await oauth.authenticate(url)
                try await store.finishOAuth(origin: origin, callback: callback, pkce: pkce, deviceLabel: UIDevice.current.model)
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func connect() {
        error = nil
        do { store.connect(try draft.configuration(), save: true) }
        catch { self.error = error.localizedDescription }
    }

    private func updateIndex(rebuild: Bool) {
        guard let api = store.api else { return }
        indexing = true
        error = nil
        Task {
            defer { indexing = false }
            do {
                let status: SemanticStatus
                if rebuild { status = try await api.post("/api/semantic/reindex", [String: String]()) }
                else { status = try await api.get("/api/semantic/status") }
                if store.api === api { semantic = status }
            } catch is CancellationError {
            } catch { if store.api === api { self.error = error.localizedDescription } }
        }
    }

    private func syncObsidian() {
        guard !obsidianBusy, obsidian?.configured == true,
              store.identity?.user.role == "admin", let api = store.api else { return }
        obsidianBusy = true
        obsidianError = nil
        Task {
            defer { obsidianBusy = false }
            do {
                let result = try await api.triggerObsidianSync()
                guard store.api === api else { return }
                obsidian = result.status
                if result.stats.created > 0 || result.stats.updated > 0 { store.refresh() }
            } catch is CancellationError {
            } catch { if store.api === api { obsidianError = error.localizedDescription } }
        }
    }
}
