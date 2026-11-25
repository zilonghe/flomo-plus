import SwiftUI

struct SessionsSheetView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    private var chat: AIChatStore { store.chat }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chat.sessions) { session in
                    Button {
                        if let api = store.api { chat.select(session.id, api: api) }
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).font(.body).foregroundStyle(Theme.ink).lineLimit(2)
                            Text(origin(session.origin)).font(.caption).foregroundStyle(Theme.ink3)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.paper)
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            if let api = store.api { Task { await chat.remove(session.id, api: api) } }
                        }
                    }
                }
                if chat.loadingList { ProgressView() }
                else if chat.cursor != nil {
                    Button("加载更多") {
                        if let api = store.api { chat.refreshSessions(api: api, more: true) }
                    }
                } else if chat.sessions.isEmpty {
                    Text("暂无会话").foregroundStyle(Theme.ink3)
                }
                InlineError(message: chat.error)
            }
            .weijiSheetBackground()
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { if let api = store.api { chat.refreshSessions(api: api) } }
        }
        .tint(Theme.active)
    }

    private func origin(_ value: String) -> String {
        switch value {
        case "note": "笔记"
        case "insight": "洞察"
        default: "全库"
        }
    }
}
