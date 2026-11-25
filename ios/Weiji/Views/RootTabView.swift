import SwiftUI

struct RootTabView: View {
    @Bindable var store: AppStore
    @State private var sidebar = false
    @Namespace private var tabSelection
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
                    case .notes: NotesTabView(store: store, sidebar: $sidebar)
                    case .walk: RandomWalkView(store: store)
                    case .ai: AIChatView(store: store)
                    case .insights: InsightsTabView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                .modifier(NotesDrawer(store: store, isOpen: $sidebar))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .tint(Theme.active)
        .onChange(of: store.authScreenState) { _, state in
            if state == .needsLogin || state == .restoring { sidebar = false }
        }
        .sheet(isPresented: $store.showSettings) { ConnectionSettingsView(store: store) }
        .sheet(item: $store.detail) { detail in
            NoteDetailSheet(store: store, note: detail.note)
        }
        .task { store.start() }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppStore.Tab.allCases, id: \.self) { tab in
                let selected = store.tab == tab
                Button {
                    store.tab = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: icon(tab)).font(.system(size: 17, weight: selected ? .semibold : .regular))
                        Text(title(tab)).font(.system(size: 10, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Theme.active : Theme.ink3)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background {
                        if selected {
                            Capsule().fill(Theme.accentSoft)
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
        .background {
            Capsule().fill(Theme.paper)
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        }
        .overlay { Capsule().strokeBorder(Theme.hairline).allowsHitTesting(false) }
        .frame(maxWidth: 360)
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background {
            // Fades scrolled content out under the floating bar instead of letting it peek around the capsule.
            LinearGradient(stops: [.init(color: Theme.canvas.opacity(0), location: 0),
                                   .init(color: Theme.canvas, location: 0.45)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -18)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
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
