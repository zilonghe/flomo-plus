import SwiftUI

struct RandomWalkView: View {
    let store: AppStore
    let noteZoom: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var focusTextSize = 18.0
    private var walk: WalkStore { store.walk }
    private var focusAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if let result = walk.result {
                                constellation(result)
                                    .id(result.focus.id)
                                    .transition(.opacity)
                            } else if !walk.loading && walk.error == nil {
                                if store.index.entries.isEmpty {
                                    Text("暂无可漫步的笔记").foregroundStyle(Theme.ink3)
                                        .padding(.top, 48)
                                } else {
                                    VStack(spacing: 12) {
                                        Text("当前焦点已移除").font(Theme.TypeScale.body).foregroundStyle(Theme.ink2)
                                        Button("随机浏览", action: shuffle)
                                            .buttonStyle(.weijiSecondary)
                                            .disabled(store.api == nil)
                                    }
                                    .padding(.top, 48)
                                }
                            }
                            InlineError(message: walk.error)
                        }
                        .frame(maxWidth: 640)
                        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                        .id("walk-canvas")
                    }
                    .background {
                        RadialGradient(colors: [Theme.active.opacity(0.08), .clear], center: .init(x: 0.5, y: 0.38),
                                       startRadius: 10, endRadius: 290)
                        .allowsHitTesting(false)
                    }
                    .onChange(of: walk.result?.focus.id) { _, _ in
                        withAnimation(focusAnimation) { proxy.scrollTo("walk-canvas", anchor: .top) }
                    }
                }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("漫步")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    IconAction(symbol: "square.and.pencil", label: "快速记", id: "walk-quick-note") {
                        store.showComposer = true
                    }
                    .disabled(store.api == nil)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if walk.loading { ProgressView().controlSize(.small).accessibilityLabel("正在寻找关联笔记") }
                    Button("随机", action: shuffle)
                        .disabled(store.index.entries.isEmpty || walk.loading || store.api == nil)
                        .accessibilityIdentifier("walk-shuffle-button")
                    Button("问 AI") { if let result = walk.result { store.askAbout(result) } }
                        .disabled(walk.result == nil || walk.loading)
                        .accessibilityIdentifier("walk-chat-button")
                }
            }
        }
        .animation(focusAnimation, value: walk.result?.focus.id)
        .sensoryFeedback(.impact(weight: .light), trigger: walk.result?.focus.id) { old, new in
            old != nil && new != nil
        }
        .task(id: store.index.entries.isEmpty) {
            if walk.result == nil && !walk.loading { shuffle() }
        }
    }

    @ViewBuilder
    private func constellation(_ result: RelatedNotes) -> some View {
        if let previous = walk.previousFocus {
            previousCard(previous)
            connector(hasPrevious: true)
        }
        Button {
            Task { await store.openNote(result.focus.id, from: .walk) }
        } label: {
            focusCard(result.focus)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: NoteZoomID(source: .walk, id: result.focus.id), in: noteZoom)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("walk-focus-card")
        .accessibilityValue(result.focus.id)

        if !result.related.isEmpty {
            connector(hasRightBranch: result.related.count > 1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 10) {
                ForEach(Array(result.related.prefix(4).enumerated()), id: \.element.id) { index, item in
                    relatedNode(item, compact: false)
                        .padding(.top, index.isMultiple(of: 2) ? 0 : 7)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("walk-related-list")
        }
        if result.related.count > 4 {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("更多关联")
                ForEach(result.related.dropFirst(4)) { item in
                    relatedNode(item, compact: true)
                }
            }
            .padding(.top, 20)
        }
    }

    private func connector(hasPrevious: Bool = false, hasRightBranch: Bool = false) -> some View {
        Canvas { context, size in
            let center = size.width / 2
            let left = (size.width - 12) / 4
            var ends = hasPrevious ? [CGPoint(x: center, y: 24)] : [CGPoint(x: left, y: 30)]
            if hasRightBranch { ends.append(CGPoint(x: size.width - left, y: 37)) }
            var path = Path()
            for end in ends {
                path.move(to: CGPoint(x: center, y: 0))
                path.addCurve(to: end, control1: CGPoint(x: center, y: end.y * 0.7),
                              control2: CGPoint(x: end.x, y: end.y * 0.3))
            }
            context.stroke(path, with: .color(Theme.active.opacity(0.42)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: hasPrevious ? [3, 4] : []))
        }
        .frame(height: hasPrevious ? 24 : hasRightBranch ? 37 : 30)
        .padding(.bottom, hasRightBranch ? -7 : 0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func sourceTitle(_ note: RelatedNoteSummary) -> String {
        let book = note.reading?.bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return book.isEmpty ? "随记" : book
    }

    private func previousCard(_ note: RelatedNoteSummary) -> some View {
        Button { walk.previous() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("← 上一步 · \(sourceTitle(note))")
                    .font(Theme.TypeScale.meta.weight(.semibold)).foregroundStyle(Theme.active)
                    .lineLimit(1)
                Text(note.body).font(Theme.TypeScale.meta).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 260, alignment: .leading)
            .background(Theme.paper, in: .rect(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Theme.active.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("walk-prev-button")
    }

    private func focusCard(_ note: RelatedNoteSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(sourceTitle(note), systemImage: "scope")
                .font(Theme.TypeScale.meta.weight(.semibold)).foregroundStyle(Theme.active).lineLimit(1)
            Text(note.body)
                .font(.system(size: focusTextSize, design: .serif))
                .foregroundStyle(Theme.ink)
                .lineSpacing(7).lineLimit(7)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(String(note.createdAt.prefix(10))).font(Theme.TypeScale.meta.monospacedDigit()).foregroundStyle(Theme.ink3)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(Theme.TypeScale.meta.weight(.semibold)).foregroundStyle(Theme.active).accessibilityHidden(true)
            }
        }
        .padding(18).padding(.leading, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(Theme.paper)
                .shadow(color: Theme.active.opacity(0.1), radius: 14, y: 5)
        }
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.active.opacity(0.32), lineWidth: 1.5) }
        .overlay(alignment: .leading) {
            Capsule().fill(Theme.green).frame(width: 3).padding(.leading, 10).padding(.vertical, 18)
                .accessibilityHidden(true)
        }
        .contentShape(.rect(cornerRadius: 22))
    }

    private func relatedNode(_ item: RelatedNotes.Item, compact: Bool) -> some View {
        let badges = WalkCardBadge.badges(for: item)
        return Button {
            if let api = store.api { walk.pivot(to: item.id, api: api) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if !badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            let accent = WalkCardBadge.accent(for: badge.kind)
                            HStack(spacing: 3) {
                                if badge.kind == .book {
                                    Image(systemName: "book.closed").accessibilityHidden(true)
                                }
                                Text(badge.text).lineLimit(1)
                            }
                            .font(Theme.TypeScale.meta.weight(.medium)).foregroundStyle(accent.active)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(accent.accentSoft, in: Capsule())
                        }
                    }
                }
                Text(item.note.body).font(Theme.TypeScale.body).foregroundStyle(Theme.ink)
                    .lineSpacing(3).lineLimit(compact ? 1 : 3, reservesSpace: !compact)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text("\(item.relevancePercent)%").monospacedDigit().foregroundStyle(Theme.ink2)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(Theme.TypeScale.meta.weight(.semibold)).foregroundStyle(Theme.active).accessibilityHidden(true)
                }
                .font(Theme.TypeScale.meta.weight(.medium))
            }
            .noteCard(padding: 12, cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .disabled(store.api == nil)
        .matchedTransitionSource(id: NoteZoomID(source: .walk, id: item.note.id), in: noteZoom)
        .contextMenu {
            Button("查看全文", systemImage: "book") {
                Task { await store.openNote(item.note.id, from: .walk) }
            }
        }
        .accessibilityIdentifier("walk-related-card-" + item.id)
    }

    private func shuffle() {
        if let api = store.api { walk.shuffle(notes: store.index.entries.map(\.note), api: api) }
    }
}
