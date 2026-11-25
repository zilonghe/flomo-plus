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

    private var cursorIndex: String.Index {
        guard let selection else { return draft.endIndex }
        switch selection.indices {
        case .selection(let range):
            return min(range.upperBound, draft.endIndex)
        case .multiSelection(let ranges):
            return min(ranges.ranges.last?.upperBound ?? draft.endIndex, draft.endIndex)
        @unknown default:
            return draft.endIndex
        }
    }

    private var activeTag: TagParser.ActiveTagQuery? {
        TagParser.activeTagQuery(in: draft, cursor: cursorIndex)
    }

    private var suggestions: [String] {
        guard let activeTag else { return [] }
        return TagParser.suggestTags(for: activeTag.query, from: store.index.exactTags, counts: tagCounts, limit: 10)
    }

    private var canSave: Bool {
        !saving && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft, selection: $selection)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .focused($focused)
                        .accessibilityIdentifier("composer-text-editor")

                    if draft.isEmpty {
                        Text("记下此刻的想法… 输入 # 联想标签")
                            .font(.system(size: 16))
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
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomAccessory }
            .navigationTitle("记一条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("composer-save-button")
                }
            }
            .task { focused = true }
            .sensoryFeedback(.selection, trigger: tagFeedback)
        }
        .tint(Theme.active)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
    }

    private var bottomAccessory: some View {
        VStack(spacing: 0) {
            if let activeTag, !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                applySuggestion(tag, replacing: activeTag.range)
                            } label: {
                                HStack(spacing: 3) {
                                    Text("#").foregroundStyle(Theme.active)
                                    Text(tag).foregroundStyle(Theme.ink)
                                }
                                .font(Theme.TypeScale.meta.weight(.medium))
                                .padding(.horizontal, 11).frame(minHeight: 32)
                                .background(Theme.paper, in: Capsule())
                                .overlay { Capsule().strokeBorder(Theme.hairline) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("composer-tag-suggestion-\(tag)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .background(Theme.canvas)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                Button(action: insertHash) {
                    HStack(spacing: 4) {
                        Image(systemName: "number").font(.system(size: 14, weight: .semibold))
                        Text("标签").font(Theme.TypeScale.meta.weight(.medium))
                    }
                    .foregroundStyle(activeTag != nil ? Theme.active : Theme.ink2)
                    .padding(.horizontal, 12).frame(minHeight: 34)
                    .background(activeTag != nil ? Theme.accentSoft : Theme.subtle, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("插入标签")
                .accessibilityIdentifier("composer-insert-hash")

                if !draft.isEmpty {
                    Text("\(draft.count) 字")
                        .font(Theme.TypeScale.meta.monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                }

                Spacer(minLength: 8)

                Button(action: save) {
                    Label("保存", systemImage: "arrow.up")
                }
                .buttonStyle(.weijiPrimary)
                .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.paper)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .animation(.easeOut(duration: 0.16), value: suggestions)
    }

    private func insertHash() {
        let idx = cursorIndex
        let needsLeadingSpace = idx > draft.startIndex && !draft[draft.index(before: idx)].isWhitespace
        let insert = needsLeadingSpace ? " #" : "#"
        draft.insert(contentsOf: insert, at: idx)
        let newCursor = draft.index(idx, offsetBy: insert.count)
        selection = TextSelection(insertionPoint: newCursor)
        focused = true
        tagFeedback += 1
    }

    private func applySuggestion(_ tag: String, replacing range: Range<String.Index>) {
        let applied = TagParser.applyTagSuggestion(tag, in: draft, replacing: range)
        draft = applied.text
        selection = TextSelection(insertionPoint: applied.cursor)
        focused = true
        tagFeedback += 1
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
