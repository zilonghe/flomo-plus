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
            HStack(spacing: 2) {
                segmentButton(.insights, title: "AI 洞察")
                segmentButton(.profile, title: "个人画像")
            }
            .padding(3)
            .background(Theme.subtle, in: Capsule())
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
            if segment == .insights { library(insights) }
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

    private func segmentButton(_ value: Segment, title: String) -> some View {
        let selected = segment == value
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { segment = value }
        } label: {
            Text(title).font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                .frame(maxWidth: .infinity, minHeight: 34)
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

    private func library(_ insights: InsightsStore) -> some View {
        @Bindable var insights = insights
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("范围").padding(.top, 8)
                VStack(spacing: 0) {
                    FormRow("时间") {
                        Picker("日期范围", selection: $insights.scope.range) {
                            Text("全部").tag("all")
                            Text("近 7 天").tag("7d")
                            Text("本周").tag("week")
                            Text("本月").tag("month")
                            Text("自定义").tag("custom")
                        }
                        .pickerStyle(.menu).labelsHidden().tint(Theme.active)
                    }
                    if insights.scope.range == "custom" {
                        FormDivider()
                        FormRow("起始") { DatePicker("起始", selection: $startDate, displayedComponents: .date).labelsHidden() }
                        FormDivider()
                        FormRow("结束") {
                            DatePicker("结束", selection: $endDate, in: startDate..., displayedComponents: .date).labelsHidden()
                        }
                    }
                    if !store.index.exactTags.isEmpty {
                        FormDivider()
                        FormRow("标签") { tagMenu(insights) }
                    }
                    FormDivider()
                    FormRow("笔记") {
                        if let stats = insights.stats {
                            Text(stats.label).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                                .accessibilityIdentifier("insights-preview-stats")
                        } else if store.api != nil && insights.error == nil {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .noteCard(padding: 0)

                HStack {
                    SectionLabel("视角")
                    Spacer()
                    Button("新建") { lensEditor = LensEditorRoute(lens: nil) }
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.active)
                        .padding(.horizontal, 4)
                }
                .padding(.top, 12)
                VStack(spacing: 0) {
                    Button { choosingLens = true } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(insights.selectedLens?.name ?? "选择视角")
                                    .font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                                if let lens = insights.selectedLens {
                                    Text(lens.description).font(.footnote).foregroundStyle(Theme.ink2)
                                        .lineSpacing(2).multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("分析视角")
                    .accessibilityValue(insights.selectedLens?.name ?? "")
                    .accessibilityIdentifier("insights-lens-picker")
                    if let lens = insights.selectedLens, !lens.builtin {
                        FormDivider()
                        Button { lensEditor = LensEditorRoute(lens: lens) } label: {
                            FormRow("自定义视角") {
                                Text("编辑").foregroundStyle(Theme.active)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    FormDivider()
                    Toggle("结合个人画像", isOn: $insights.useProfile)
                        .font(.subheadline).foregroundStyle(Theme.ink)
                        .tint(Theme.accent)
                        .padding(.horizontal, 14).frame(minHeight: 48)
                }
                .noteCard(padding: 0)

                InlineError(message: insights.error).padding(.top, 4)
                Button {
                    if let api = store.api { insights.run(api: api, options: store.options) }
                } label: {
                    Label("生成洞察", systemImage: "sparkles")
                }
                .buttonStyle(.weijiPrimaryWide)
                .disabled((insights.stats?.noteCount ?? 0) == 0 || insights.selectedLens == nil)
                .accessibilityIdentifier("insights-run-button")
                .padding(.top, 12)

                if !insights.reports.isEmpty {
                    SectionLabel("历史报告").padding(.top, 20)
                    VStack(spacing: 0) {
                        ForEach(Array(insights.reports.enumerated()), id: \.element.id) { offset, report in
                            if offset > 0 { FormDivider() }
                            Button {
                                if let api = store.api { insights.openReport(report, api: api) }
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(report.title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Text(String(report.createdAt.prefix(10)))
                                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.ink3)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("insight-report-row-\(report.id)")
                        }
                    }
                    .noteCard(padding: 0)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .onChange(of: insights.scope.range) { _, _ in updateDates() }
        .onChange(of: startDate) { _, _ in updateDates() }
        .onChange(of: endDate) { _, _ in updateDates() }
        .onChange(of: insights.scope) { _, _ in if let api = store.api { insights.preview(api: api) } }
    }

    private func tagMenu(_ insights: InsightsStore) -> some View {
        @Bindable var insights = insights
        return Menu {
            Picker("匹配", selection: $insights.scope.tagMode) {
                Text("任一标签").tag("any")
                Text("全部标签").tag("all")
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
            HStack(spacing: 4) {
                Text(insights.scope.tags.isEmpty ? "全部" : insights.scope.tags.map { "#" + $0 }.joined(separator: " · "))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline).foregroundStyle(Theme.active)
        }
        .accessibilityLabel("筛选标签")
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

/// Label-left, value-right row used inside grouped cards.
private struct FormRow<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline).foregroundStyle(Theme.ink2)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

private struct FormDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
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
                            Text(lens.name).font(.body.weight(selected ? .semibold : .regular)).foregroundStyle(Theme.ink)
                            Text(lens.description).font(.footnote).foregroundStyle(Theme.ink2).lineLimit(3)
                        }
                        Spacer(minLength: 8)
                        if selected {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.active)
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
