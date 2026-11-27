import SwiftUI

struct InsightsTabView: View {
    private enum Segment: String { case insights, profile }
    @Bindable var store: AppStore
    @State private var segment: Segment = .insights
    @State private var selectedCategory: String?
    @State private var activeRecipe: InsightLens?
    @State private var pendingRecipeAction: RecipeExitAction?
    @State private var showHistory = false
    @State private var pendingHistoryReport: InsightReport?
    @State private var lensEditor: LensEditorRoute?
    @State private var pendingReportAction: ReportExitAction?

    private struct LensEditorRoute: Identifiable { let id = UUID(); let lens: InsightLens? }
    private enum RecipeExitAction { case run, edit(InsightLens) }
    private enum ReportExitAction { case followUp(InsightReport), askNote(Note), openTag(String) }

    private var categories: [String?] {
        let builtin: [String?] = [nil, "复盘整理", "自我觉察", "思维决策", "大师视角"]
        return store.insights.lenses.contains { !$0.builtin } ? builtin + ["我的"] : builtin
    }

    var body: some View {
        @Bindable var insights = store.insights
        NavigationStack {
            Group {
                if segment == .insights { recipeBoard }
                else { ProfileWorkspaceView(store: store) }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(segment == .insights ? "洞察" : "画像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("视图", selection: $segment) {
                        Text("洞察").tag(Segment.insights)
                        Text("画像").tag(Segment.profile)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if segment == .insights {
                        IconAction(symbol: "clock.arrow.circlepath", label: "历史", id: "insights-history-button") {
                            showHistory = true
                        }
                        IconAction(symbol: "plus", label: "新建视角", id: "insights-new-lens-button") {
                            lensEditor = LensEditorRoute(lens: nil)
                        }
                    }
                }
            }
        }
        .sheet(item: $activeRecipe, onDismiss: finishRecipe) { lens in
            RecipeRunSheet(store: store, lens: lens,
                           onRun: { exitRecipe(with: .run) },
                           onEdit: { exitRecipe(with: .edit(lens)) })
        }
        .sheet(isPresented: $showHistory, onDismiss: {
            guard let report = pendingHistoryReport else { return }
            pendingHistoryReport = nil
            if let api = store.api { insights.openReport(report, api: api) }
        }) {
            InsightReportsHistorySheet(insights: insights) { report in
                pendingHistoryReport = report
                showHistory = false
            }
        }
        .sheet(isPresented: $insights.showReport, onDismiss: {
            insights.stopReport()
            guard let action = pendingReportAction else { return }
            pendingReportAction = nil
            switch action {
            case .followUp(let report): store.askAbout(report)
            case .askNote(let note): store.askAbout(note)
            case .openTag(let tag): store.openTag(tag)
            }
        }) {
            InsightReportSheet(store: store,
                               followUp: { exitReport(with: .followUp($0)) },
                               onAskNote: { exitReport(with: .askNote($0)) },
                               onOpenTag: { exitReport(with: .openTag($0)) })
        }
        .sheet(item: $lensEditor) { route in CustomLensSheet(store: store, lens: route.lens) }
        .task(id: store.api != nil) {
            if let api = store.api { await insights.loadLibrary(api: api) }
        }
        .onChange(of: insights.lenses.map(\.id)) { _, _ in
            selectedCategory = InsightsStore.resolvedCategory(selectedCategory, for: insights.lenses)
        }
    }

    private func exitRecipe(with action: RecipeExitAction) {
        pendingRecipeAction = action
        activeRecipe = nil
    }

    private func finishRecipe() {
        guard let action = pendingRecipeAction else { return }
        pendingRecipeAction = nil
        switch action {
        case .run:
            if let api = store.api { store.insights.run(api: api, options: store.options) }
        case .edit(let lens): lensEditor = LensEditorRoute(lens: lens)
        }
    }

    private func exitReport(with action: ReportExitAction) {
        pendingReportAction = action
        store.insights.showReport = false
    }

    private var recipeBoard: some View {
        let insights = store.insights
        let recipes = InsightsStore.filteredLenses(insights.lenses, category: selectedCategory)
        return VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(categories, id: \.self) { category in
                        Button { selectedCategory = category } label: {
                            Chip(text: category ?? "全部", selected: selectedCategory == category)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            ScrollView {
                if recipes.isEmpty {
                    if insights.error != nil { InlineError(message: insights.error).padding(16) }
                    else { Text("暂无配方").foregroundStyle(Theme.ink3).padding(.top, 32) }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(recipes) { lens in
                            Button {
                                insights.prepareRecipe(lens, api: store.api)
                                activeRecipe = lens
                            } label: { recipeCard(lens) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("insights-recipe-card-\(lens.id)")
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func recipeCard(_ lens: InsightLens) -> some View {
        let (symbol, accent): (String, ThemeAccent) = switch (lens.builtin, lens.category) {
        case (true, "复盘整理"): ("square.stack", .pine)
        case (true, "自我觉察"): ("waveform.path", .plum)
        case (true, "思维决策"): ("point.3.connected.trianglepath.dotted", .indigo)
        case (true, "大师视角"): ("book.closed", .clay)
        default: ("slider.horizontal.3", .graphite)
        }
        let shape = RoundedRectangle(cornerRadius: 18)
        return VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(Theme.TypeScale.body.weight(.semibold)).foregroundStyle(accent.active)
                .frame(width: 34, height: 34)
                .background(accent.accentSoft, in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            Text(lens.name).font(Theme.TypeScale.itemTitle).foregroundStyle(Theme.ink).lineLimit(1)
            Text(lens.description).font(Theme.TypeScale.body).foregroundStyle(Theme.ink2)
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 4) {
                Text(lens.category).foregroundStyle(accent.active)
                Spacer(minLength: 0)
                Text(recipeRangeLabel(lens.suggestedRange ?? "7d")).foregroundStyle(Theme.ink3)
            }
            .font(Theme.TypeScale.meta)
            .lineLimit(1)
        }
        .multilineTextAlignment(.leading)
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Theme.paper)
            shape.fill(RadialGradient(colors: [accent.tone.opacity(0.12), .clear], center: .topTrailing,
                                      startRadius: 6, endRadius: 110))
        }
        .overlay { shape.strokeBorder(Theme.hairline).allowsHitTesting(false) }
        .contentShape(shape)
    }
}

private func recipeRangeLabel(_ range: String) -> String {
    switch range {
    case "week": "本周"
    case "month": "本月"
    case "all": "全部"
    case "custom": "自定义"
    default: "近 7 天"
    }
}

private struct RecipeRunSheet: View {
    let store: AppStore
    let lens: InsightLens
    let onRun: () -> Void
    let onEdit: () -> Void
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var endDate = Date.now
    private var insights: InsightsStore { store.insights }

    var body: some View {
        @Bindable var insights = store.insights
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(lens.name).font(Theme.TypeScale.pageTitle).foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        if !lens.builtin {
                            Spacer(minLength: 8)
                            Button("编辑", action: onEdit).buttonStyle(.weijiSecondary)
                        }
                    }
                    Text(lens.description).font(Theme.TypeScale.body).foregroundStyle(Theme.ink2).lineSpacing(4)
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            rangeMenu
                            if !store.index.exactTags.isEmpty { tagMenu }
                            Toggle(isOn: $insights.useProfile) {
                                Chip(text: "结合个人画像", symbol: "person.crop.circle", selected: insights.useProfile)
                            }
                            .toggleStyle(.button)
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollIndicators(.hidden)
                    if insights.scope.range == "custom" {
                        HStack(spacing: 8) {
                            DatePicker("起始日期", selection: $startDate, displayedComponents: .date).labelsHidden()
                            Text("至").font(Theme.TypeScale.meta).foregroundStyle(Theme.ink3)
                            DatePicker("结束日期", selection: $endDate, displayedComponents: .date).labelsHidden()
                        }
                    }
                    InlineError(message: insights.error)
                    VStack(alignment: .leading, spacing: 10) {
                        if let stats = insights.stats {
                            Text(stats.label).font(Theme.TypeScale.meta.monospacedDigit()).foregroundStyle(Theme.ink2)
                                .accessibilityIdentifier("insights-preview-stats")
                        } else if store.api != nil && insights.error == nil {
                            ProgressView().controlSize(.small).accessibilityLabel("正在计算笔记范围")
                        }
                        Button(action: onRun) { Label("开始分析", systemImage: "sparkles") }
                            .buttonStyle(.weijiPrimaryWide)
                            .disabled(store.api == nil || (insights.stats?.noteCount ?? 0) == 0)
                            .accessibilityIdentifier("insights-run-button")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 18)
        .onChange(of: startDate) { _, _ in if insights.scope.range == "custom" { applyDates() } }
        .onChange(of: endDate) { _, _ in if insights.scope.range == "custom" { applyDates() } }
        .weijiSheetBackground()
        .presentationBackground(Theme.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var rangeMenu: some View {
        Menu {
            Picker("时间范围", selection: Binding(get: { insights.scope.range }, set: selectRange)) {
                ForEach(["7d", "week", "month", "all", "custom"], id: \.self) { range in
                    Text(range == "custom" ? "自定义日期" : recipeRangeLabel(range)).tag(range)
                }
            }
        } label: {
            Chip(text: recipeRangeLabel(insights.scope.range), symbol: "calendar", selected: insights.scope.range != "all")
        }
        .accessibilityLabel("时间范围")
        .accessibilityValue(recipeRangeLabel(insights.scope.range))
    }

    private var tagMenu: some View {
        let active = !insights.scope.tags.isEmpty
        return Menu {
            Picker("匹配方式", selection: Binding(get: { insights.scope.tagMode }, set: { mode in
                updateScope { $0.tagMode = mode }
            })) {
                Text("任一标签").tag("any")
                Text("全部标签").tag("all")
            }
            if active {
                Button("清除已选标签", role: .destructive) { updateScope { $0.tags = [] } }
            }
            ForEach(store.index.exactTags, id: \.self) { tag in
                Button {
                    updateScope {
                        if $0.tags.contains(tag) { $0.tags.removeAll { $0 == tag } }
                        else if $0.tags.count < 20 { $0.tags.append(tag) }
                    }
                } label: {
                    if insights.scope.tags.contains(tag) { Label("#" + tag, systemImage: "checkmark") }
                    else { Text("#" + tag) }
                }
            }
        } label: {
            Chip(text: active ? "标签 \(insights.scope.tags.count)" : "全部标签", symbol: "number", selected: active)
        }
        .accessibilityLabel("筛选标签")
        .accessibilityValue(insights.scope.tags.joined(separator: "、"))
    }

    private func selectRange(_ range: String) {
        if range == "custom" { applyDates() }
        else {
            updateScope {
                $0.range = range
                $0.startDate = nil
                $0.endDate = nil
            }
        }
    }

    private func updateScope(_ change: (inout InsightScope) -> Void) {
        var scope = insights.scope
        change(&scope)
        guard scope != insights.scope else { return }
        insights.scope = scope
        if let api = store.api { insights.preview(api: api) }
    }

    private func applyDates() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let end = max(startDate, endDate)
        let startText = formatter.string(from: startDate)
        let endText = formatter.string(from: end)
        if endDate != end { endDate = end }
        guard insights.scope.range != "custom" || insights.scope.startDate != startText || insights.scope.endDate != endText else { return }
        insights.applyCustomDateRange(start: startText, end: endText, api: store.api)
    }
}

private struct InsightReportsHistorySheet: View {
    let insights: InsightsStore
    let onSelect: (InsightReport) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if insights.reports.isEmpty {
                    Text("暂无历史报告").font(Theme.TypeScale.body).foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity).padding(.top, 32)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(insights.reports) { report in
                            Button { onSelect(report) } label: { reportCard(report) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("insight-report-row-\(report.id)")
                        }
                    }
                    .padding(16)
                }
            }
            .weijiSheetBackground()
            .navigationTitle("历史报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(Theme.active)
        .presentationBackground(Theme.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func reportCard(_ report: InsightReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(report.lensName).foregroundStyle(Theme.active).lineLimit(1)
                Spacer(minLength: 8)
                Text(String(report.createdAt.prefix(10))).monospacedDigit().foregroundStyle(Theme.ink3)
            }
            .font(Theme.TypeScale.meta)
            HStack {
                Text(report.title).font(Theme.TypeScale.itemTitle).foregroundStyle(Theme.ink).lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
            }
            if let excerpt = report.excerpt, !excerpt.isEmpty {
                Text(excerpt).font(Theme.TypeScale.body).foregroundStyle(Theme.ink2).lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
        .noteCard(padding: 16, cornerRadius: 16)
    }
}
