import SwiftUI

struct InsightsTabView: View {
    enum Segment: String { case insights, profile }
    @Bindable var store: AppStore
    @State private var segment: Segment = .insights
    @State private var lensEditor: LensEditorRoute?
    @State private var choosingLens = false
    @State private var followup: InsightReport?
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var endDate = Date.now
    @Namespace private var segmentSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct LensEditorRoute: Identifiable { let id = UUID(); let lens: InsightLens? }

    var body: some View {
        @Bindable var insights = store.insights
        VStack(spacing: 0) {
            header.screenHeader()
            if segment == .insights { studio(insights) }
            else { ProfileWorkspaceView(store: store) }
        }
        .sheet(isPresented: $insights.showReport, onDismiss: {
            insights.stopReport()
            if let followup { store.askAbout(followup); self.followup = nil }
        }) {
            InsightReportSheet(store: store) { report in
                followup = report
                insights.showReport = false
            }
        }
        .sheet(item: $lensEditor) { route in CustomLensSheet(store: store, lens: route.lens) }
        .sheet(isPresented: $choosingLens) { LensPickerSheet(insights: insights) }
        .task {
            if let api = store.api {
                insights.preview(api: api)
                await insights.loadLibrary(api: api)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("洞察")
                .font(Theme.TypeScale.pageTitle)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                segmentButton(.insights, title: "洞察")
                segmentButton(.profile, title: "画像")
            }
            .padding(3)
            .background(Theme.subtle, in: Capsule())
        }
    }

    private func segmentButton(_ value: Segment, title: String) -> some View {
        let selected = segment == value
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { segment = value }
        } label: {
            Text(title)
                .font(Theme.TypeScale.meta.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background {
                    if selected {
                        Capsule().fill(Theme.paper)
                            .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
                            .matchedGeometryEffect(id: "segment", in: segmentSelection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("insights-segment-" + value.rawValue)
    }

    private func studio(_ insights: InsightsStore) -> some View {
        @Bindable var insights = insights
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                studioCard(insights)
                reportsSection(insights)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .onChange(of: insights.scope.range) { _, _ in updateDates() }
        .onChange(of: startDate) { _, _ in updateDates() }
        .onChange(of: endDate) { _, _ in updateDates() }
        .onChange(of: insights.scope) { _, _ in if let api = store.api { insights.preview(api: api) } }
    }

    private func studioCard(_ insights: InsightsStore) -> some View {
        @Bindable var insights = insights
        let lens = insights.selectedLens
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(lens?.category ?? "分析视角")
                    .font(Theme.TypeScale.meta.weight(.medium))
                    .foregroundStyle(Theme.active)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                    .background(Theme.accentSoft, in: Capsule())
                Spacer(minLength: 8)
                if let lens, !lens.builtin {
                    Button("编辑") { lensEditor = LensEditorRoute(lens: lens) }
                        .font(Theme.TypeScale.meta.weight(.medium))
                        .foregroundStyle(Theme.ink2)
                }
                Button {
                    lensEditor = LensEditorRoute(lens: nil)
                } label: {
                    Label("新建视角", systemImage: "plus")
                        .font(Theme.TypeScale.meta.weight(.medium))
                        .foregroundStyle(Theme.active)
                }
                .buttonStyle(.plain)
            }

            Button {
                choosingLens = true
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(lens?.name ?? "选择视角")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                    }
                    if let description = lens?.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.TypeScale.body)
                            .foregroundStyle(Theme.ink2)
                            .lineSpacing(4)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分析视角")
            .accessibilityValue(lens?.name ?? "")
            .accessibilityIdentifier("insights-lens-picker")

            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        rangeMenu(insights)
                        if !store.index.exactTags.isEmpty {
                            tagMenu(insights)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                if insights.scope.range == "custom" {
                    HStack(spacing: 10) {
                        DatePicker("起始", selection: $startDate, displayedComponents: .date)
                            .labelsHidden()
                        Text("至").font(Theme.TypeScale.meta).foregroundStyle(Theme.ink3)
                        DatePicker("结束", selection: $endDate, in: startDate..., displayedComponents: .date)
                            .labelsHidden()
                    }
                }

                HStack(spacing: 8) {
                    if let stats = insights.stats {
                        Text(stats.label)
                            .font(Theme.TypeScale.meta.monospacedDigit())
                            .foregroundStyle(Theme.ink2)
                            .accessibilityIdentifier("insights-preview-stats")
                    } else if store.api != nil && insights.error == nil {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 8)
                }

                Toggle(isOn: $insights.useProfile) {
                    Text("结合个人画像")
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
            }

            InlineError(message: insights.error)

            Button {
                if let api = store.api { insights.run(api: api, options: store.options) }
            } label: {
                Label("生成洞察", systemImage: "sparkles")
            }
            .buttonStyle(.weijiPrimaryWide)
            .disabled((insights.stats?.noteCount ?? 0) == 0 || lens == nil)
            .accessibilityIdentifier("insights-run-button")
        }
        .noteCard(padding: 18, cornerRadius: 20)
    }

    private func rangeMenu(_ insights: InsightsStore) -> some View {
        @Bindable var insights = insights
        return Menu {
            Picker("时间范围", selection: $insights.scope.range) {
                Text("全部时间").tag("all")
                Text("近 7 天").tag("7d")
                Text("本周").tag("week")
                Text("本月").tag("month")
                Text("自定义日期").tag("custom")
            }
        } label: {
            filterPill(symbol: "calendar", text: rangeLabel(insights.scope.range), active: insights.scope.range != "all")
        }
        .accessibilityLabel("时间范围")
    }

    private func tagMenu(_ insights: InsightsStore) -> some View {
        @Bindable var insights = insights
        let active = !insights.scope.tags.isEmpty
        let title = active ? insights.scope.tags.map { "#" + $0 }.joined(separator: " · ") : "全部标签"
        return Menu {
            Picker("匹配方式", selection: $insights.scope.tagMode) {
                Text("任一标签").tag("any")
                Text("全部标签").tag("all")
            }
            if active {
                Button("清除已选标签", role: .destructive) { insights.scope.tags.removeAll() }
            }
            ForEach(store.index.exactTags, id: \.self) { tag in
                Button {
                    if insights.scope.tags.contains(tag) { insights.scope.tags.removeAll { $0 == tag } }
                    else if insights.scope.tags.count < 20 { insights.scope.tags.append(tag) }
                } label: {
                    if insights.scope.tags.contains(tag) { Label("#" + tag, systemImage: "checkmark") }
                    else { Text("#" + tag) }
                }
            }
        } label: {
            filterPill(symbol: "number", text: title, active: active)
        }
        .accessibilityLabel("筛选标签")
    }

    private func filterPill(symbol: String, text: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.active : Theme.ink3)
            Text(text)
                .font(Theme.TypeScale.meta.weight(.medium))
                .foregroundStyle(active ? Theme.active : Theme.ink)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? Theme.active : Theme.ink3)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(active ? Theme.accentSoft : Theme.subtle, in: Capsule())
    }

    private func reportsSection(_ insights: InsightsStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("历史报告")
                Spacer()
                if !insights.reports.isEmpty {
                    Text("\(insights.reports.count) 篇")
                        .font(Theme.TypeScale.meta.monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 4)
                }
            }

            if insights.reports.isEmpty {
                Text("生成的洞察报告会保存在这里")
                    .font(Theme.TypeScale.meta)
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .noteCard(padding: 16, cornerRadius: 16)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(insights.reports) { report in
                        Button {
                            if let api = store.api { insights.openReport(report, api: api) }
                        } label: {
                            reportCard(report)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("insight-report-row-\(report.id)")
                    }
                }
            }
        }
    }

    private func reportCard(_ report: InsightReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(report.lensName)
                    .font(Theme.TypeScale.meta.weight(.medium))
                    .foregroundStyle(Theme.active)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(report.createdAt.prefix(10)))
                    .font(Theme.TypeScale.meta.monospacedDigit())
                    .foregroundStyle(Theme.ink3)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.title)
                        .font(Theme.TypeScale.itemTitle)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let excerpt = report.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(Theme.TypeScale.body)
                            .foregroundStyle(Theme.ink2)
                            .lineSpacing(3)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, 4)
            }
        }
        .noteCard(padding: 16, cornerRadius: 16)
    }

    private func rangeLabel(_ value: String) -> String {
        switch value {
        case "7d": "近 7 天"
        case "week": "本周"
        case "month": "本月"
        case "custom": "自定义"
        default: "全部时间"
        }
    }

    private func updateDates() {
        let current = store.insights.scope
        var next = current
        if next.range == "custom" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            next.startDate = formatter.string(from: startDate)
            next.endDate = formatter.string(from: max(startDate, endDate))
        } else {
            next.startDate = nil
            next.endDate = nil
        }
        if next != current { store.insights.scope = next }
    }
}

/// Clean list instead of a system Menu, so each lens shows its description and nothing glassy floats over the run button.
private struct LensPickerSheet: View {
    @Bindable var insights: InsightsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(insights.lenses) { lens in
                let selected = insights.lensId == lens.id
                Button {
                    insights.lensId = lens.id
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lens.name)
                                .font(Theme.TypeScale.itemTitle.weight(selected ? .semibold : .medium))
                                .foregroundStyle(Theme.ink)
                            Text(lens.description)
                                .font(Theme.TypeScale.meta)
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 8)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.active)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.paper)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("insights-lens-\(lens.id)")
            }
            .weijiSheetBackground()
            .navigationTitle("分析视角")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(Theme.active)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
