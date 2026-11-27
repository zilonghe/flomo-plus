import SwiftUI

struct NotesTabView: View {
    @Bindable var store: AppStore
    let noteZoom: Namespace.ID
    @Binding var sidebar: Bool

    var body: some View {
        NavigationStack {
            NotesList(store: store, noteZoom: noteZoom, sidebar: sidebar)
                .background(Theme.canvas.ignoresSafeArea())
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        IconAction(symbol: "line.3.horizontal", label: "笔记菜单", id: "notes-menu-button") {
                            sidebar = true
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if store.syncing {
                            ProgressView().controlSize(.small).accessibilityLabel("正在同步")
                        }
                        IconAction(symbol: "arrow.clockwise", label: "同步", id: "notes-sync-button") { store.refresh() }
                            .disabled(store.syncing)
                    }
                }
        }
        .searchable(text: $store.query, prompt: "搜索笔记、书名、作者")
    }

    private var navigationTitle: String {
        if let tag = store.filter.tag { return "#" + tag }
        if let day = store.filter.day { return day }
        return store.filter == NoteFilter() ? "笔记" : store.filter.kind.rawValue
    }
}

private struct NotesList: View {
    let store: AppStore
    let noteZoom: Namespace.ID
    let sidebar: Bool
    @State private var composer = false
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        VStack(spacing: 0) {
            if store.isOffline {
                Label("离线 · 仅可浏览已同步笔记", systemImage: "wifi.slash")
                    .font(.footnote).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtle, in: .rect(cornerRadius: 10))
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
            if store.filter != NoteFilter() {
                Button {
                    store.filter = NoteFilter()
                } label: {
                    Chip(text: store.filter.tag.map { "#" + $0 } ?? store.filter.day ?? store.filter.kind.rawValue,
                         symbol: "xmark", selected: true)
                        .minTapHeight()
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
                            Task { await store.openNote(note.id, from: .notes) }
                        } label: {
                            NoteCardContent(note: note).noteCard(padding: 16)
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: NoteZoomID(source: .notes, id: note.id), in: noteZoom)
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
                if !isSearching && store.api != nil {
                    Button {
                        composer = true
                    } label: {
                        Image(systemName: "plus").font(.title2.weight(.semibold))
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
        .onChange(of: sidebar) { _, open in if open && isSearching { dismissSearch() } }
        .sheet(isPresented: $composer) { QuickComposerSheet(store: store) }
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
