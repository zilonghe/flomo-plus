import SwiftUI

struct NoteZoomID: Hashable {
    let source: DetailSource
    let id: String
}

struct RootTabView: View {
    @Bindable var store: AppStore
    @State private var restoring = false
    @State private var notesSidebar = false
    @State private var showDatePicker = false
    @State private var aiSessionsDrawer = false
    @Namespace private var noteZoom

    var body: some View {
        Group {
            switch store.authScreenState {
            case .needsLogin:
                LoginView(store: store)
            case .restoring:
                VStack(spacing: 22) {
                    WeijiLoginMark()
                    ProgressView().accessibilityLabel("正在恢复连接")
                }
            case .online, .offline:
                ZStack {
                    NotesTabView(store: store, noteZoom: noteZoom, sidebar: $notesSidebar, showDatePicker: $showDatePicker)
                        .workspaceVisible(store.tab == .notes)
                    AIChatView(store: store, showSessions: $aiSessionsDrawer)
                        .workspaceVisible(store.tab == .ai)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if store.deletedUndoNote != nil { undoBar }
                }
                .modifier(SideDrawer(isOpen: $notesSidebar, edgeSwipeEnabled: store.tab == .notes && !aiSessionsDrawer) {
                    SidebarSheetView(store: store, onClose: { notesSidebar = false },
                                     onPickDate: { showDatePicker = true })
                })
                .modifier(SideDrawer(isOpen: $aiSessionsDrawer, edgeSwipeEnabled: store.tab == .ai && store.api != nil && !notesSidebar) {
                    SessionsDrawerView(store: store, onClose: { aiSessionsDrawer = false })
                })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .tint(Theme.ink)
        .onChange(of: store.authScreenState) { _, state in
            if state == .needsLogin || state == .restoring {
                notesSidebar = false
                showDatePicker = false
                aiSessionsDrawer = false
            }
        }
        .onChange(of: store.tab) { _, _ in
            notesSidebar = false
            aiSessionsDrawer = false
        }
        .sheet(item: $store.settingsSection) { ConnectionSettingsView(store: store, section: $0) }
        .sheet(isPresented: $store.showComposer) { QuickComposerSheet(store: store) }
        .modifier(ChatSwitchAlert(store: store, active: store.detail == nil, onConfirm: closeSessions))
        .fullScreenCover(item: $store.detail) { detail in
            noteReader(for: detail)
                .modifier(ChatSwitchAlert(store: store, active: true, onConfirm: closeSessions))
        }
        .task { store.start() }
    }

    private var undoBar: some View {
        HStack {
            Text("已删除一条笔记").frame(maxWidth: .infinity, alignment: .leading)
            Button {
                restoring = true
                Task { await store.undoDelete(); restoring = false }
            } label: {
                Text("撤销").fontWeight(.semibold).fixedSize().minTouchTarget()
            }
            .buttonStyle(.plain)
            .disabled(restoring)
        }
        .font(.subheadline).foregroundStyle(Theme.inverseText)
        .padding(.horizontal, 16).background(Theme.inverseBg, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private func closeSessions() { aiSessionsDrawer = false }

    @ViewBuilder
    private func noteReader(for detail: AppStore.Detail) -> some View {
        let reader = NavigationStack {
            NoteReaderView(store: store, note: detail.note, source: detail.source)
        }
        if detail.source == .notes {
            reader.navigationTransition(.zoom(sourceID: NoteZoomID(source: detail.source, id: detail.id), in: noteZoom))
        } else {
            reader
        }
    }

}

private extension View {
    func workspaceVisible(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .offset(x: visible ? 0 : -10_000)
            .zIndex(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

struct SpaceSwitcher: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 2) {
            item("笔记", .notes)
            Text("·").foregroundStyle(Theme.ink2).accessibilityHidden(true)
            item("AI", .ai)
        }
    }

    @ViewBuilder
    private func item(_ title: String, _ tab: AppStore.Tab) -> some View {
        if store.tab == tab {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize().minTouchTarget()
                .accessibilityAddTraits(.isSelected)
        } else {
            Button { store.tab = tab } label: {
                Text(title).font(.subheadline.weight(.regular))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize().minTouchTarget()
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ChatSwitchAlert: ViewModifier {
    let store: AppStore
    let active: Bool
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert("AI 正在回复", isPresented: Binding(
            get: { active && store.pendingChatSwitch != nil },
            set: { _ in } // The two buttons resolve the pending switch.
        )) {
            Button("继续等待", role: .cancel) { store.cancelChatSwitch() }
            Button("停止并切换", role: .destructive) {
                store.confirmChatSwitch()
                onConfirm()
            }
        }
    }
}

/// Shared solid, strictly clipped left-edge slide-in drawer for both Notes sidebar and AI history.
struct SideDrawer<DrawerContent: View>: ViewModifier {
    @Binding var isOpen: Bool
    let edgeSwipeEnabled: Bool
    @ViewBuilder let drawer: () -> DrawerContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isOpen)
            .allowsHitTesting(!isOpen)
            .simultaneousGesture(DragGesture().onEnded { value in
                let dx = value.translation.width
                guard edgeSwipeEnabled, !isOpen, value.startLocation.x <= 28,
                      dx > 60, dx > abs(value.translation.height) else { return }
                isOpen = true
            })
            .overlay {
                if isOpen {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.black.opacity(0.32)
                                .ignoresSafeArea()
                                .onTapGesture { isOpen = false }
                                .accessibilityHidden(true)
                                .transition(.opacity)
                            drawer()
                                .frame(width: min(320, geo.size.width * 0.84))
                                .frame(maxHeight: .infinity)
                                .clipped()
                                .background {
                                    // Large drawer panels stay strictly opaque to prevent translucency bleed.
                                    UnevenRoundedRectangle(bottomTrailingRadius: 24, topTrailingRadius: 24)
                                        .fill(Theme.canvas)
                                        .shadow(color: .black.opacity(0.22), radius: 20, x: 6)
                                        .ignoresSafeArea()
                                }
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
