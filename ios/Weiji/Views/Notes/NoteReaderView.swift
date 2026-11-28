import SwiftUI

struct NoteReaderStack: Equatable {
    private(set) var ids: [String] = []

    mutating func push(_ id: String) {
        ids.append(id)
    }

    func hasLiveEntry(in notesById: [String: Note]) -> Bool {
        ids.contains { notesById[$0] != nil }
    }

    mutating func popLive(in notesById: [String: Note]) -> Note? {
        while let id = ids.popLast() {
            if let note = notesById[id] { return note }
        }
        return nil
    }

    mutating func prune(using notesById: [String: Note]) {
        ids.removeAll { notesById[$0] == nil }
    }
}

struct NoteReaderView: View {
    let store: AppStore
    let source: DetailSource

    @State private var displayedNote: Note
    @State private var backStack = NoteReaderStack()
    private var isRandomMode: Bool { source == .walk }
    @ScaledMetric(relativeTo: .body) private var readerFontSize: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: AppStore, note: Note, source: DetailSource) {
        self.store = store
        self.source = source
        _displayedNote = State(initialValue: note)
    }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NoteDraft?
    @State private var selection: TextSelection?
    @State private var error: String?
    @State private var saving = false
    @State private var confirmingDelete = false
    @FocusState private var editing: Bool

    private var current: Note { store.notesById[displayedNote.id] ?? displayedNote }
    private var isEditingOrSaving: Bool { draft != nil || saving }
    private var canModify: Bool { !saving && store.api != nil && store.notesById[displayedNote.id] != nil }
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
                        .font(.system(size: readerFontSize, design: .serif))
                        .lineSpacing(8)
                        .foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 240)
                        .focused($editing)
                        .disabled(saving)
                        .accessibilityLabel("笔记正文")
                        .accessibilityIdentifier("detail-body-editor")
                } else {
                    readingText
                        .padding(.leading, current.reading == nil ? 0 : 17)
                        .overlay(alignment: .leading) {
                            if current.reading != nil {
                                Rectangle().fill(Theme.quoteBar).frame(width: 1.5).accessibilityHidden(true)
                            }
                        }
                    if let reading = current.reading { attribution(for: reading).padding(.leading, 17) }
                    relatedNotes
                }
                InlineError(message: error)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .id(displayedNote.id)
        .transition(.opacity)
        .background(Theme.canvas.ignoresSafeArea())
        .tint(Theme.ink)
        .environment(\.openURL, OpenURLAction { url in
            guard let tag = TagParser.tagPath(from: url) else { return .systemAction }
            store.openTag(tag)
            return .handled
        })
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if draft != nil {
                NoteTagAccessoryBar(store: store, draft: draftBodyBinding, selection: $selection,
                                    refocus: { editing = true })
                    .disabled(saving)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { readerToolbar.background(Theme.canvas) }
        .interactiveDismissDisabled(isEditingOrSaving)
        .confirmationDialog("删除这条笔记？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: delete)
        }
        .task(id: displayedNote.id) {
            if let api = store.api { store.walk.pivot(to: displayedNote.id, api: api, keepHistory: false) }
        }
        .onChange(of: Set(store.notesById.keys)) { _, _ in
            reconcileDeletedNotes()
        }
    }

    private var readingText: some View {
        Text(NoteCardContent.highlightingTags(current.body, limit: nil, linkTags: true))
            .font(.system(size: readerFontSize, design: .serif))
            .lineSpacing(8)
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func attribution(for reading: Reading) -> some View {
        let title = reading.bookTitle.flatMap { $0.isEmpty ? nil : "《\($0)》" }
        let source = [title, reading.chapter].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !source.isEmpty {
            Text(source).font(.footnote).tracking(0.5).foregroundStyle(Theme.ink2)
        }
    }

    @ViewBuilder
    private var relatedNotes: some View {
        if let result = store.walk.result, result.focus.id == displayedNote.id, !result.related.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("相关笔记").font(.footnote).tracking(0.5).foregroundStyle(Theme.ink2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(result.related.prefix(3)) { item in
                    Button {
                        if let note = store.notesById[item.id] { navigate(to: note) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.note.body).font(.callout).foregroundStyle(Theme.ink).lineLimit(2)
                            Text(item.note.reading?.bookTitle.map { "《\($0)》" } ?? String(item.note.createdAt.prefix(10)))
                                .font(.footnote).foregroundStyle(Theme.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).minTapHeight()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 20)
        }
    }

    private func navigate(to note: Note, push: Bool = true) {
        if push { backStack.push(displayedNote.id) }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            displayedNote = note
            error = nil
        }
    }

    private func reconcileDeletedNotes() {
        backStack.prune(using: store.notesById)
        guard store.notesById[displayedNote.id] == nil, draft == nil, !saving else { return }
        if let fallback = backStack.popLive(in: store.notesById) {
            navigate(to: fallback, push: false)
        } else {
            dismiss()
        }
    }

    @ViewBuilder
    private var conflictCard: some View {
        if let latest = store.notesById[displayedNote.id] {
            VStack(alignment: .leading, spacing: 8) {
                Text("云端版本已更新").font(.footnote.weight(.semibold)).foregroundStyle(Theme.danger)
                Text(latest.body).font(.subheadline)
                    .accessibilityIdentifier("detail-conflict-server-body")
                Button("保留草稿，使用云端版本继续编辑") {
                    draft?.review(latest)
                    error = nil
                }
                .buttonStyle(.weijiPrimary)
            }
        } else {
            Text("这条笔记已在云端删除。").foregroundStyle(Theme.ink2)
        }
    }

    private var readerToolbar: some View {
        HStack(spacing: 4) {
            if let draft {
                toolbarText("取消", color: Theme.ink2) {
                    editing = false
                    self.draft = nil
                    selection = nil
                    error = nil
                    reconcileDeletedNotes()
                }
                .disabled(saving)
                Spacer()
                toolbarText("保存", bold: true) { save(draft) }
                    .disabled(saving || draft.conflict || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("detail-save-button")
            } else {
                if !backStack.hasLiveEntry(in: store.notesById) {
                    IconAction(symbol: "xmark", label: "关闭", id: "detail-close-button") { dismiss() }
                        .disabled(saving)
                } else {
                    Button {
                        if let note = backStack.popLive(in: store.notesById) {
                            navigate(to: note, push: false)
                        } else {
                            dismiss()
                        }
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label("返回", systemImage: "chevron.left").fixedSize()
                            Image(systemName: "chevron.left")
                        }
                        .foregroundStyle(Theme.ink).minTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                    .disabled(saving)
                }
                Spacer(minLength: 0)
                if isRandomMode {
                    toolbarText("换一条") {
                        if let note = store.walk.randomNote(in: store.index, excluding: displayedNote.id) {
                            navigate(to: note)
                        }
                    }
                    .disabled(saving || store.api == nil || store.index.entries.count < 2)
                }
                toolbarText("编辑") {
                    draft = NoteDraft(note: current)
                    selection = nil
                    error = nil
                    editing = true
                }
                .disabled(!canModify)
                .accessibilityIdentifier("detail-edit-button")
                Menu {
                    primaryButton
                    Button("复制全文", systemImage: "doc.on.doc") { UIPasteboard.general.string = current.body }
                    ShareLink(item: current.body) { Label("分享", systemImage: "square.and.arrow.up") }
                    Button("删除笔记", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(!canModify)
                        .accessibilityIdentifier("detail-delete-button")
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.ink).minTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多操作")
            }
        }
        .padding(.horizontal, 14)
    }

    private func toolbarText(_ title: String, color: Color = Theme.ink, bold: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(bold ? .semibold : .regular))
                .foregroundStyle(color).fixedSize(horizontal: false, vertical: true).minTouchTarget()
        }
        .buttonStyle(.plain)
    }

    private var primaryButton: some View {
        Button {
            store.performReaderPrimaryAction(for: current, source: source)
        } label: {
            let isPinned = store.chat.pins.contains(current.id)
            let title = source == .ai ? (isPinned ? "移出引用" : "加入引用") : "问 AI"
            let icon = source == .ai ? (isPinned ? "pin.slash" : "pin") : "bubble.left"
            // The bottom bar otherwise reduces a Label to its icon, hiding the pin action's state.
            HStack(spacing: 6) {
                Image(systemName: icon).accessibilityHidden(true)
                Text(title)
            }
        }
        .disabled(saving || !store.canPerformReaderPrimaryAction(for: current.id, source: source))
        .sensoryFeedback(.selection, trigger: store.chat.pins.contains(current.id)) { _, _ in source == .ai }
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
