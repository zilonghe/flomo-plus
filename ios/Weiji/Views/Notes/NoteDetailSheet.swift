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
    private var conflictServerNote: Note? { store.notesById[note.id] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        if let book = current.reading?.bookTitle {
                            Image(systemName: "book.closed").accessibilityHidden(true)
                            Text(book).lineLimit(1)
                            Text("·")
                        }
                        Text(String(current.createdAt.prefix(10))).monospacedDigit()
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.ink3)
                    if draft != nil {
                        TextField("笔记正文", text: Binding(get: { draft?.body ?? "" }, set: { draft?.body = $0 }), axis: .vertical)
                            .lineLimit(5...).lineSpacing(4).focused($editing)
                            .noteCard(padding: 14)
                            .accessibilityIdentifier("detail-body-editor")
                        if draft?.conflict == true {
                            if let latest = conflictServerNote {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("云端版本已更新").font(.footnote.weight(.semibold)).foregroundStyle(.red)
                                    Text(latest.body).font(.subheadline)
                                        .accessibilityIdentifier("detail-conflict-server-body")
                                }.noteCard()
                                Button("保留草稿，使用云端版本继续编辑") {
                                    draft?.review(latest)
                                    error = nil
                                }
                            } else {
                                Text("这条笔记已在云端删除。").foregroundStyle(Theme.ink2)
                            }
                        }
                    } else {
                        Text(current.body).font(.body).lineSpacing(5).foregroundStyle(Theme.ink).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            dismiss()
                            if let onAsk { onAsk() } else { store.askAbout(current) }
                        } label: {
                            Label("与 AI 聊这条", systemImage: "bubble.left")
                        }
                        .buttonStyle(.weijiPrimary)
                        .accessibilityIdentifier("detail-ask-ai-button")
                        .disabled(store.api == nil)
                        .padding(.top, 10)
                        Button("删除笔记", role: .destructive) { confirmingDelete = true }
                            .font(.footnote.weight(.medium))
                            .accessibilityIdentifier("detail-delete-button")
                            .disabled(saving || store.api == nil || store.notesById[note.id] == nil)
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
                        .disabled(saving || store.api == nil || store.notesById[note.id] == nil)
                        .accessibilityIdentifier("detail-edit-button")
                    }
                }
            }
            .confirmationDialog("删除这条笔记？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive, action: delete)
            }
        }
        .tint(Theme.active)
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
