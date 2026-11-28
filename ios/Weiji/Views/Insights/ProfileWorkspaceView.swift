import SwiftUI

struct ProfileWorkspaceView: View {
    private enum Pane { case bio, style }

    let store: AppStore
    @State private var pane = Pane.bio
    @State private var draft = ""
    @State private var editing = false
    private var insights: InsightsStore { store.insights }

    var body: some View {
        VStack(spacing: 0) {
            Picker("画像与风格", selection: $pane) {
                Text("个人画像").tag(Pane.bio)
                Text("写作风格").tag(Pane.style)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            if pane == .bio { biography }
            else { WritingStyleWorkspaceView(store: store) }
        }
    }

    private var biography: some View {
        let enabled = insights.profile?.enabled == true
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Button {
                        if let api = store.api {
                            insights.saveProfile(ProfileEdit(enabled: !enabled), api: api)
                        }
                    } label: {
                        Chip(text: enabled ? "已启用" : "未启用",
                             symbol: enabled ? "checkmark.circle.fill" : "circle", selected: enabled)
                            .minTapHeight()
                    }
                    .buttonStyle(.plain)
                    .disabled(insights.savingProfile || insights.generatingProfile || store.api == nil)
                    .accessibilityIdentifier("profile-enable-toggle")
                    Spacer(minLength: 8)
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
                .noteCard(padding: 14, cornerRadius: 16)

                InlineError(message: insights.profileError)

                if editing {
                    VStack(alignment: .trailing, spacing: 8) {
                        TextField("画像 Markdown", text: $draft, axis: .vertical)
                            .lineLimit(10...)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .onChange(of: draft) { _, value in
                                if value.utf16.count > 6000 { draft = clippedUTF16(value, to: 6000) }
                            }
                            .noteCard(padding: 16, cornerRadius: 18)
                        Text("\(draft.utf16.count)/6000")
                            .font(Theme.TypeScale.meta.monospacedDigit())
                            .foregroundStyle(Theme.ink3)
                    }
                } else if !insights.profileText.isEmpty {
                    MarkdownBlockView(text: insights.profileText)
                        .noteCard(padding: 18, cornerRadius: 20)
                } else if insights.generatingProfile {
                    ProgressView("正在生成画像")
                        .font(Theme.TypeScale.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                        .noteCard(padding: 18, cornerRadius: 20)
                } else {
                    VStack(spacing: 8) {
                        Text("暂无个人画像")
                            .font(Theme.TypeScale.itemTitle)
                            .foregroundStyle(Theme.ink)
                        Text("点击「生成」，从历史笔记中提炼你的长期关注点与思维风格。")
                            .font(Theme.TypeScale.meta)
                            .foregroundStyle(Theme.ink2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .noteCard(padding: 18, cornerRadius: 20)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .task { if let api = store.api { await insights.loadProfile(api: api) } }
    }

    private func save() {
        guard let api = store.api,
              let saving = insights.saveProfile(ProfileEdit(content: draft, enabled: insights.profile?.enabled ?? false), api: api) else { return }
        Task { if await saving.value { editing = false } }
    }
}
