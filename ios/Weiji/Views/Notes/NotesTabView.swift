import SwiftUI

struct NotesTabView: View {
    @Bindable var store: AppStore
    let noteZoom: Namespace.ID
    @Binding var sidebar: Bool
    @Binding var showDatePicker: Bool
    @State private var draftDate = Date()
    @State private var searchPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !searchPresented { header }
                NotesList(store: store, noteZoom: noteZoom, sidebar: sidebar, activateSearch: { searchPresented = true })
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbarVisibility(searchPresented ? .visible : .hidden, for: .navigationBar)
            .searchable(text: $store.query, isPresented: $searchPresented,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
        }
        .onChange(of: store.tab) { _, tab in if tab != .notes { searchPresented = false } }
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
        .onChange(of: showDatePicker) { _, open in
            if open { draftDate = store.filter.day.flatMap { Self.dayFormatter.date(from: $0) } ?? .now }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            IconAction(symbol: "line.3.horizontal", label: "笔记菜单", id: "notes-menu-button") { sidebar = true }
            Spacer(minLength: 0)
            SpaceSwitcher(store: store)
            Spacer(minLength: 0)
            IconAction(symbol: "shuffle", label: "随机读", id: "notes-random-walk-button") { store.openRandomRead() }
                .disabled(store.api == nil || store.index.entries.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .accessibilityAction(named: Text("搜索")) { searchPresented = true }
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
        .tint(Theme.ink)
    }

    static var dayFormatter: DateFormatter {
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
    let activateSearch: () -> Void
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch
    @State private var atTop = true

    var body: some View {
        VStack(spacing: 0) {
            if store.isOffline {
                Text("离线 · 仅可浏览已同步笔记")
                    .font(.footnote).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
            }
            if store.filter != NoteFilter() { filterLine }
            InlineError(message: store.error).padding(.horizontal, 24)
            stream
        }
        .onChange(of: sidebar) { _, open in if open && isSearching { dismissSearch() } }
    }

    private var stream: some View {
        let calendar = Calendar.current
        let formatter = NotesTabView.dayFormatter
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        let notes = store.results.prefix(store.pageSize)
        let grouped = Dictionary(grouping: notes) { note in
            (iso.date(from: note.createdAt) ?? seconds.date(from: note.createdAt))
                .map { formatter.string(from: $0) } ?? String(note.createdAt.prefix(10))
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 44) {
                if notes.isEmpty && !store.syncing {
                    Text("暂无笔记").foregroundStyle(Theme.ink2)
                        .frame(maxWidth: .infinity).padding(.top, 48)
                }
                ForEach(grouped.keys.sorted(by: >), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(dayTitle(day, formatter: formatter, calendar: calendar))
                            .font(.footnote).tracking(0.5).foregroundStyle(Theme.ink2)
                            .accessibilityAddTraits(.isHeader)
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ForEach(grouped[day] ?? []) { note in
                                Button {
                                    Task { await store.openNote(note.id, from: .notes) }
                                } label: {
                                    NoteCardContent(note: note)
                                        .frame(maxWidth: .infinity, alignment: .leading).minTapHeight()
                                }
                                .buttonStyle(.plain)
                                .environment(\.openURL, OpenURLAction { url in
                                    guard let tag = TagParser.tagPath(from: url) else { return .systemAction }
                                    store.openTag(tag)
                                    return .handled
                                })
                                .matchedTransitionSource(id: NoteZoomID(source: .notes, id: note.id), in: noteZoom)
                                .accessibilityIdentifier("note-card-" + note.id)
                                .onAppear { store.loadMore(after: note.id) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 640).padding(.horizontal, 24)
            .padding(.top, 16).padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top < 1
        } action: { _, isTop in atTop = isTop }
        .simultaneousGesture(DragGesture().onEnded { value in
            let y = value.translation.height
            guard atTop, !sidebar, !isSearching, y > abs(value.translation.width) else { return }
            if y >= 100 { refresh() }
            else if y >= 24 { activateSearch() }
        })
        .accessibilityAction(named: Text("搜索"), activateSearch)
        .refreshable { refresh() }
        .overlay(alignment: .bottomTrailing) {
            if store.api != nil && store.deletedUndoNote == nil {
                Button { store.showComposer = true } label: {
                    Image(systemName: "plus").font(.title2.weight(.medium))
                        .foregroundStyle(Theme.inverseText)
                        .frame(width: 54, height: 54)
                        .background { Circle().fill(Theme.inverseBg).shadow(color: .black.opacity(0.14), radius: 8, y: 4) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("记一条")
                .accessibilityIdentifier("notes-fab-new")
                .padding(.trailing, 24).padding(.bottom, 16)
            }
        }
    }

    private func refresh() {
        if !store.syncing { store.refresh() }
    }

    private func dayTitle(_ day: String, formatter: DateFormatter, calendar: Calendar) -> String {
        guard let date = formatter.date(from: day) else { return day }
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return day }
        let prefix = year == calendar.component(.year, from: .now) ? "" : "\(year)年"
        return "\(prefix)\(month)月\(day)日"
    }

    private var filterLine: some View {
        let titles = NoteFilter.Dimension.allCases.compactMap { $0.label(in: store.filter) }
        return HStack {
            Text("筛选：" + titles.joined(separator: " · "))
                .font(.footnote).foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { store.filter = NoteFilter() } label: {
                Text("清除").font(.subheadline).foregroundStyle(Theme.ink).fixedSize().minTouchTarget()
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }

}

struct NoteCardContent: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.highlightingTags(note.body, linkTags: true))
                .font(.callout).foregroundStyle(Theme.ink)
                .lineSpacing(6).lineLimit(4).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, note.reading == nil ? 0 : 13)
                .overlay(alignment: .leading) {
                    if note.reading != nil {
                        Rectangle().fill(Theme.quoteBar).frame(width: 1.5).accessibilityHidden(true)
                    }
                }
            if let book = note.reading?.bookTitle, !book.isEmpty {
                Text("《\(book)》").font(.footnote).tracking(0.5).foregroundStyle(Theme.ink2)
                    .padding(.leading, 13)
            }
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
