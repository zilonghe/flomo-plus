import SwiftUI

struct QuickComposerSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var id = UUID().uuidString.lowercased()
    @State private var timestamp = AppStore.timestamp()
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("记下此刻的想法", text: $draft, axis: .vertical)
                        .lineLimit(4...12).lineSpacing(4).noteCard(padding: 14)
                        .focused($focused)
                        .accessibilityIdentifier("composer-text-editor")
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            Button { appendTag("") } label: { Chip(text: "#") }
                            ForEach(store.index.exactTags.prefix(12), id: \.self) { tag in
                                Button { appendTag(tag) } label: { Chip(text: "#" + tag) }
                            }
                        }
                        .buttonStyle(.plain)
                    }.scrollIndicators(.hidden)
                    InlineError(message: error)
                }.padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle("快速记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("composer-save-button")
                }
            }
            .task { focused = true }
        }
        .tint(Theme.active)
        .interactiveDismissDisabled(saving)
    }

    private func appendTag(_ tag: String) {
        if !draft.isEmpty && draft.last?.isWhitespace != true { draft += " " }
        draft += "#" + tag
        focused = true
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do { try await store.create(draft, id: id, createdAt: timestamp); dismiss() }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}
