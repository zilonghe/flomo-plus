import SwiftUI

struct InsightReportView: View {
    enum Mode { case live, saved(String) }

    let store: AppStore
    let mode: Mode
    let onCite: (Note) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var citationID: String?
    @State private var confirmDelete = false
    private var insights: InsightsStore { store.insights }

    private var isLive: Bool {
        if case .live = mode { return true }
        return false
    }

    private var isViewingSaved: Bool {
        if case .saved(let id) = mode { return insights.viewedReportID == id }
        return false
    }

    private var report: InsightReport? {
        isLive ? insights.liveReport : (isViewingSaved ? insights.viewedReport : nil)
    }

    private var text: String {
        isLive ? insights.liveReportText : (isViewingSaved ? insights.viewedReportText : "")
    }

    private var error: String? {
        isLive ? insights.liveReportError : (isViewingSaved ? insights.viewedReportError : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let report, let api = store.api {
                    deleteButton(report, api: api)
                }
                InlineError(message: error ?? store.error)
                if text.isEmpty, isLive ? insights.running : (isViewingSaved && insights.loadingReport) {
                    ProgressView(isLive ? "正在生成" : "正在读取")
                        .frame(maxWidth: .infinity).padding(.top, 22)
                }
                MarkdownBlockView(text: text, citations: report?.citations ?? []) { citationID = $0 }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(Theme.canvas)
        .navigationTitle(report?.title ?? (isLive ? insights.runningLensName : nil) ?? "洞察")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(insights.deletingReport)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isLive && insights.running {
                    Button("停止") { insights.stopReport() }.minTouchTarget()
                } else if let report {
                    Button("继续追问") { store.askAbout(report) }
                        .minTouchTarget()
                        .disabled(insights.deletingReport)
                        .accessibilityIdentifier("insight-followup-button")
                }
            }
        }
        .task(id: citationID) {
            guard let id = citationID else { return }
            let note = await store.resolveNote(id)
            guard !Task.isCancelled else { return }
            citationID = nil
            if let note { onCite(note) }
        }
        .onDisappear { citationID = nil }
    }

    @ViewBuilder
    private func deleteButton(_ report: InsightReport, api: WeijiAPIClient) -> some View {
        if confirmDelete {
            VStack(alignment: .leading, spacing: 8) {
                Text("删除这份报告？").font(.subheadline)
                HStack {
                    Button("取消") { confirmDelete = false }.buttonStyle(.weijiSecondary)
                    Spacer()
                    Button(role: .destructive) {
                        Task {
                            if await insights.deleteReport(report.id, api: api) { dismiss() }
                        }
                    } label: {
                        Text("确认删除").minTapHeight()
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .accessibilityIdentifier("insight-report-confirm-delete")
                }
            }
            .noteCard()
            .disabled(insights.deletingReport)
        } else {
            Button(role: .destructive) { confirmDelete = true } label: {
                Text("删除报告").font(.footnote.weight(.medium)).minTapHeight()
            }
            .accessibilityIdentifier("insight-report-delete-button")
        }
    }
}
