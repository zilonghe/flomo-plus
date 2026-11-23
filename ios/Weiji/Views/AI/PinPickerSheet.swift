import SwiftUI

struct PinPickerSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Note] = []
    @State private var displayCount = 50

    var body: some View {
        NavigationStack {
            List {
                ForEach(results.prefix(displayCount)) { note in
                    let selected = store.chat.pins.contains(note.id)
                    Button {
                        store.chat.togglePin(note.id)
                    } label: {
                        HStack {
                            Text(note.body).lineLimit(2)
                            Spacer()
                            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.active) }
                        }
                    }
                    .disabled(!selected && store.chat.pins.count >= 10)
                    .onAppear {
                        if displayCount < results.count && results[displayCount - 1].id == note.id { displayCount += 50 }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索笔记")
            .navigationTitle("置顶笔记 · \(store.chat.pins.count)/10")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: query) {
                let index = store.index
                let text = query
                let found = await Task.detached { index.search(text) }.value
                guard !Task.isCancelled else { return }
                results = found
                displayCount = 50
            }
        }
    }
}
