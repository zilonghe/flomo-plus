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

    init(store: AppStore) {
        self.store = store
        _draft = State(initialValue: ConnectionSettingsDraft(configuration: store.configuration))
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
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 12)
                    }
                }
                .disabled(loginBusy || store.signingOut)
                .padding(24)
                .frame(maxWidth: 396)
                .weijiGlassCard(cornerRadius: 30)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background {
            RadialGradient(colors: [Theme.green.opacity(0.20), Theme.canvas],
                           center: .init(x: 0.27, y: 0.29), startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
        }
        .task(id: retry) { await discoverProviders() }
    }

    @ViewBuilder private var providerButtons: some View {
        if let providers {
            if providers.authMode == "oauth" {
                VStack(spacing: 10) {
                    ForEach(providers.providers) { provider in
                        Button {
                            login(provider.id)
                        } label: {
                            Text("用 \(provider.name) 登录")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .weijiGlassCapsule()
                        }
                        .buttonStyle(.plain)
                    }
                    if loginBusy { ProgressView().accessibilityLabel("正在登录") }
                }
            }
        } else if let providerError {
            VStack(spacing: 8) {
                InlineError(message: providerError)
                Button("重试") { retry += 1 }.buttonStyle(.bordered)
            }
        } else {
            ProgressView().accessibilityLabel("正在载入登录方式")
        }
    }

    private func discoverProviders() async {
        providerError = nil
        do {
            let config = try ServerConfiguration(address: ServerConfiguration.defaultOrigin, token: "")
            let client = WeijiAPIClient(configuration: config)
            defer { Task { await client.cancel() } }
            let result = try await client.authProviders()
            try Task.checkCancellation()
            if result.authMode == "oauth", result.publicOrigin != config.origin {
                throw WeijiAPIError(status: 0, message: "登录服务地址不一致。")
            }
            providers = result
        } catch is CancellationError {
        } catch { providerError = error.localizedDescription }
    }

    private func login(_ provider: String) {
        error = nil
        loginBusy = true
        Task {
            defer { loginBusy = false }
            do {
                let origin = ServerConfiguration.defaultOrigin
                let pkce = try OAuthPKCE.generate()
                let callback = try await oauth.authenticate(pkce.startURL(origin: origin, provider: provider))
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
}

struct WeijiLoginMark: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Theme.active)
                .frame(width: 58, height: 58)
                .weijiGlassCircle(tint: Theme.green.opacity(0.32), interactive: false)
                .accessibilityHidden(true)
            Text("微记").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        }
    }
}
