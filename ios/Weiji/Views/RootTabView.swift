import SwiftUI

struct NoteZoomID: Hashable {
    let source: DetailSource
    let id: String
}

struct RootTabView: View {
    @Bindable var store: AppStore
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
                TabView(selection: $store.tab) {
                    Tab("笔记", systemImage: "text.alignleft", value: AppStore.Tab.notes) {
                        NotesTabView(store: store, noteZoom: noteZoom, sidebar: $notesSidebar, showDatePicker: $showDatePicker)
                    }
                    Tab("漫步", systemImage: "point.topleft.down.to.point.bottomright.curvepath", value: AppStore.Tab.walk) {
                        RandomWalkView(store: store, noteZoom: noteZoom)
                    }
                    Tab("AI", systemImage: "bubble.left", value: AppStore.Tab.ai) {
                        AIChatView(store: store, showSessions: $aiSessionsDrawer)
                    }
                    Tab("洞察", systemImage: "chart.bar.xaxis", value: AppStore.Tab.insights) {
                        InsightsTabView(store: store)
                    }
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
        .tint(Theme.active)
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

    private func closeSessions() { aiSessionsDrawer = false }

    @ViewBuilder
    private func noteReader(for detail: AppStore.Detail) -> some View {
        let reader = NavigationStack {
            NoteReaderView(store: store, note: detail.note, source: detail.source, presentation: .fullScreen)
        }
        if detail.source.supportsZoom {
            reader.navigationTransition(.zoom(sourceID: NoteZoomID(source: detail.source, id: detail.id), in: noteZoom))
        } else {
            reader
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
