import Foundation
import SwiftUI

struct WritingStyleWorkspaceView: View {
    private enum Sheet: String, Identifiable {
        case rules, anchors, start, end
        var id: Self { self }
        var dateTitle: String { self == .start ? "起始日期" : "结束日期" }
    }

    let store: AppStore
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var sheet: Sheet?
    @State private var rules = ""
    @State private var topic = ""
    @State private var date = Date.now

    private var insights: InsightsStore { store.insights }
    private var anchorIds: [String] { insights.writingStyle?.anchorNoteIds ?? [] }
    private var busy: Bool {
        insights.loadingWritingStyle || insights.savingWritingStyle || insights.generatingWritingStyle || store.api == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls.noteCard()
                InlineError(message: insights.writingStyleError ?? (store.isRelayMode ? InsightsStore.writingStyleRelayMessage : nil))
                if !insights.writingStyleLoaded && !busy {
                    Button("重新加载") {
                        Task { if let api = store.api { await insights.loadWritingStyle(api: api) } }
                    }
                    .buttonStyle(.weijiSecondary)
                    .accessibilityIdentifier("style-retry-load-button")
                }
                rulesCard.noteCard()
                anchorsCard.noteCard()
                blindTestCard.noteCard()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.canvas)
        .tint(Theme.active)
        .task(id: store.api.map { ObjectIdentifier($0) }) {
            if let api = store.api { await insights.loadWritingStyle(api: api) }
        }
        .sheet(item: $sheet) { item in
            Group {
                switch item {
                case .rules: rulesSheet
                case .anchors: WritingStyleAnchorPickerSheet(store: store, ids: anchorIds, onPick: addAnchor)
                case .start, .end: dateSheet(item)
                }
            }
            .presentationDetents([.medium, .large])
            .tint(Theme.active)
        }
    }

    private var controls: some View {
        let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button(insights.generatingWritingStyle ? "停止提炼" : "提炼风格") {
                if insights.generatingWritingStyle { insights.stopWritingStyle() }
                else if let api = store.api {
                    insights.generateWritingStyle(api: api, options: store.options, isRelayMode: store.isRelayMode)
                }
            }
            .buttonStyle(.weijiPrimary)
            .disabled(insights.savingWritingStyle || store.api == nil || (store.isRelayMode && !insights.generatingWritingStyle))
            .accessibilityIdentifier("style-generate-button")

            Button("编辑规则") { rules = insights.writingStyleRulesText; sheet = .rules }
                .buttonStyle(.weijiSecondary)
                .disabled(busy || !insights.writingStyleLoaded)
                .accessibilityIdentifier("style-edit-button")

            Button("添加原句") { sheet = .anchors }
                .buttonStyle(.weijiSecondary)
                .disabled(busy || !insights.writingStyleLoaded || anchorIds.count >= InsightsStore.writingStyleMaxAnchors)
                .accessibilityIdentifier("style-add-anchor-button")
        }
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("写作规则")
            if let status = insights.writingStyleStatus {
                ProgressView(status).font(Theme.TypeScale.body).foregroundStyle(Theme.ink2)
            } else if insights.loadingWritingStyle {
                ProgressView("正在载入写作风格")
            }
            if !insights.writingStyleRulesText.isEmpty {
                MarkdownBlockView(text: insights.writingStyleRulesText)
            } else if !insights.generatingWritingStyle && !insights.loadingWritingStyle {
                Text("暂无写作规则").font(Theme.TypeScale.body).foregroundStyle(Theme.ink2)
            }
            rangeMenu
            if insights.writingStyleScope.range == "custom" {
                let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    dateButton(.start, day: insights.writingStyleScope.startDate)
                    dateButton(.end, day: insights.writingStyleScope.endDate)
                }
            }
        }
    }

    private static let ranges = ["all", "7d", "week", "month", "custom"]
    private func rangeTitle(_ range: String) -> String {
        switch range {
        case "7d": "近 7 天"
        case "week": "本周"
        case "month": "本月"
        case "custom": "自定义日期"
        default: "全部笔记"
        }
    }

    private var rangeMenu: some View {
        Menu {
            Picker("提炼范围", selection: Binding(get: { insights.writingStyleScope.range }, set: selectRange)) {
                ForEach(Self.ranges, id: \.self) { range in Text(rangeTitle(range)).tag(range) }
            }
        } label: {
            Chip(text: rangeTitle(insights.writingStyleScope.range), symbol: "calendar").minTouchTarget()
        }
        .accessibilityLabel("提炼范围")
        .accessibilityValue(rangeTitle(insights.writingStyleScope.range))
        .disabled(busy)
    }

    private func selectRange(_ range: String) {
        insights.writingStyleScope.range = range
        let today = Self.dayFormatter.string(from: .now)
        insights.writingStyleScope.startDate = range == "custom" ? today : nil
        insights.writingStyleScope.endDate = range == "custom" ? today : nil
    }

    private func dateButton(_ item: Sheet, day: String?) -> some View {
        Button {
            date = day.flatMap { Self.dayFormatter.date(from: $0) } ?? .now
            sheet = item
        } label: {
            Text(day ?? item.dateTitle)
        }
        .buttonStyle(.weijiSecondary)
        .disabled(busy)
        .accessibilityLabel(item.dateTitle)
        .accessibilityValue(day ?? "未设置")
    }

    private func dateSheet(_ item: Sheet) -> some View {
        NavigationStack {
            ScrollView {
                DatePicker(item.dateTitle, selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, 8)
            }
            .weijiSheetBackground()
            .navigationTitle(item.dateTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let day = Self.dayFormatter.string(from: date)
                        if item == .start {
                            insights.writingStyleScope.startDate = day
                            insights.writingStyleScope.endDate = max(day, insights.writingStyleScope.endDate ?? day)
                        } else {
                            insights.writingStyleScope.endDate = day
                            insights.writingStyleScope.startDate = min(day, insights.writingStyleScope.startDate ?? day)
                        }
                        sheet = nil
                    }
                }
            }
        }
    }

    private var rulesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("写作规则", text: $rules, axis: .vertical)
                        .lineLimit(5...)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.ink)
                        .onChange(of: rules) { _, value in
                            let clipped = clippedUTF16(value, to: InsightsStore.writingStyleMaxRules)
                            if clipped != value { rules = clipped }
                        }
                        .disabled(insights.savingWritingStyle)
                        .noteCard()
                    Text("\(rules.utf16.count)/\(InsightsStore.writingStyleMaxRules)")
                        .font(Theme.TypeScale.meta.monospacedDigit()).foregroundStyle(Theme.ink2)
                    InlineError(message: insights.writingStyleError)
                }
                .padding(16)
            }
            .weijiSheetBackground()
            .navigationTitle("编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { sheet = nil }
                        .disabled(insights.savingWritingStyle)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let submitted = rules
                        guard let api = store.api, let task = insights.saveWritingStyle(.init(rules: submitted), api: api) else { return }
                        Task { if await task.value, sheet == .rules, rules == submitted { sheet = nil } }
                    }
                    .disabled(busy || rules.utf16.count > InsightsStore.writingStyleMaxRules)
                }
            }
        }
        .interactiveDismissDisabled(insights.savingWritingStyle)
    }

    private var anchorsCard: some View {
        let anchors = insights.writingStyle?.anchors ?? []
        let available = anchors.map(\.id)
        let suggested = insights.suggestedAnchors.map(\.id).filter { !anchorIds.contains($0) && store.notesById[$0].flatMap { Note.extractOriginalWriting(from: $0) } != nil }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("原句锚点 · \(anchorIds.count)/\(InsightsStore.writingStyleMaxAnchors)")
            ForEach(anchors) { anchor in
                HStack(spacing: 8) {
                    Text(anchor.excerpt).font(Theme.TypeScale.body).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconAction(symbol: "minus.circle", label: "移除原句\(anchor.excerpt)", id: "style-remove-anchor-\(anchor.id)") {
                        saveAnchors(available.filter { $0 != anchor.id })
                    }
                    .disabled(busy)
                }
            }
            if let missing = insights.writingStyle?.missingAnchorCount, missing > 0 {
                Text("\(missing) 条原句已不可用").font(Theme.TypeScale.meta).foregroundStyle(Theme.ink2)
                Button("移除不可用原句") { saveAnchors(available) }
                    .buttonStyle(.weijiSecondary).disabled(busy)
            }
            if !suggested.isEmpty && anchorIds.count < InsightsStore.writingStyleMaxAnchors {
                Button("采纳推荐原句") { saveAnchors(Array((available + suggested).prefix(InsightsStore.writingStyleMaxAnchors))) }
                    .buttonStyle(.weijiSecondary).disabled(busy)
            }
        }
    }

    private func addAnchor(_ id: String) {
        guard let api = store.api else { return }
        insights.addWritingStyleAnchor(id, api: api)
    }

    private func saveAnchors(_ ids: [String]) {
        guard let api = store.api else { return }
        insights.saveWritingStyle(.init(anchorNoteIds: ids), api: api)
    }

    private var blindTestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("盲测")
            TextField("自定义主题（可留空）", text: $topic, axis: .vertical)
                .font(Theme.TypeScale.body).foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).minTapHeight()
                .background(Theme.subtle, in: .rect(cornerRadius: 10))
                .onChange(of: topic) { _, value in
                    let clipped = clippedUTF16(value, to: InsightsStore.blindTestMaxPrompt)
                    if clipped != value { topic = clipped }
                }
                .disabled(insights.runningBlindTest)
            Button(insights.runningBlindTest ? "停止盲测" : "开始盲测") {
                if insights.runningBlindTest { insights.stopBlindTest() }
                else if let api = store.api {
                    insights.runBlindTest(api: api, options: store.options, prompt: topic, isRelayMode: store.isRelayMode)
                }
            }
            .buttonStyle(.weijiPrimary)
            .disabled(!insights.runningBlindTest && (busy || store.isRelayMode || insights.writingStyle?.ready != true))
            InlineError(message: insights.blindTestError)
            if let result = insights.blindTest {
                SectionLabel(result.source.kind == "topic" ? "主题" : "留出笔记")
                Text(result.source.text).font(Theme.TypeScale.body).foregroundStyle(Theme.ink2)
                ForEach(result.candidates, id: \.slot) { candidate in
                    SectionLabel(candidateTitle(candidate))
                    MarkdownBlockView(text: candidate.text)
                }
                if let vote = insights.blindTestVote {
                    Text(vote == "tie" ? "已选：差不多" : "已选：版本 \(vote)")
                        .font(Theme.TypeScale.meta).foregroundStyle(Theme.ink2)
                } else {
                    let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 6))
                    layout {
                        Button("选 A") { insights.voteBlindTest("A") }.buttonStyle(.weijiSecondary)
                        Button("选 B") { insights.voteBlindTest("B") }.buttonStyle(.weijiSecondary)
                        Button("差不多") { insights.voteBlindTest("tie") }.buttonStyle(.weijiSecondary)
                    }
                }
            }
        }
    }

    private func candidateTitle(_ candidate: BlindTestCandidate) -> String {
        let version = "版本 \(candidate.slot)"
        guard insights.blindTestVote != nil else { return version }
        return version + (candidate.variant == "styled" ? " · 写作风格" : " · 基准")
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

private struct WritingStyleAnchorPickerSheet: View {
    let store: AppStore
    let ids: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Note] = []
    @State private var displayCount = 50

    var body: some View {
        NavigationStack {
            List(results.prefix(displayCount)) { note in
                if let text = Note.extractOriginalWriting(from: note) {
                    Button {
                        onPick(note.id)
                        dismiss()
                    } label: {
                        Text(text).font(Theme.TypeScale.body).foregroundStyle(Theme.ink)
                            .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            .minTapHeight()
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.paper)
                    .onAppear {
                        if displayCount < results.count && results[displayCount - 1].id == note.id { displayCount += 50 }
                    }
                }
            }
            .weijiSheetBackground()
            .searchable(text: $query, prompt: "搜索原创笔记")
            .navigationTitle("添加原句 · \(ids.count)/\(InsightsStore.writingStyleMaxAnchors)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task(id: query) {
                let index = store.index
                let text = query
                let selected = Set(ids)
                let found = await Task.detached {
                    index.search(text).filter { !selected.contains($0.id) && Note.extractOriginalWriting(from: $0) != nil }
                }.value
                guard !Task.isCancelled else { return }
                results = found
                displayCount = 50
            }
        }
    }
}
