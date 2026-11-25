import SwiftUI

struct ProfileWorkspaceView: View {
    let store: AppStore
    @State private var draft = ""
    @State private var editing = false
    private var insights: InsightsStore { store.insights }

    var body: some View {
        let enabled = insights.profile?.enabled == true
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if let api = store.api {
                        insights.saveProfile(ProfileEdit(enabled: !enabled), api: api)
                    }
                } label: {
                    Chip(text: enabled ? "已启用" : "未启用",
                         symbol: enabled ? "checkmark.circle.fill" : "circle", selected: enabled)
                }
                .buttonStyle(.plain)
                .disabled(insights.savingProfile || insights.generatingProfile || store.api == nil)
                .accessibilityIdentifier("profile-enable-toggle")
                Spacer()
                if insights.generatingProfile {
                    Button("停止") { insights.stopProfile() }
                        .buttonStyle(.weijiSecondary)
                        .accessibilityIdentifier("profile-stop-button")
                } else if editing {
                    Button("取消") { editing = false }
                        .buttonStyle(.weijiSecondary)
                        .disabled(insights.savingProfile)
                    Button("保存", action: save)
                        .buttonStyle(.weijiPrimary)
                        .disabled(insights.savingProfile || draft.utf16.count > 6000)
                        .accessibilityIdentifier("profile-save-button")
                } else {
                    Button("编辑") { draft = insights.profileText; editing = true }
                        .buttonStyle(.weijiSecondary)
                        .disabled(insights.savingProfile || store.api == nil)
                        .accessibilityIdentifier("profile-edit-button")
                    Button("生成") {
                        if let api = store.api { insights.generateProfile(api: api, options: store.options) }
                    }
                    .buttonStyle(.weijiPrimary)
                    .disabled(insights.savingProfile || store.api == nil)
                    .accessibilityIdentifier("profile-generate-button")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .zIndex(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    InlineError(message: insights.profileError)
                    if editing {
                        TextField("画像 Markdown", text: $draft, axis: .vertical)
                            .lineLimit(10...).font(.system(.callout, design: .monospaced))
                            .onChange(of: draft) { _, value in
                                if value.utf16.count > 6000 { draft = clippedUTF16(value, to: 6000) }
                            }
                            .noteCard(padding: 14)
                        Text("\(draft.utf16.count)/6000").font(.caption.monospacedDigit()).foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else if !insights.profileText.isEmpty {
                        MarkdownBlockView(text: insights.profileText)
                    } else if insights.generatingProfile {
                        ProgressView("正在生成画像").frame(maxWidth: .infinity).padding(.top, 48)
                    } else {
                        Text("暂无个人画像").foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity).padding(.top, 48)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
            }
            .clipped()
        }
        .task { if let api = store.api { await insights.loadProfile(api: api) } }
    }

    private func save() {
        guard let api = store.api,
              let saving = insights.saveProfile(ProfileEdit(content: draft, enabled: insights.profile?.enabled ?? false), api: api) else { return }
        Task { if await saving.value { editing = false } }
    }
}
