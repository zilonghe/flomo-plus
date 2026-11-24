import SwiftUI

struct NotesTabView: View {
    @Bindable var store: AppStore
    @State private var showSearch = false
    @Binding var sidebar: Bool
    @State private var composer = false
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 8) { header } }
                else { header }
            }
            .screenHeader()
            if store.isOffline {
                Label("离线 · 仅可浏览已同步笔记", systemImage: "wifi.slash")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.line.opacity(0.6), in: .rect(cornerRadius: 8))
                    .padding(.horizontal, 16)
            }
            if showSearch {
                TextField("搜索笔记、书名、作者", text: $store.query)
                    .focused($searching)
                    .submitLabel(.search)
                    .onSubmit { searching = false }
                    .onChange(of: store.query) { previous, current in
                        if !previous.isEmpty && current.isEmpty { searching = false }
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 16)
                    .weijiGlassCapsule(interactive: false)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("notes-search-field")
            }
            if store.filter != NoteFilter() {
                Button {
                    store.filter = NoteFilter()
                } label: {
                    Label(store.filter.tag.map { "#" + $0 } ?? store.filter.day ?? store.filter.kind.rawValue, systemImage: "xmark.circle")
                        .font(.footnote).padding(.horizontal, 16).padding(.vertical, 6)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            InlineError(message: store.error).padding(.horizontal, 16)
            ScrollView {
                LazyVStack(spacing: 9) {
                    if store.results.isEmpty && !store.syncing {
                        Text("暂无笔记").foregroundStyle(.secondary).padding(.top, 36)
                    }
                    ForEach(store.results.prefix(store.pageSize)) { note in
                        Button {
                            searching = false
                            Task { await store.openNote(note.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(note.reading?.bookTitle ?? String(note.createdAt.prefix(10)))
                                    .foregroundStyle(.secondary).font(.caption)
                                Text(note.body).font(.subheadline).lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .noteCard()
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("note-card-" + note.id)
                        .onAppear { store.loadMore(after: note.id) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 76)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { store.refresh() }
            .overlay(alignment: .bottomTrailing) {
                if !searching && store.api != nil {
                    Button {
                        composer = true
                    } label: {
                        Image(systemName: "plus").font(.system(size: 25, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 54, height: 54)
                            .weijiGlassCircle(tint: Theme.green.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快速记")
                    .accessibilityIdentifier("notes-fab-new")
                    .padding(18)
                }
            }
        }
        .onChange(of: sidebar) { _, open in if open { searching = false } }
        .sheet(isPresented: $composer) { QuickComposerSheet(store: store) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconAction(symbol: "line.3.horizontal", label: "笔记菜单", id: "notes-menu-button") { sidebar = true }
                .weijiGlassCircle()
            Text("微记").font(.title2.bold())
            Spacer()
            if store.syncing { ProgressView().controlSize(.small).accessibilityLabel("正在同步") }
            HStack(spacing: 0) {
                IconAction(symbol: "magnifyingglass", label: "搜索", id: "notes-search-button") {
                    showSearch.toggle()
                    searching = showSearch
                    if !showSearch { store.query = "" }
                }
                IconAction(symbol: "arrow.clockwise", label: "同步", id: "notes-sync-button") { store.refresh() }
                    .disabled(store.syncing)
            }
            .weijiGlassCapsule()
        }
    }
}

struct NotesDrawer: ViewModifier {
    let store: AppStore
    @Binding var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isOpen)
            .allowsHitTesting(!isOpen)
            .simultaneousGesture(DragGesture().onEnded { value in
                let dx = value.translation.width
                guard store.tab == .notes, value.startLocation.x <= 28,
                      dx > 60, dx > abs(value.translation.height) else { return }
                isOpen = true
            })
            .overlay {
                if isOpen {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.black.opacity(0.28)
                                .ignoresSafeArea()
                                .onTapGesture { isOpen = false }
                                .accessibilityHidden(true)
                                .transition(.opacity)
                            SidebarSheetView(store: store, onClose: { isOpen = false })
                                .frame(width: min(310, geo.size.width * 0.82))
                                .frame(maxHeight: .infinity)
                                .weijiGlassSurface(in: UnevenRoundedRectangle(bottomTrailingRadius: 26, topTrailingRadius: 26))
                                .shadow(color: .black.opacity(0.18), radius: 14, x: 5)
                                .accessibilityAddTraits(.isModal)
                                .accessibilityAction(.escape) { isOpen = false }
                                .transition(.move(edge: .leading))
                        }
                        .simultaneousGesture(DragGesture().onEnded { value in
                            let dx = value.translation.width
                            if dx < -60, -dx > abs(value.translation.height) { isOpen = false }
                        })
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86), value: isOpen)
    }
}
