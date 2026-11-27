import SwiftUI

struct SessionsDrawerView: View {
    let store: AppStore
    let onClose: () -> Void
    private var chat: AIChatStore { store.chat }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史会话").font(.title3.bold()).foregroundStyle(Theme.ink)
                Spacer()
                IconAction(symbol: "xmark", label: "关闭历史会话", id: "ai-sessions-close", action: onClose)
                    .foregroundStyle(Theme.ink2)
                    .padding(.trailing, -10)
            }
            .padding(.horizontal, 16).frame(minHeight: 52)

            Button {
                store.requestNewChat()
                if store.pendingChatSwitch == nil { onClose() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.subheadline.weight(.semibold))
                    Text("新建对话").font(Theme.TypeScale.body.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(Theme.active)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Theme.accentSoft, in: .rect(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .accessibilityIdentifier("ai-drawer-new-button")

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(chat.sessions) { session in
                        sessionRow(session)
                    }
                    if chat.loadingList {
                        ProgressView().padding(.vertical, 16)
                    } else if chat.cursor != nil {
                        Button("加载更多") {
                            if let api = store.api { chat.refreshSessions(api: api, more: true) }
                        }
                        .buttonStyle(.weijiSecondary)
                        .padding(.top, 8)
                    } else if chat.sessions.isEmpty {
                        Text("暂无历史会话")
                            .font(Theme.TypeScale.meta)
                            .foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 36)
                    }
                    InlineError(message: chat.error).padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            if let api = store.api { chat.refreshSessions(api: api) }
        }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        let selected = chat.session?.id == session.id
        return HStack(spacing: 8) {
            Button {
                store.requestSelectChatSession(session.id)
                if store.pendingChatSwitch == nil { onClose() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(Theme.TypeScale.body.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.active : Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(origin(session.origin)) · \(String(session.updatedAt.prefix(10)))")
                        .font(Theme.TypeScale.meta.monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("删除会话", systemImage: "trash", role: .destructive) {
                    if let api = store.api { Task { await chat.remove(session.id, api: api) } }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("管理会话")
        }
        .background(selected ? Theme.accentSoft : Theme.paper, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Theme.active.opacity(0.25) : Theme.hairline)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("删除会话", systemImage: "trash", role: .destructive) {
                if let api = store.api { Task { await chat.remove(session.id, api: api) } }
            }
        }
        .accessibilityIdentifier("ai-session-row-\(session.id)")
    }

    private func origin(_ value: String) -> String {
        switch value {
        case "note": "笔记"
        case "insight": "洞察"
        default: "全库"
        }
    }
}
