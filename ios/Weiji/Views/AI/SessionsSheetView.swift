import SwiftUI

struct SessionsDrawerView: View {
    let store: AppStore
    let onClose: () -> Void
    private var chat: AIChatStore { store.chat }
    @State private var reportToDelete: InsightReport?

    private enum Item: Identifiable {
        case session(ChatSession), report(InsightReport)

        var id: String {
            switch self {
            case .session(let session): "ai-session-row-" + session.id
            case .report(let report): "ai-report-row-" + report.id
            }
        }
        var title: String {
            switch self {
            case .session(let session): session.title
            case .report(let report): report.title
            }
        }
        var timestamp: String {
            switch self {
            case .session(let session): session.updatedAt
            case .report(let report): report.createdAt
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                IconAction(symbol: "xmark", label: "关闭历史", id: "ai-sessions-close", action: onClose)
            }
            .padding(.horizontal, 20)
            ScrollView {
                timeline
                    .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            if let api = store.api { chat.refreshSessions(api: api) }
        }
        .confirmationDialog("删除这份报告？", isPresented: Binding(
            get: { reportToDelete != nil }, set: { if !$0 { reportToDelete = nil } }
        ), titleVisibility: .visible, presenting: reportToDelete) { report in
            Button("删除报告", role: .destructive) {
                guard let api = store.api else { return }
                let selected = store.presentedReport?.id == report.id
                Task {
                    if await store.insights.deleteReport(report.id, api: api), selected {
                        store.requestNewChat()
                        if store.pendingChatSwitch == nil { onClose() }
                    }
                }
            }
        }
    }

    private var timeline: some View {
        let calendar = Calendar.current
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        let groups = Dictionary(grouping: chat.sessions.map(Item.session) + store.insights.reports.map(Item.report)) { item in
            guard let date = iso.date(from: item.timestamp) ?? seconds.date(from: item.timestamp) else { return 2 }
            if calendar.isDateInToday(date) { return 0 }
            return calendar.isDate(date, equalTo: .now, toGranularity: .weekOfYear) ? 1 : 2
        }
        return LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(groups.keys.sorted(), id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(["今天", "本周", "更早"][index])
                        .font(.footnote).tracking(0.5).foregroundStyle(Theme.ink2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach((groups[index] ?? []).sorted { $0.timestamp > $1.timestamp }) { row($0) }
                }
            }
            if chat.loadingList { ProgressView().minTapHeight() }
            else if chat.cursor != nil {
                Button("加载更多") {
                    if let api = store.api { chat.refreshSessions(api: api, more: true) }
                }.minTapHeight()
            } else if groups.isEmpty {
                Text("暂无历史").font(.footnote).foregroundStyle(Theme.ink2).padding(.top, 20)
            }
            InlineError(message: chat.error ?? store.insights.error)
        }
        .padding(.top, 12)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 0) {
            Button {
                switch item {
                case .session(let session): store.requestSelectChatSession(session.id)
                case .report(let report): store.requestViewReport(report)
                }
                if store.pendingChatSwitch == nil { onClose() }
            } label: {
                Text(item.title).font(.subheadline).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading).minTapHeight()
            }
            .buttonStyle(.plain)
            Menu {
                switch item {
                case .session(let session):
                    Button("删除对话", role: .destructive) {
                        if let api = store.api { Task { await chat.remove(session.id, api: api) } }
                    }
                case .report(let report):
                    Button("删除报告", role: .destructive) { reportToDelete = report }
                        .disabled(store.insights.deletingReport || (store.presentedReport?.id == report.id && chat.sending))
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.ink2).minTouchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("管理「\(item.title)」")
        }
        .accessibilityIdentifier(item.id)
    }
}
