import SwiftUI

struct ConnectionSettingsView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = "http://10.199.197.116:5173"
    @State private var token = ""
    @State private var error: String?
    @State private var semantic: SemanticStatus?
    @State private var indexing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("自托管服务") {
                    TextField("服务器地址", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("访问令牌", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
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
                if let config = store.configuration { address = config.origin; token = config.token }
                if store.api != nil { updateIndex(rebuild: false) }
            }
        }
    }

    private func connect() {
        error = nil
        do { store.connect(try ServerConfiguration(address: address, token: token), save: true) }
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
