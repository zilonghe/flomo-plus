import SwiftUI

struct InsightsTabView: View {
    enum Segment: String { case insights, profile }
    @Bindable var store: AppStore
    @State private var segment: Segment = .insights
    @State private var lensEditor: LensEditorRoute?
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var endDate = Date.now

    private struct LensEditorRoute: Identifiable { let id = UUID(); let lens: InsightLens? }

    var body: some View {
        @Bindable var insights = store.insights
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                segmentButton(.insights, title: "AI 洞察")
                segmentButton(.profile, title: "个人画像")
            }.padding(4)
                .background(Theme.line.opacity(0.6), in: .rect(cornerRadius: 11))
                .padding(.horizontal, 16).padding(.vertical, 8)
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
        .task {
            if let api = store.api {
                insights.preview(api: api)
                await insights.loadLibrary(api: api)
            }
        }
    }

    @State private var followup: InsightReport?

    private func segmentButton(_ value: Segment, title: String) -> some View {
        Button {
            segment = value
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(segment == value ? Theme.ink : .secondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(segment == value ? Theme.paper : .clear, in: .rect(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(segment == value ? .isSelected : [])
        .accessibilityIdentifier("insights-segment-" + value.rawValue)
    }

    private func library(_ insights: InsightsStore) -> some View {
        @Bindable var insights = insights
        return ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 11) {
                    Text("范围").font(.headline)
                    Picker("日期范围", selection: $insights.scope.range) {
                        Text("全部").tag("all")
                        Text("近 7 天").tag("7d")
                        Text("本周").tag("week")
                        Text("本月").tag("month")
                        Text("自定义").tag("custom")
                    }.pickerStyle(.menu).padding(.leading, -8)
                    if insights.scope.range == "custom" {
                        DatePicker("起始", selection: $startDate, displayedComponents: .date)
                        DatePicker("结束", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                    if !store.index.exactTags.isEmpty {
                        Menu {
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
                            Label(insights.scope.tags.isEmpty ? "筛选标签" : insights.scope.tags.map { "#" + $0 }.joined(separator: " · "),
                                  systemImage: "tag")
                                .font(.subheadline).lineLimit(1)
                        }
                    }
                    if let stats = insights.stats {
                        Text(stats.label).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.active)
                            .accessibilityIdentifier("insights-preview-stats")
                    } else if store.api != nil && insights.error == nil {
                        ProgressView().controlSize(.small)
                    }
                }.noteCard()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("视角").font(.headline)
                        Spacer()
                        Button("新建") { lensEditor = LensEditorRoute(lens: nil) }.font(.subheadline)
                    }
                    Picker("分析视角", selection: $insights.lensId) {
                        ForEach(insights.lenses) { lens in Text(lens.name).tag(lens.id) }
                    }.padding(.leading, -8)
                    if let lens = insights.selectedLens {
                        Text(lens.description).font(.subheadline).foregroundStyle(.secondary)
                        if !lens.builtin { Button("编辑视角") { lensEditor = LensEditorRoute(lens: lens) }.font(.subheadline) }
                    }
                    Toggle("结合个人画像", isOn: $insights.useProfile).font(.subheadline)
                }.noteCard()
                InlineError(message: insights.error)
                Button {
                    if let api = store.api { insights.run(api: api, options: store.options) }
                } label: {
                    Label("生成洞察", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled((insights.stats?.noteCount ?? 0) == 0 || insights.selectedLens == nil)
                .accessibilityIdentifier("insights-run-button")
                if !insights.reports.isEmpty {
                    Text("历史报告").font(.headline).padding(.top, 8)
                    ForEach(insights.reports) { report in
                        Button {
                            if let api = store.api { insights.openReport(report, api: api) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(report.title).font(.subheadline.weight(.semibold))
                                    Text(String(report.createdAt.prefix(10))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.noteCard()
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(16)
        }
        .onChange(of: insights.scope.range) { _, _ in updateDates() }
        .onChange(of: startDate) { _, _ in updateDates() }
        .onChange(of: endDate) { _, _ in updateDates() }
        .onChange(of: insights.scope) { _, _ in if let api = store.api { insights.preview(api: api) } }
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
