import SwiftUI

struct NotesTabView: View {
    @Bindable var store: AppStore
    let noteZoom: Namespace.ID
    @State private var showSearch = false
    @Binding var sidebar: Bool
    @State private var composer = false
    @FocusState private var searching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header.screenHeader()
            if store.isOffline {
                Label("离线 · 仅可浏览已同步笔记", systemImage: "wifi.slash")
                    .font(.footnote).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtle, in: .rect(cornerRadius: 10))
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
            if showSearch { searchField.transition(.move(edge: .top).combined(with: .opacity)) }
            if store.filter != NoteFilter() {
                Button {
                    store.filter = NoteFilter()
                } label: {
                    Chip(text: store.filter.tag.map { "#" + $0 } ?? store.filter.day ?? store.filter.kind.rawValue,
                         symbol: "xmark", selected: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除筛选")
                .padding(.horizontal, 16).padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            InlineError(message: store.error).padding(.horizontal, 16)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.results.isEmpty && !store.syncing {
                        Text("暂无笔记").foregroundStyle(Theme.ink3).padding(.top, 48)
                    }
                    ForEach(store.results.prefix(store.pageSize)) { note in
                        Button {
                            searching = false
                            Task { await store.openNote(note.id, from: .notes) }
                        } label: {
                            NoteCardContent(note: note).noteCard(padding: 16)
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: note.id, in: noteZoom)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("note-card-" + note.id)
                        .onAppear { store.loadMore(after: note.id) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 96)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { store.refresh() }
            .overlay(alignment: .bottomTrailing) {
                if !searching && store.api != nil {
                    Button {
                        composer = true
                    } label: {
                        Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background {
                                Circle().fill(Theme.accent)
                                    .shadow(color: Theme.accent.opacity(0.32), radius: 12, y: 5)
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快速记")
                    .accessibilityIdentifier("notes-fab-new")
                    .padding(.trailing, 20).padding(.bottom, 12)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showSearch)
        .onChange(of: sidebar) { _, open in if open { searching = false } }
        .sheet(isPresented: $composer) { QuickComposerSheet(store: store) }
    }

    private var header: some View {
        HStack(spacing: 4) {
            IconAction(symbol: "line.3.horizontal", label: "笔记菜单", id: "notes-menu-button") { sidebar = true }
                .padding(.leading, -10)
            Text("微记").font(Theme.TypeScale.pageTitle).foregroundStyle(Theme.ink)
            Spacer()
            if store.syncing { ProgressView().controlSize(.small).accessibilityLabel("正在同步").padding(.trailing, 4) }
            IconAction(symbol: showSearch ? "xmark" : "magnifyingglass", label: "搜索", id: "notes-search-button") {
                showSearch.toggle()
                searching = showSearch
                if !showSearch { store.query = "" }
            }
            IconAction(symbol: "arrow.clockwise", label: "同步", id: "notes-sync-button") { store.refresh() }
                .disabled(store.syncing)
                .padding(.trailing, -10)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Theme.ink3).accessibilityHidden(true)
            TextField("搜索笔记、书名、作者", text: $store.query)
                .focused($searching)
                .submitLabel(.search)
                .onSubmit { searching = false }
                .onChange(of: store.query) { previous, current in
                    if !previous.isEmpty && current.isEmpty { searching = false }
                }
                .accessibilityIdentifier("notes-search-field")
            if !store.query.isEmpty {
                Button { store.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 42)
        .background(Theme.paper, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline).allowsHitTesting(false) }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

struct NoteCardContent: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let book = note.reading?.bookTitle, !book.isEmpty {
                    Image(systemName: "book.closed.fill").font(.caption2).foregroundStyle(Theme.active)
                        .accessibilityHidden(true)
                    Text(book).font(.caption.weight(.medium)).foregroundStyle(Theme.ink2).lineLimit(1)
                    Spacer(minLength: 8)
                }
                Text(String(note.createdAt.prefix(10))).font(.caption.monospacedDigit()).foregroundStyle(Theme.ink3)
            }
            Text(Self.highlightingTags(note.body))
                .font(.callout).foregroundStyle(Theme.ink)
                .lineSpacing(4).lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func highlightingTags(_ body: String, limit: Int? = 400, linkTags: Bool = false) -> AttributedString {
        let text = limit.map { String(body.prefix($0)) } ?? body
        var rich = AttributedString(text)
        for (range, tag) in TagParser.matchRanges(in: text) {
            guard let start = AttributedString.Index(range.lowerBound, within: rich),
                  let end = AttributedString.Index(range.upperBound, within: rich) else { continue }
            rich[start..<end].foregroundColor = Theme.active
            if linkTags { rich[start..<end].link = TagParser.tagURL(for: tag) }
        }
        return rich
    }
}
