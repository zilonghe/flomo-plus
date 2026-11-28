import SwiftUI

struct QuickComposerSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var selection: TextSelection?
    @State private var id = UUID().uuidString.lowercased()
    @State private var timestamp = AppStore.timestamp()
    @State private var saving = false
    @State private var error: String?

    private var canSave: Bool {
        !saving && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft, selection: $selection)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .focused($focused)
                        .accessibilityIdentifier("composer-text-editor")

                    if draft.isEmpty {
                        Text("记下此刻的想法…")
                            .font(.body)
                            .foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 19)
                            .padding(.top, 16)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let error {
                    InlineError(message: error)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                }
            }
            .background(Theme.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NoteTagAccessoryBar(store: store, draft: $draft, selection: $selection, refocus: { focused = true })
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("取消").font(.subheadline).foregroundStyle(Theme.ink2).minTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    Spacer()
                    Button(action: save) {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Theme.accent.opacity(canSave ? 1 : 0.35), in: Circle())
                            .minTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .accessibilityLabel("发送")
                    .accessibilityIdentifier("composer-save-button")
                }
                .padding(.horizontal, 14)
                .background(Theme.canvas)
            }
            .task { focused = true }
        }
        .tint(Theme.ink)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
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

struct NoteTagAccessoryBar: View {
    let store: AppStore
    @Binding var draft: String
    @Binding var selection: TextSelection?
    let refocus: () -> Void
    @State private var tagFeedback = 0

    private var tagCounts: [String: Int] {
        var result: [String: Int] = [:]
        func walk(_ nodes: [TagParser.Node]) {
            for node in nodes {
                result[node.path] = node.count
                walk(node.children)
            }
        }
        walk(store.index.tags)
        return result
    }

    private var cursorIndex: String.Index? {
        guard let selection else { return draft.endIndex }
        switch selection.indices {
        case .selection(let range):
            guard range.lowerBound == range.upperBound, range.upperBound <= draft.endIndex else { return nil }
            return range.upperBound
        case .multiSelection:
            return nil
        @unknown default:
            return draft.endIndex
        }
    }

    private var activeTag: TagParser.ActiveTagQuery? {
        guard let cursor = cursorIndex else { return nil }
        return TagParser.activeTagQuery(in: draft, cursor: cursor)
    }

    var body: some View {
        let activeTag = activeTag
        let suggestions = activeTag.map {
            TagParser.suggestTags(for: $0.query, from: store.index.exactTags, counts: tagCounts, limit: 10)
        } ?? []
        VStack(spacing: 0) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                applySuggestion(tag)
                            } label: {
                                HStack(spacing: 3) {
                                    Text("#").foregroundStyle(Theme.active)
                                    Text(tag).foregroundStyle(Theme.ink)
                                }
                                .font(Theme.TypeScale.meta.weight(.medium))
                                .padding(.horizontal, 8).minTouchTarget()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("composer-tag-suggestion-\(tag)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .background(Theme.paper)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        }
        .animation(.easeOut(duration: 0.16), value: suggestions)
        .sensoryFeedback(.selection, trigger: tagFeedback)
    }

    private func applySuggestion(_ tag: String) {
        guard let cursor = cursorIndex,
              let current = TagParser.activeTagQuery(in: draft, cursor: cursor) else { return }
        let applied = TagParser.applyTagSuggestion(tag, in: draft, replacing: current.range)
        draft = applied.text
        selection = TextSelection(insertionPoint: applied.cursor)
        refocus()
        tagFeedback += 1
    }
}
