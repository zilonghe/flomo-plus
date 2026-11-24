import SwiftUI

struct InsightReportSheet: View {
    let store: AppStore
    let followUp: (InsightReport) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cited: AppStore.Detail?
    @State private var askCited: Note?
    @State private var confirmDelete = false
    private var insights: InsightsStore { store.insights }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let report = insights.report, let api = store.api {
                        if confirmDelete {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("删除这份报告？").font(.subheadline)
                                HStack {
                                    Button("取消") { confirmDelete = false }
                                    Spacer()
                                    Button("确认删除", role: .destructive) {
                                        Task { await insights.deleteReport(report.id, api: api) }
                                    }
                                    .accessibilityIdentifier("insight-report-confirm-delete")
                                }.buttonStyle(.bordered)
                            }.noteCard()
                            .disabled(insights.deletingReport)
                        } else {
                            Button("删除报告", role: .destructive) { confirmDelete = true }
                                .font(.subheadline)
                                .accessibilityIdentifier("insight-report-delete-button")
                        }
                    }
                    InlineError(message: insights.reportError ?? store.error)
                    if insights.reportText.isEmpty && insights.running {
                        ProgressView("正在生成").frame(maxWidth: .infinity).padding(.top, 22)
                    }
                    MarkdownBlockView(text: insights.reportText, citations: insights.report?.citations ?? []) { id in
                        Task {
                            if let note = await store.resolveNote(id) { cited = .init(note: note) }
                        }
                    }
                }.padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle(insights.report?.title ?? insights.selectedLens?.name ?? "洞察")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(insights.deletingReport)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if insights.running {
                        Button("停止") { insights.stopReport() }
                    } else if let report = insights.report {
                        Button("继续追问") { followUp(report) }
                            .disabled(insights.deletingReport)
                            .accessibilityIdentifier("insight-followup-button")
                    }
                }
            }
            .sheet(item: $cited, onDismiss: {
                if let askCited {
                    self.askCited = nil
                    dismiss()
                    store.askAbout(askCited)
                }
            }) { item in
                NoteDetailSheet(store: store, note: item.note) { askCited = item.note }
            }
        }
        .interactiveDismissDisabled(insights.deletingReport)
    }
}
