import SwiftUI

struct RandomWalkView: View {
    let store: AppStore
    private var walk: WalkStore { store.walk }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("漫步").font(.title2.bold())
                Spacer()
                if walk.loading { ProgressView().controlSize(.small) }
            }.screenHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result = walk.result {
                        Button {
                            Task { await store.openNote(result.focus.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(result.focus.reading?.bookTitle ?? String(result.focus.createdAt.prefix(10)))
                                    .font(.caption).foregroundStyle(Theme.active)
                                Text(result.focus.body).font(.body).lineLimit(5).multilineTextAlignment(.leading)
                            }.noteCard()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("walk-focus-card")
                        .accessibilityValue(result.focus.id)
                        if !result.related.isEmpty {
                            Text("关联笔记").font(.headline)
                            VStack(spacing: 8) {
                                ForEach(result.related) { item in
                                    Button {
                                        Task { await store.openNote(item.id) }
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(item.note.body).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                            Text("\(item.relevancePercent)%").font(.caption.monospacedDigit()).foregroundStyle(Theme.active)
                                        }.noteCard()
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("walk-related-card-" + item.id)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("walk-related-list")
                        }
                    } else if !walk.loading && walk.error == nil {
                        Text("暂无可漫步的笔记").foregroundStyle(.secondary)
                    }
                    InlineError(message: walk.error)
                }.padding(16)
            }
            HStack {
                Button("上一条") { walk.previous() }
                    .disabled(!walk.hasPrevious)
                    .accessibilityIdentifier("walk-prev-button")
                Spacer()
                Button("换一条", action: shuffle)
                    .disabled(store.index.entries.isEmpty || walk.loading)
                    .accessibilityIdentifier("walk-shuffle-button")
                Button("聊这组") { if let result = walk.result { store.askAbout(result) } }
                    .disabled(walk.result == nil || walk.loading)
                    .accessibilityIdentifier("walk-chat-button")
                    .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .task(id: store.index.entries.isEmpty) {
            if walk.result == nil && !walk.loading { shuffle() }
        }
    }

    private func shuffle() {
        if let api = store.api { walk.shuffle(notes: store.index.entries.map(\.note), api: api) }
    }
}
