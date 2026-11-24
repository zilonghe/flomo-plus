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
        .foregroundStyle(Theme.ink)
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
        HStack(spacing: 2) {
            ForEach(AppStore.Tab.allCases, id: \.self) { tab in
                let selected = store.tab == tab
                Button {
                    store.tab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon(tab)).font(.system(size: 19))
                        Text(title(tab)).font(.caption)
                    }
                    .foregroundStyle(selected ? Color.white : Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background {
                        if selected {
                            Capsule().fill(Theme.deepGreen)
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
        .padding(5)
        .frame(maxWidth: 420)
        .weijiGlassCapsule(interactive: false)
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
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
