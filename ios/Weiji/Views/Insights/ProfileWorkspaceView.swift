import SwiftUI

struct ProfileWorkspaceView: View {
    let store: AppStore
    @State private var draft = ""
    @State private var editing = false
    @State private var confirmClear = false
    private var insights: InsightsStore { store.insights }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("对话时结合个人画像", isOn: Binding(
                    get: { insights.profile?.enabled == true },
                    set: { enabled in
                        if let api = store.api { insights.saveProfile(ProfileEdit(enabled: enabled), api: api) }
                    }
                ))
                .tint(Theme.inverseBg)
                .disabled(insights.savingProfile || insights.generatingProfile || store.api == nil)
                .minTapHeight()
                .accessibilityIdentifier("profile-enable-toggle")
                Rectangle().fill(Theme.hairline).frame(height: 1)

                InlineError(message: insights.profileError)
                if editing {
                    TextField("个人画像", text: $draft, axis: .vertical)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(8...)
                        .onChange(of: draft) { _, value in
                            if value.utf16.count > 6000 { draft = clippedUTF16(value, to: 6000) }
                        }
                    HStack {
                        action("取消") { editing = false }.disabled(insights.savingProfile)
                        Spacer()
                        action("保存") { save() }
                            .disabled(insights.savingProfile)
                            .accessibilityIdentifier("profile-save-button")
                    }
                } else {
                    Text(insights.profileText.isEmpty ? "暂无个人画像" : insights.profileText)
                        .font(.body).foregroundStyle(insights.profileText.isEmpty ? Theme.ink2 : Theme.ink)
                        .lineSpacing(6).textSelection(.enabled)
                    if insights.generatingProfile {
                        action("停止") { insights.stopProfile() }.accessibilityIdentifier("profile-stop-button")
                    } else {
                        action("编辑") { draft = insights.profileText; editing = true }
                            .disabled(insights.savingProfile || store.api == nil)
                            .accessibilityIdentifier("profile-edit-button")
                        action("重新生成") {
                            if let api = store.api { insights.generateProfile(api: api, options: store.options) }
                        }
                        .disabled(insights.savingProfile || store.api == nil)
                        .accessibilityIdentifier("profile-generate-button")
                        action("清空画像", color: Theme.danger) { confirmClear = true }
                            .disabled(insights.savingProfile || store.api == nil || insights.profileText.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .confirmationDialog("清空个人画像？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空画像", role: .destructive) {
                if let api = store.api { insights.saveProfile(ProfileEdit(content: "", enabled: false), api: api) }
            }
        }
    }

    private func action(_ title: String, color: Color = Theme.ink, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(title).foregroundStyle(color).minTouchTarget() }.buttonStyle(.plain)
    }

    private func save() {
        guard let api = store.api,
              let saving = insights.saveProfile(ProfileEdit(content: draft, enabled: insights.profile?.enabled ?? false), api: api) else { return }
        Task { if await saving.value { editing = false } }
    }
}
