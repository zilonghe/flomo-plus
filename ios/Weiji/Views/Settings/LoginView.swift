import SwiftUI
import UIKit

struct LoginView: View {
    let store: AppStore
    @State private var draft: ConnectionSettingsDraft
    @State private var providers: OAuthProviders?
    @State private var providerError: String?
    @State private var error: String?
    @State private var retry = 0
    @State private var loginBusy = false
    @State private var oauth = OAuthSessionCoordinator()

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
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 24) {
                    WeijiLoginMark()
                    providerButtons
                    InlineError(message: error ?? store.error)
                    DisclosureGroup("高级连接") {
                        VStack(spacing: 12) {
                            TextField("服务器地址", text: Binding(get: { draft.address }, set: {
                                draft.setAddress($0, savedToken: store.savedConnectionToken(for:))
                            }))
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .accessibilityLabel("服务器地址")
                            SecureField("手动访问令牌", text: $draft.token)
                            Button("使用令牌连接", action: connect)
                                .buttonStyle(.weijiPrimaryWide)
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 12)
                    }
                }
                .disabled(loginBusy || store.signingOut)
                .padding(24)
                .noteCard(padding: 0, cornerRadius: 28)
                .frame(maxWidth: 396)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .tint(Theme.active)
        .task(id: "\(origin ?? "")|\(retry)") { await discoverProviders() }
    }

    @ViewBuilder private var providerButtons: some View {
        if let providers {
            if providers.authMode == "oauth" {
                VStack(spacing: 10) {
                    ForEach(providers.providers) { provider in
                        Button("用 \(provider.name) 登录") { login(provider.id) }
                            .buttonStyle(.weijiPrimaryWide)
                    }
                    if loginBusy { ProgressView().accessibilityLabel("正在登录") }
                }
            }
        } else if let providerError {
            VStack(spacing: 8) {
                InlineError(message: providerError)
                Button("重试") { retry += 1 }.buttonStyle(.weijiSecondary)
            }
        } else if origin != nil {
            ProgressView().accessibilityLabel("正在载入登录方式")
        }
    }

    private func discoverProviders() async {
        providers = nil
        providerError = nil
        guard let target = origin else {
            providerError = "请输入有效的服务器地址。"
            return
        }
        do {
            if target != ServerConfiguration.defaultOrigin {
                try await Task.sleep(for: .milliseconds(300))
            }
            let config = try ServerConfiguration(address: target, token: "")
            let client = WeijiAPIClient(configuration: config)
            defer { Task { await client.cancel() } }
            let result = try await client.authProviders()
            try Task.checkCancellation()
            if result.authMode == "oauth", result.publicOrigin != config.origin {
                throw WeijiAPIError(status: 0, message: "登录服务地址不一致。")
            }
            if self.origin == target { providers = result }
        } catch is CancellationError {
        } catch {
            if self.origin == target { providerError = error.localizedDescription }
        }
    }

    private func login(_ provider: String) {
        guard let target = origin else {
            error = "请输入有效的服务器地址。"
            return
        }
        error = nil
        loginBusy = true
        Task {
            defer { loginBusy = false }
            do {
                let pkce = try OAuthPKCE.generate()
                let callback = try await oauth.authenticate(pkce.startURL(origin: target, provider: provider))
                try await store.finishOAuth(origin: target, callback: callback, pkce: pkce, deviceLabel: UIDevice.current.model)
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func connect() {
        error = nil
        do { store.connect(try draft.configuration(), save: true) }
        catch { self.error = error.localizedDescription }
    }
}

struct WeijiLoginMark: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Theme.active)
                .frame(width: 58, height: 58)
                .background(Theme.accentSoft, in: .rect(cornerRadius: 18))
                .accessibilityHidden(true)
            Text("微记").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        }
    }
}
