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
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionSettingsDraft
    @State private var error: String?
    @State private var semantic: SemanticStatus?
    @State private var indexing = false
    @State private var oauth = OAuthSessionCoordinator()
    @State private var providers: OAuthProviders?
    @State private var loginBusy = false
    @State private var obsidian: ObsidianSyncStatus?
    @State private var obsidianBusy = false
    @State private var obsidianError: String?
    @Bindable private var theme = ThemeManager.shared

    private var origin: String? {
        try? ServerConfiguration(address: draft.address, token: "").origin
    }

    init(store: AppStore) {
        self.store = store
        var draft = ConnectionSettingsDraft(configuration: store.configuration)
        draft.setAddress(draft.address, savedToken: store.savedConnectionToken(for:))
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("主题色").font(Theme.TypeScale.body).foregroundStyle(Theme.ink)
                        HStack(spacing: 0) {
                            ForEach(ThemeAccent.allCases) { option in
                                let selected = theme.accent == option
                                Button {
                                    theme.accent = option
                                } label: {
                                    VStack(spacing: 6) {
                                        ZStack {
                                            Circle()
                                                .fill(option.accent)
                                                .frame(width: 32, height: 32)
                                            if selected {
                                                Circle()
                                                    .strokeBorder(option.accent, lineWidth: 2)
                                                    .frame(width: 40, height: 40)
                                                Image(systemName: "checkmark")
                                                    .font(.footnote.weight(.bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        .frame(width: 42, height: 42)
                                        Text(option.label)
                                            .font(Theme.TypeScale.meta.weight(selected ? .semibold : .regular))
                                            .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityLabel("主题色：\(option.label)")
                                .accessibilityIdentifier("theme-accent-\(option.rawValue)")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .sensoryFeedback(.selection, trigger: theme.accent)
                }
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
            .weijiSheetBackground()
            .navigationTitle("连接设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .tint(Theme.active)
            .task(id: origin) { await discoverProviders() }
            .task(id: store.api.map(ObjectIdentifier.init)) {
                obsidian = nil
                obsidianError = nil
                guard store.identity?.user.role == "admin", let api = store.api else { return }
                let status = try? await api.obsidianStatus()
                if !Task.isCancelled, store.api === api { obsidian = status }
            }
            .onAppear {
                if store.api != nil { updateIndex(rebuild: false) }
            }
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
