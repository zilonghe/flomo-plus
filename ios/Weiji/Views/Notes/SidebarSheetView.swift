import SwiftUI

struct SidebarSheetView: View {
    @Bindable var store: AppStore
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyHGrid(rows: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                        ForEach(store.index.heatmap) { day in
                            Button {
                                store.filter.day = store.filter.day == day.id ? nil : day.id
                                dismiss()
                            } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(day.count == 0 ? Theme.line : Theme.green.opacity(min(1, 0.24 + Double(day.count) * 0.13)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(day.id)，\(day.count) 条笔记")
                        }
                    }.frame(height: 120)
                    LabeledContent("全部笔记", value: store.index.entries.count.formatted())
                    LabeledContent("读书笔记", value: store.index.readingCount.formatted())
                }
                Section("筛选") {
                    Picker("类型", selection: $store.filter.kind) {
                        ForEach(NoteFilter.Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                    }
                    Button("清除筛选") { store.filter = NoteFilter(); dismiss() }
                }
                Section("标签") {
                    ForEach(store.index.tags) { node in TagBranch(node: node, filter: applyTag) }
                }
                Section {
                    Button(action: openSettings) { Label("连接设置", systemImage: "gearshape") }
                }
            }
            .navigationTitle("笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func applyTag(_ tag: String) {
        store.filter.tag = tag
        dismiss()
    }
}

private struct TagBranch: View {
    let node: TagParser.Node
    let filter: (String) -> Void

    var body: some View {
        if node.children.isEmpty { filterButton }
        else {
            DisclosureGroup {
                Button("筛选 #\(node.path)") { filter(node.path) }
                ForEach(node.children) { child in TagBranch(node: child, filter: filter) }
            } label: {
                LabeledContent("#" + node.name, value: node.count.formatted())
            }
        }
    }

    private var filterButton: some View {
        Button { filter(node.path) } label: { LabeledContent("#" + node.name, value: node.count.formatted()) }
    }
}
