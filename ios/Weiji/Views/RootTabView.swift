import SwiftUI

struct RootTabView: View {
    @Bindable var store: AppStore
    @State private var notesSidebar = false
    @State private var aiSessionsDrawer = false
    @Namespace private var tabSelection
    @Namespace private var noteZoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                Group {
                    switch store.tab {
                    case .notes: NotesTabView(store: store, noteZoom: noteZoom, sidebar: $notesSidebar)
                    case .walk: RandomWalkView(store: store, noteZoom: noteZoom)
                    case .ai: AIChatView(store: store, showSessions: $aiSessionsDrawer)
                    case .insights: InsightsTabView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                .modifier(SideDrawer(isOpen: $notesSidebar, edgeSwipeEnabled: store.tab == .notes && !aiSessionsDrawer) {
                    SidebarSheetView(store: store, onClose: { notesSidebar = false })
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
                aiSessionsDrawer = false
            }
        }
        .onChange(of: store.tab) { _, _ in
            notesSidebar = false
            aiSessionsDrawer = false
        }
        .sheet(isPresented: $store.showSettings) { ConnectionSettingsView(store: store) }
        .fullScreenCover(item: $store.detail) { detail in
            noteReader(for: detail)
        }
        .task { store.start() }
    }

    @ViewBuilder
    private func noteReader(for detail: AppStore.Detail) -> some View {
        let reader = NavigationStack {
            NoteReaderView(store: store, note: detail.note, source: detail.source, presentation: .fullScreen)
        }
        if detail.source.supportsZoom {
            reader.navigationTransition(.zoom(sourceID: detail.id, in: noteZoom))
        } else {
            reader
        }
    }

    private var tabBar: some View {
        tabCapsule
            .frame(maxWidth: 360)
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .background {
                // Softly fades scrolled content below the floating glass bar without blocking taps.
                LinearGradient(stops: [.init(color: Theme.canvas.opacity(0), location: 0),
                                       .init(color: Theme.canvas, location: 0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -16)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
    }

    /// Small floating navigation bar uses native iOS 26 Liquid Glass so it harmonizes with system sheet toolbars.
    @ViewBuilder
    private var tabCapsule: some View {
        let content = HStack(spacing: 0) {
            ForEach(AppStore.Tab.allCases, id: \.self) { tab in
                let selected = store.tab == tab
                Button {
                    store.tab = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: icon(tab)).font(.system(size: 17, weight: selected ? .semibold : .regular))
                        Text(title(tab)).font(.system(size: 10, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Theme.active : Theme.ink2)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background {
                        if selected {
                            Capsule().fill(Theme.accentSoft.opacity(0.88))
                                .matchedGeometryEffect(id: "selected-tab", in: tabSelection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tab-" + tab.rawValue)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: store.tab)
        .padding(4)

        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.hairline).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        }
    }

    private func icon(_ tab: AppStore.Tab) -> String {
        switch tab {
        case .notes: "text.alignleft"
        case .walk: "point.topleft.down.to.point.bottomright.curvepath"
        case .ai: "bubble.left"
        case .insights: "chart.bar.xaxis"
        }
    }

    private func title(_ tab: AppStore.Tab) -> String {
        switch tab {
        case .notes: "笔记"
        case .walk: "漫步"
        case .ai: "AI"
        case .insights: "洞察"
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
