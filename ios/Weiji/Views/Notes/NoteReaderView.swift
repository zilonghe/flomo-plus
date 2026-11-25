import SwiftUI

struct NoteReaderView: View {
    enum Presentation { case fullScreen, pushed }

    let store: AppStore
    let note: Note
    let source: DetailSource
    let presentation: Presentation
    var isEditing: Binding<Bool>? = nil
    var onAsk: (() -> Void)? = nil
    var onOpenTag: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var draft: NoteDraft?
    @State private var selection: TextSelection?
    @State private var error: String?
    @State private var saving = false
    @State private var confirmingDelete = false
    @FocusState private var editing: Bool

    private var current: Note { store.notesById[note.id] ?? note }
    private var isEditingOrSaving: Bool { draft != nil || saving }
    private var canModify: Bool { !saving && store.api != nil && store.notesById[note.id] != nil }
    private var draftBodyBinding: Binding<String> {
        Binding(get: { draft?.body ?? "" }, set: { draft?.body = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(NoteDateFormatter.fullDisplay(from: current.createdAt))
                    .font(.footnote).monospacedDigit().foregroundStyle(Theme.ink3)
                if let draft {
                    if draft.conflict { conflictCard }
                    TextEditor(text: draftBodyBinding, selection: $selection)
                        .font(.system(size: 18, design: .serif))
                        .lineSpacing(8)
                        .foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 240)
                        .focused($editing)
                        .disabled(saving)
                        .accessibilityLabel("笔记正文")
                        .accessibilityIdentifier("detail-body-editor")
                } else {
                    if let reading = current.reading {
                        HStack(alignment: .top, spacing: 14) {
                            Capsule().fill(Theme.green).frame(width: 2).accessibilityHidden(true)
                            readingText
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        attribution(for: reading)
                    } else {
                        readingText
                    }
                }
                InlineError(message: error)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .tint(Theme.active)
        .environment(\.openURL, OpenURLAction { url in
            guard let tag = TagParser.tagPath(from: url) else { return .systemAction }
            if let onOpenTag { onOpenTag(tag) } else { store.openTag(tag) }
            return .handled
        })
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if draft != nil {
                NoteTagAccessoryBar(store: store, draft: draftBodyBinding, selection: $selection,
                                    refocus: { editing = true }) { EmptyView() }
                    .disabled(saving)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditingOrSaving)
        .interactiveDismissDisabled(isEditingOrSaving)
        .toolbar(draft == nil ? .visible : .hidden, for: .bottomBar)
        .toolbar { readerToolbar }
        .confirmationDialog("删除这条笔记？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: delete)
        }
        .onChange(of: isEditingOrSaving, initial: true) { _, value in isEditing?.wrappedValue = value }
        .onDisappear { isEditing?.wrappedValue = false }
    }

    private var readingText: some View {
        Text(NoteCardContent.highlightingTags(current.body, limit: nil, linkTags: true))
            .font(.system(size: 18, design: .serif))
            .lineSpacing(8)
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func attribution(for reading: Reading) -> some View {
        let title = reading.bookTitle.flatMap { $0.isEmpty ? nil : "《\($0)》" }
        let book = [title, reading.author].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let source = [reading.chapter, reading.sourceDate].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !book.isEmpty || !source.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Theme.line).frame(width: 32, height: 1).accessibilityHidden(true)
                if !book.isEmpty { Text(book).font(.subheadline).foregroundStyle(Theme.ink2) }
                if !source.isEmpty { Text(source).font(.footnote).foregroundStyle(Theme.ink3) }
            }
        }
    }

    @ViewBuilder
    private var conflictCard: some View {
        if let latest = store.notesById[note.id] {
            VStack(alignment: .leading, spacing: 8) {
                Text("云端版本已更新").font(.footnote.weight(.semibold)).foregroundStyle(.red)
                Text(latest.body).font(.subheadline)
                    .accessibilityIdentifier("detail-conflict-server-body")
                Button("保留草稿，使用云端版本继续编辑") {
                    draft?.review(latest)
                    error = nil
                }
                .buttonStyle(.weijiPrimary)
            }.noteCard()
        } else {
            Text("这条笔记已在云端删除。").foregroundStyle(Theme.ink2)
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if draft != nil {
                Button("取消") {
                    editing = false
                    draft = nil
                    selection = nil
                    error = nil
                }
                .disabled(saving)
            } else if presentation == .fullScreen {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("关闭")
                    .accessibilityIdentifier("detail-close-button")
                    .disabled(saving)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if let draft {
                Button("保存") { save(draft) }
                    .fontWeight(.semibold)
                    .disabled(saving || draft.conflict || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("detail-save-button")
            } else {
                Menu {
                    Button("复制全文", systemImage: "doc.on.doc") { UIPasteboard.general.string = current.body }
                    ShareLink(item: current.body) { Label("分享", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button("删除笔记", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(!canModify)
                        .accessibilityIdentifier("detail-delete-button")
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多操作")
            }
        }
        if draft == nil {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    draft = NoteDraft(note: current)
                    selection = nil
                    error = nil
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(!canModify)
                .accessibilityLabel("编辑")
                .accessibilityIdentifier("detail-edit-button")
                Spacer()
                primaryButton
            }
        }
    }

    private var primaryButton: some View {
        Button {
            if source != .ai, let onAsk { onAsk() }
            else { store.performReaderPrimaryAction(for: current, source: source) }
        } label: {
            let isPinned = store.chat.pins.contains(current.id)
            let title = source == .ai ? (isPinned ? "移出引用" : "加入引用") : "聊这条"
            let icon = source == .ai ? (isPinned ? "pin.slash" : "pin") : "bubble.left"
            // The bottom bar otherwise reduces a Label to its icon, hiding the pin action's state.
            HStack(spacing: 6) {
                Image(systemName: icon).accessibilityHidden(true)
                Text(title)
            }
        }
        .disabled(saving || !store.canPerformReaderPrimaryAction(for: current.id, source: source))
        .accessibilityIdentifier("detail-ask-ai-button")
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
