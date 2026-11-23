import SwiftUI

struct ProfileWorkspaceView: View {
    let store: AppStore
    @State private var draft = ""
    @State private var editing = false
    private var insights: InsightsStore { store.insights }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if let api = store.api {
                        insights.saveProfile(ProfileEdit(enabled: !(insights.profile?.enabled ?? false)), api: api)
                    }
                } label: {
                    Label(insights.profile?.enabled == true ? "已启用" : "未启用",
                          systemImage: insights.profile?.enabled == true ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.bordered)
                .disabled(insights.savingProfile || insights.generatingProfile || store.api == nil)
                .accessibilityIdentifier("profile-enable-toggle")
                Spacer()
                if insights.generatingProfile {
                    Button("停止") { insights.stopProfile() }.accessibilityIdentifier("profile-stop-button")
                } else if editing {
                    Button("取消") { editing = false }.disabled(insights.savingProfile)
                    Button("保存", action: save)
                        .disabled(insights.savingProfile || draft.utf16.count > 6000)
                        .accessibilityIdentifier("profile-save-button")
                } else {
                    Button("编辑") { draft = insights.profileText; editing = true }
                        .disabled(insights.savingProfile || store.api == nil)
                        .accessibilityIdentifier("profile-edit-button")
                    Button("生成") {
                        if let api = store.api { insights.generateProfile(api: api, options: store.options) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(insights.savingProfile || store.api == nil)
                    .accessibilityIdentifier("profile-generate-button")
                }
            }.screenHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    InlineError(message: insights.profileError)
                    if editing {
                        TextField("画像 Markdown", text: $draft, axis: .vertical)
                            .lineLimit(10...).font(.system(.body, design: .monospaced))
                            .onChange(of: draft) { _, value in
                                if value.utf16.count > 6000 { draft = clippedUTF16(value, to: 6000) }
                            }
                        Text("\(draft.utf16.count)/6000").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else if !insights.profileText.isEmpty {
                        MarkdownBlockView(text: insights.profileText)
                    } else if insights.generatingProfile {
                        ProgressView("正在生成画像")
                    } else {
                        Text("暂无个人画像").foregroundStyle(.secondary)
                    }
                }.noteCard().padding(16)
            }
        }
        .task { if let api = store.api { await insights.loadProfile(api: api) } }
    }

    private func save() {
        guard let api = store.api,
              let saving = insights.saveProfile(ProfileEdit(content: draft, enabled: insights.profile?.enabled ?? false), api: api) else { return }
        Task { if await saving.value { editing = false } }
    }
}
