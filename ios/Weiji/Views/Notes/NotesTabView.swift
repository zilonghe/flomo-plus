import SwiftUI

struct NotesTabView: View {
    @Bindable var store: AppStore
    let noteZoom: Namespace.ID
    @Binding var sidebar: Bool
    @Binding var showDatePicker: Bool
    @State private var draftDate = Date()

    var body: some View {
        NavigationStack {
            NotesList(store: store, noteZoom: noteZoom, sidebar: sidebar)
                .background(Theme.canvas.ignoresSafeArea())
                .navigationTitle(store.filter.navigationTitle)
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
                        IconAction(symbol: "gearshape", label: "设置", id: "notes-settings-button") {
                            store.openSettings(.general)
                        }
                    }
                }
        }
        .searchable(text: $store.query, prompt: "搜索笔记、书名、作者")
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
        .onChange(of: showDatePicker) { _, open in
            if open { draftDate = store.filter.day.flatMap { Self.dayFormatter.date(from: $0) } ?? .now }
        }
    }

    private var datePickerSheet: some View {
        NavigationStack {
            ScrollView {
                DatePicker("按日期筛选", selection: $draftDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
            }
            .weijiSheetBackground()
            .navigationTitle("按日期筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showDatePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("筛选") {
                        store.filter.day = Self.dayFormatter.string(from: draftDate)
                        showDatePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(Theme.active)
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

}

extension NoteFilter {
    enum Dimension: CaseIterable {
        case kind, tag, day

        func label(in filter: NoteFilter) -> String? {
            switch self {
            case .kind: return filter.kind == .all ? nil : filter.kind.rawValue
            case .tag: return filter.tag.map { "#" + $0 }
            case .day: return filter.day
            }
        }
    }

    var navigationTitle: String {
        let active = Dimension.allCases.compactMap { $0.label(in: self) }
        return active.count > 1 ? "筛选结果" : (active.first ?? "笔记")
    }

    mutating func clear(_ dimension: Dimension) {
        switch dimension {
        case .kind: kind = .all
        case .tag: tag = nil
        case .day: day = nil
        }
    }
}

private struct NotesList: View {
    let store: AppStore
    let noteZoom: Namespace.ID
    let sidebar: Bool
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
                filterChips
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
                if store.api != nil {
                    Button {
                        store.showComposer = true
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
    }

    private var filterChips: some View {
        let active = NoteFilter.Dimension.allCases.filter { $0.label(in: store.filter) != nil }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(active, id: \.self) { dimension in
                    if let title = dimension.label(in: store.filter) {
                        Button { store.filter.clear(dimension) } label: {
                            Chip(text: title, symbol: "xmark", selected: true).minTouchTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除 \(title)")
                    }
                }
                if active.count > 1 {
                    Button { store.filter = NoteFilter() } label: {
                        Chip(text: "清除全部").minTouchTarget()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 6)
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
