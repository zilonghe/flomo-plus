import SwiftUI

struct RootTabView: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch store.tab {
                case .notes: NotesTabView(store: store)
                case .walk: RandomWalkView(store: store)
                case .ai: AIChatView(store: store)
                case .insights: InsightsTabView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 0) {
                ForEach(AppStore.Tab.allCases, id: \.self) { tab in
                    Button {
                        store.tab = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: icon(tab)).font(.system(size: 19))
                            Text(title(tab)).font(.caption)
                        }
                        .foregroundStyle(store.tab == tab ? Theme.active : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 51)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.tab == tab ? .isSelected : [])
                    .accessibilityIdentifier("tab-" + tab.rawValue)
                }
            }
            .background(Theme.paper)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .tint(Theme.active)
        .sheet(isPresented: $store.showSettings) { ConnectionSettingsView(store: store) }
        .sheet(item: $store.detail) { detail in
            NoteDetailSheet(store: store, note: detail.note)
        }
        .task { store.start() }
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
