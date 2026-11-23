import SwiftUI

struct InsightReportSheet: View {
    let store: AppStore
    let followUp: (InsightReport) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cited: AppStore.Detail?
    @State private var askCited: Note?
    private var insights: InsightsStore { store.insights }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if insights.reportText.isEmpty && insights.running {
                        ProgressView("正在生成").frame(maxWidth: .infinity).padding(.top, 22)
                    }
                    MarkdownBlockView(text: insights.reportText, citations: insights.report?.citations ?? []) { id in
                        Task {
                            if let note = await store.resolveNote(id) { cited = .init(note: note) }
                        }
                    }
                    InlineError(message: insights.reportError ?? store.error)
                }.padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle(insights.report?.title ?? insights.selectedLens?.name ?? "洞察")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if insights.running {
                        Button("停止") { insights.stopReport() }
                    } else if let report = insights.report {
                        Button("继续追问") { followUp(report) }.accessibilityIdentifier("insight-followup-button")
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
    }
}
