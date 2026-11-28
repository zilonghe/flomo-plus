import SwiftUI

struct SidebarSheetView: View {
    @Bindable var store: AppStore
    let onClose: () -> Void
    let onPickDate: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var statsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                IconAction(symbol: "xmark", label: "关闭菜单", id: "notes-menu-close", action: onClose)
                    .foregroundStyle(Theme.ink2)
                    .padding(.trailing, -10)
            }
            .padding(.horizontal, 16).frame(minHeight: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statistics
                    kinds
                    dateFilter
                    if !store.index.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("标签").padding(.bottom, 6)
                            ForEach(store.index.tags) { node in TagBranch(node: node, depth: 0, filter: applyTag) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            Rectangle().fill(Theme.hairline).frame(height: 1).accessibilityHidden(true)
            Button {
                onClose()
                store.openSettings()
            } label: {
                HStack {
                    Text("设置")
                    Spacer()
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 20).minTapHeight()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notes-settings-button")
        }
    }

    private var statistics: some View {
        let days = store.index.heatmap
        let activeDays = Set(store.index.entries.lazy.map(\.day).filter { !$0.isEmpty }).count
        let peak = max(1, days.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Button { statsExpanded.toggle() } label: {
                HStack {
                    Text("\(store.index.entries.count) 笔记 · \(store.index.readingCount) 读书 · \(activeDays) 天")
                        .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if !statsExpanded && !dynamicTypeSize.isAccessibilitySize {
                        HStack(spacing: 3) {
                            ForEach(days.suffix(7)) { day in
                                Circle().fill(Theme.heat(level: level(day.count, peak: peak))).frame(width: 5, height: 5)
                            }
                        }.accessibilityHidden(true)
                    }
                    Image(systemName: statsExpanded ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                }
                .font(.footnote).foregroundStyle(Theme.ink2).minTapHeight()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-stats-toggle")
            .accessibilityValue(statsExpanded ? "已展开" : "已收起")
            if statsExpanded {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(10), spacing: 3), count: 7), spacing: 3) {
                    ForEach(days) { day in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.heat(level: level(day.count, peak: peak)))
                            .frame(width: 10, height: 10)
                    }
                }
                .accessibilityLabel("近 12 周有 \(days.filter { $0.count > 0 }.count) 天记录")
                Text("近 12 周").font(.footnote).tracking(0.5).foregroundStyle(Theme.ink2)
            }
        }
    }

    private func level(_ count: Int, peak: Int) -> Int {
        count == 0 ? 0 : (count * 4 + peak - 1) / peak
    }

    private var kinds: some View {
        HStack(spacing: 8) {
            ForEach(NoteFilter.Kind.allCases) { kind in
                Button { store.filter.kind = kind } label: {
                    Text(kind.rawValue)
                        .font(.subheadline)
                        .underline(store.filter.kind == kind)
                        .foregroundStyle(store.filter.kind == kind ? Theme.ink : Theme.ink2)
                        .frame(maxWidth: .infinity).minTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(store.filter.kind == kind ? .isSelected : [])
            }
        }
    }

    private var dateFilter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onClose()
                onPickDate()
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("按日期")
                            dateFilterValue
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Text("按日期")
                            Spacer(minLength: 8)
                            dateFilterValue
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notes-filter-date")

            if store.filter.day != nil {
                Button {
                    store.filter.day = nil
                    onClose()
                } label: {
                    Text("清除日期").minTouchTarget()
                }
            }
        }
    }

    private var dateFilterValue: some View {
        HStack(spacing: 6) {
            if let day = store.filter.day { Text(day) }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.ink2)
    }

    private func applyTag(_ tag: String) {
        store.filter.tag = tag
        onClose()
    }
}

private struct TagBranch: View {
    let node: TagParser.Node
    let depth: Int
    let filter: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button { filter(node.path) } label: {
                    HStack {
                        Text("#" + node.name).font(.subheadline).foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Text(node.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(Theme.ink3)
                    }
                    .minTapHeight()
                }
                .buttonStyle(.plain)
                if node.children.isEmpty {
                    Color.clear.frame(width: 44)
                } else {
                    Button { expanded.toggle() } label: {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "收起 #\(node.name)" : "展开 #\(node.name)")
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 4)
            if expanded {
                ForEach(node.children) { child in TagBranch(node: child, depth: depth + 1, filter: filter) }
            }
        }
    }
}
