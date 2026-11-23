import SwiftUI

struct NoteDetailSheet: View {
    let store: AppStore
    let note: Note
    var onAsk: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NoteDraft?
    @State private var error: String?
    @State private var saving = false
    @State private var confirmingDelete = false
    @FocusState private var editing: Bool

    private var current: Note { store.notesById[note.id] ?? note }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(current.reading?.bookTitle ?? String(current.createdAt.prefix(10)))
                        .font(.caption).foregroundStyle(.secondary)
                    if draft != nil {
                        TextField("笔记正文", text: Binding(get: { draft?.body ?? "" }, set: { draft?.body = $0 }), axis: .vertical)
                            .lineLimit(5...).focused($editing)
                            .accessibilityIdentifier("detail-body-editor")
                        if draft?.conflict == true {
                            Text("云端版本已更新，以下是最新正文。你的草稿仍保留在上方。")
                                .font(.footnote).foregroundStyle(.red)
                            if let latest = store.notesById[note.id] {
                                Text(latest.body).noteCard()
                                Button("保留草稿，使用云端版本继续编辑") {
                                    draft?.review(latest)
                                    error = nil
                                }
                            } else {
                                Text("这条笔记已在云端删除。").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(current.body).font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            dismiss()
                            if let onAsk { onAsk() } else { store.askAbout(current) }
                        } label: {
                            Label("与 AI 聊这条", systemImage: "bubble.left")
                        }
                        .accessibilityIdentifier("detail-ask-ai-button")
                        Button("删除笔记", role: .destructive) { confirmingDelete = true }
                            .accessibilityIdentifier("detail-delete-button")
                            .disabled(saving || store.notesById[note.id] == nil)
                    }
                    InlineError(message: error)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
            .navigationTitle("笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.accessibilityIdentifier("detail-close-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let draft {
                        Button("保存") { save(draft) }
                            .disabled(saving || draft.conflict || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("detail-save-button")
                    } else {
                        Button("编辑") {
                            draft = NoteDraft(note: current)
                            error = nil
                            editing = true
                        }
                        .disabled(saving || store.notesById[note.id] == nil)
                        .accessibilityIdentifier("detail-edit-button")
                    }
                }
            }
            .confirmationDialog("删除这条笔记？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive, action: delete)
            }
        }
        .interactiveDismissDisabled(draft != nil || saving)
    }

    private func save(_ pending: NoteDraft) {
        saving = true
        editing = false
        Task {
            defer { saving = false }
            do {
                try await store.update(pending.base, body: pending.body)
                draft = nil
                error = nil
            } catch is CancellationError {
            } catch {
                draft?.failed(error)
                self.error = draft?.conflict == true ? nil : error.localizedDescription
            }
        }
    }

    private func delete() {
        saving = true
        let base = current
        Task {
            defer { saving = false }
            do { try await store.delete(base); dismiss() }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}
