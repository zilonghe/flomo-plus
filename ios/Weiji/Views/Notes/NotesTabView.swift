import SwiftUI

struct NotesTabView: View {
    @Bindable var store: AppStore
    @State private var showSearch = false
    @State private var sidebar = false
    @State private var composer = false
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                IconAction(symbol: "line.3.horizontal", label: "笔记菜单", id: "notes-menu-button") { sidebar = true }
                Text("微记").font(.title2.bold())
                Spacer()
                if store.syncing { ProgressView().controlSize(.small).accessibilityLabel("正在同步") }
                IconAction(symbol: "magnifyingglass", label: "搜索", id: "notes-search-button") {
                    showSearch.toggle()
                    searching = showSearch
                    if !showSearch { store.query = "" }
                }
                IconAction(symbol: "arrow.clockwise", label: "同步", id: "notes-sync-button") { store.refresh() }
                    .disabled(store.api == nil || store.syncing)
            }
            .screenHeader()
            if showSearch {
                TextField("搜索笔记、书名、作者", text: $store.query)
                    .focused($searching)
                    .submitLabel(.search)
                    .onSubmit { searching = false }
                    .onChange(of: store.query) { previous, current in
                        if !previous.isEmpty && current.isEmpty { searching = false }
                    }
                    .padding(11)
                    .background(Theme.paper, in: .rect(cornerRadius: 10))
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
                        if store.api == nil {
                            Button("连接微记服务") { store.showSettings = true }.padding(.top, 36)
                        } else {
                            Text("暂无笔记").foregroundStyle(.secondary).padding(.top, 36)
                        }
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
                            .foregroundStyle(Color(red: 0.03, green: 0.19, blue: 0.13))
                            .frame(width: 54, height: 54)
                            .background(Theme.green, in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快速记")
                    .accessibilityIdentifier("notes-fab-new")
                    .padding(18)
                }
            }
        }
        .sheet(isPresented: $sidebar, onDismiss: {
            if connectAfterSidebar { connectAfterSidebar = false; store.showSettings = true }
        }) {
            SidebarSheetView(store: store) { connectAfterSidebar = true; sidebar = false }
        }
        .sheet(isPresented: $composer) { QuickComposerSheet(store: store) }
    }

    @State private var connectAfterSidebar = false
}
