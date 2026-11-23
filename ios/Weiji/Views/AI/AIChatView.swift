import SwiftUI

struct AIChatView: View {
    let store: AppStore
    @State private var showSessions = false
    @State private var showPins = false
    @State private var showAISettings = false
    @FocusState private var writing: Bool

    var body: some View {
        @Bindable var chat = store.chat
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                IconAction(symbol: "clock.arrow.circlepath", label: "会话", id: "ai-sessions-button") { showSessions = true }
                    .disabled(store.api == nil)
                Text(chat.session?.title ?? "AI 对话").font(.headline).lineLimit(1)
                Spacer()
                Button {
                    showAISettings = true
                } label: {
                    Text(store.options.model.isEmpty ? store.options.provider.label : store.options.model)
                        .font(.caption).lineLimit(1).padding(8).background(Theme.line.opacity(0.55), in: Capsule())
                }.buttonStyle(.plain)
                IconAction(symbol: "square.and.pencil", label: "新建会话", id: "ai-new-button") { chat.start() }
            }.screenHeader()
            if !chat.pins.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(chat.pins, id: \.self) { id in
                            Button {
                                writing = false
                                Task { await store.openNote(id) }
                            } label: {
                                Text(store.notesById[id].map { String($0.body.prefix(25)) } ?? "引用笔记")
                                    .lineLimit(1).font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("ai-pin-chip-" + id)
                            .contextMenu { Button("移除引用", role: .destructive) { chat.togglePin(id) } }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ai-pin-chip-list")
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .padding(.bottom, 8)
            }
            if let insight = chat.insight { Label(insight.title, systemImage: "chart.bar").font(.footnote).padding(8) }
            messages(chat)
            if let status = chat.status, chat.streamedText.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            InlineError(message: chat.error).padding(.horizontal, 16)
            HStack(alignment: .bottom, spacing: 4) {
                IconAction(symbol: "at", label: "置顶笔记", id: "ai-pin-picker-button") { showPins = true }
                TextField("问一问你的笔记", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($writing)
                    .padding(10)
                    .background(Theme.paper, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("ai-input-field")
                if chat.sending {
                    IconAction(symbol: "stop.circle.fill", label: "停止", id: "ai-stop-button") { chat.stop() }
                } else {
                    IconAction(symbol: "arrow.up.circle.fill", label: "发送", id: "ai-send-button") {
                        writing = false
                        if let api = store.api { chat.send(api: api, options: store.options, profile: store.insights) }
                    }
                    .disabled(store.api == nil || chat.loadingSession || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .sheet(isPresented: $showSessions) { SessionsSheetView(store: store) }
        .sheet(isPresented: $showPins) { PinPickerSheet(store: store) }
        .sheet(isPresented: $showAISettings) { AISettingsView(store: store) }
    }

    @State private var nearBottom = true

    private func messages(_ chat: AIChatStore) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let turns = chat.session?.turns {
                        ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                            if turn.role == "user" { question(turn.text, insight: index == 0 && chat.session?.origin == "insight") }
                            else { reply(turn.text, citations: turn.citations ?? []) }
                        }
                    } else if chat.pendingQuestion.isEmpty {
                        if chat.loadingSession { ProgressView().frame(maxWidth: .infinity).padding(24) }
                        else {
                            Text("和你的笔记聊聊").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 46)
                        }
                    }
                    if !chat.pendingQuestion.isEmpty { question(chat.pendingQuestion, insight: false) }
                    if !chat.streamedText.isEmpty { reply(chat.streamedText, citations: []) }
                    Color.clear.frame(height: 1).id("chat-bottom").accessibilityHidden(true)
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 100
            } action: { _, new in nearBottom = new }
            .onChange(of: chat.pendingQuestion) { _, new in
                if !new.isEmpty { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: chat.streamedText) { _, _ in
                if nearBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: chat.session?.version) { _, _ in
                if nearBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom {
                    Button { proxy.scrollTo("chat-bottom", anchor: .bottom) } label: {
                        Image(systemName: "arrow.down.circle.fill").font(.title2).padding(10)
                    }.accessibilityLabel("回到最新消息")
                }
            }
        }
    }

    private func question(_ text: String, insight: Bool) -> some View {
        let content = insight ? text.components(separatedBy: "\n\n[追问]\n").last ?? text : text
        return Text(content).textSelection(.enabled)
            .padding(12).background(Theme.green.opacity(0.13), in: .rect(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func reply(_ text: String, citations: [Citation]) -> some View {
        MarkdownBlockView(text: text, citations: citations) { id in
            writing = false
            Task { await store.openNote(id) }
        }.noteCard()
    }
}

private struct AISettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var error: String?

    var body: some View {
        @Bindable var chat = store.chat
        NavigationStack {
            Form {
                Picker("服务", selection: Binding(get: { store.options.provider }, set: store.setProvider)) {
                    if store.identity?.codexAvailable == true { Text("Codex").tag(AIProvider.codex) }
                    Text("OpenAI").tag(AIProvider.openai)
                }
                if store.options.provider == .openai {
                    SecureField("OpenAI API Key", text: $apiKey).autocorrectionDisabled()
                    TextField("模型", text: $store.options.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                } else if !store.gatewayModels.isEmpty {
                    Picker("模型", selection: $store.options.model) {
                        Text(store.gatewayDefault ?? "网关默认").tag("")
                        ForEach(store.gatewayModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("使用个人画像", isOn: $chat.useProfile)
                InlineError(message: error)
            }
            .navigationTitle("AI 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        do { try store.setAPIKey(apiKey); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .onAppear { apiKey = store.options.apiKey }
        }
    }
}
