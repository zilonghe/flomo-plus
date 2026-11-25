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
                            focusCard(result.focus)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("walk-focus-card")
                        .accessibilityValue(result.focus.id)
                        if !result.related.isEmpty {
                            SectionLabel("关联笔记").padding(.top, 10)
                            VStack(spacing: 8) {
                                ForEach(result.related) { item in
                                    Button {
                                        Task { await store.openNote(item.id) }
                                    } label: {
                                        relatedCard(item)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("walk-related-card-" + item.id)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("walk-related-list")
                        }
                    } else if !walk.loading && walk.error == nil {
                        Text("暂无可漫步的笔记").foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity).padding(.top, 48)
                    }
                    InlineError(message: walk.error)
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        }
        .task(id: store.index.entries.isEmpty) {
            if walk.result == nil && !walk.loading { shuffle() }
        }
    }

    private func focusCard(_ note: RelatedNoteSummary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule().fill(Theme.green).frame(width: 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    if let book = note.reading?.bookTitle, !book.isEmpty {
                        Image(systemName: "book.closed.fill").font(.caption2).accessibilityHidden(true)
                        Text(book).lineLimit(1)
                    } else {
                        Image(systemName: "quote.opening").font(.caption2).accessibilityHidden(true)
                        Text("随记")
                    }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.active)
                Text(note.body)
                    .font(.system(size: 18, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(7).lineLimit(9)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(note.createdAt.prefix(10))).font(.caption.monospacedDigit()).foregroundStyle(Theme.ink3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .noteCard(padding: 18, cornerRadius: 20)
    }

    private func relatedCard(_ item: RelatedNotes.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.note.body).font(.subheadline).foregroundStyle(Theme.ink)
                    .lineSpacing(3).lineLimit(2).multilineTextAlignment(.leading)
                if !item.sharedTags.isEmpty {
                    Text(item.sharedTags.prefix(3).map { "#" + $0 }.joined(separator: "  "))
                        .font(.caption).foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text("\(item.relevancePercent)%")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.active)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.accentSoft, in: Capsule())
        }
        .noteCard(padding: 14, cornerRadius: 14)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("上一条") { walk.previous() }
                .buttonStyle(.weijiSecondary)
                .disabled(!walk.hasPrevious)
                .accessibilityIdentifier("walk-prev-button")
            Button("换一条", action: shuffle)
                .buttonStyle(.weijiSecondary)
                .disabled(store.index.entries.isEmpty || walk.loading)
                .accessibilityIdentifier("walk-shuffle-button")
            Spacer(minLength: 0)
            Button("聊这组") { if let result = walk.result { store.askAbout(result) } }
            .buttonStyle(.weijiPrimary)
            .disabled(walk.result == nil || walk.loading)
            .accessibilityIdentifier("walk-chat-button")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            LinearGradient(stops: [.init(color: Theme.canvas.opacity(0), location: 0),
                                   .init(color: Theme.canvas, location: 0.35)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -16)
                .allowsHitTesting(false)
        }
    }

    private func shuffle() {
        if let api = store.api { walk.shuffle(notes: store.index.entries.map(\.note), api: api) }
    }
}
