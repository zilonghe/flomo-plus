import SwiftUI

struct ConnectionSettingsDraft {
    private(set) var address: String
    var token: String
    private var tokenOrigin: String?

    init(configuration: ServerConfiguration?) {
        address = configuration?.origin ?? "http://10.199.197.116:5173"
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

    init(store: AppStore) {
        self.store = store
        var draft = ConnectionSettingsDraft(configuration: store.configuration)
        draft.setAddress(draft.address, savedToken: store.savedConnectionToken(for:))
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("自托管服务") {
                    TextField("服务器地址", text: Binding(get: { draft.address }, set: {
                        draft.setAddress($0, savedToken: store.savedConnectionToken(for:))
                    }))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("访问令牌", text: $draft.token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("测试并连接", action: connect).disabled(store.syncing)
                    if store.syncing { ProgressView("正在连接") }
                    if let user = store.identity?.user { LabeledContent("账户", value: user.name) }
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
            }
            .navigationTitle("连接设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .onAppear {
                if store.api != nil { updateIndex(rebuild: false) }
            }
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
}
