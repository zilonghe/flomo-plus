import SwiftUI

struct SidebarSheetView: View {
    @Bindable var store: AppStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("微记").font(.title3.bold())
                Spacer()
                IconAction(symbol: "xmark", label: "关闭菜单", id: "notes-menu-close", action: onClose)
                    .foregroundStyle(Theme.ink2)
                    .padding(.trailing, -10)
            }
            .screenHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        metric("全部笔记", store.index.entries.count)
                        metric("读书笔记", store.index.readingCount)
                    }
                    heatmap
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel("筛选")
                            Spacer()
                            if store.filter != NoteFilter() {
                                Button("清除") { store.filter = NoteFilter(); onClose() }
                                    .font(.footnote.weight(.medium))
                            }
                        }
                        Picker("类型", selection: $store.filter.kind) {
                            ForEach(NoteFilter.Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                        }
                        .pickerStyle(.segmented)
                    }
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
            Divider().overlay(Theme.hairline)
            Button {
                onClose()
                store.showSettings = true
            } label: {
                Label("连接设置", systemImage: "gearshape")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(Theme.ink2)
        }
        .noteCard(padding: 12, cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }

    private var heatmap: some View {
        let days = store.index.heatmap
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let peak = max(1, days.map(\.count).max() ?? 1)
        return HStack(alignment: .top, spacing: 3) {
            ForEach(columns.indices, id: \.self) { column in
                VStack(spacing: 3) {
                    ForEach(columns[column]) { day in
                        Button {
                            store.filter.day = store.filter.day == day.id ? nil : day.id
                            onClose()
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(day.count == 0 ? Theme.subtle : Theme.green.opacity(0.28 + 0.72 * Double(day.count) / Double(peak)))
                                .overlay {
                                    if store.filter.day == day.id {
                                        RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.ink, lineWidth: 1.5)
                                    }
                                }
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(day.id)，\(day.count) 条笔记")
                    }
                }
            }
        }
        .noteCard(padding: 12, cornerRadius: 14)
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
                        Text("#" + node.name).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(node.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(Theme.ink3)
                    }
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if node.children.isEmpty {
                    Color.clear.frame(width: 32)
                } else {
                    Button { expanded.toggle() } label: {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 32, height: 36).contentShape(Rectangle())
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
