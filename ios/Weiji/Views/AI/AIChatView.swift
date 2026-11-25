import SwiftUI

struct AIChatView: View {
    let store: AppStore
    @Binding var showSessions: Bool
    @State private var showPins = false
    @State private var showAISettings = false
    @State private var showModels = false
    @State private var sendFeedback = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var writing: Bool

    var body: some View {
        @Bindable var chat = store.chat
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                IconAction(symbol: "clock.arrow.circlepath", label: "历史会话", id: "ai-sessions-button") {
                    writing = false
                    showSessions = true
                }
                .disabled(store.api == nil)
                .padding(.leading, -10)
                Text(chat.session?.title ?? "AI 对话")
                    .font(chat.session == nil ? Theme.TypeScale.pageTitle : Theme.TypeScale.itemTitle)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer()
                IconAction(symbol: "slider.horizontal.3", label: "AI 设置", id: "ai-settings-button") { showAISettings = true }
                IconAction(symbol: "square.and.pencil", label: "新建会话", id: "ai-new-button") { chat.start() }
                    .padding(.trailing, -10)
            }.screenHeader()
            if !chat.pins.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(chat.pins, id: \.self) { id in
                            Button {
                                writing = false
                                Task { await store.openNote(id) }
                            } label: {
                                Chip(text: store.notesById[id].map { String($0.body.prefix(25)) } ?? "引用笔记",
                                     symbol: "pin.fill", selected: true)
                            }
                            .buttonStyle(.plain)
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
            if let insight = chat.insight {
                Label(insight.title, systemImage: "chart.bar").font(.footnote.weight(.medium)).foregroundStyle(Theme.ink2)
                    .lineLimit(1).padding(.horizontal, 16).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if chat.session == nil && chat.pendingQuestion.isEmpty && !chat.sending && !chat.loadingSession {
                emptyState(chat)
            } else {
                messages(chat)
            }
            InlineError(message: chat.error).padding(.horizontal, 16)
            composer(chat)
        }
        .sheet(isPresented: $showPins) { PinPickerSheet(store: store) }
        .sheet(isPresented: $showAISettings) { AISettingsView(store: store) }
        .sheet(isPresented: $showModels) { ModelPickerSheet(store: store) }
        .sensoryFeedback(.selection, trigger: store.options.model)
        .sensoryFeedback(.selection, trigger: store.options.reasoningEffort)
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedback)
    }

    private func composer(_ chat: AIChatStore) -> some View {
        @Bindable var chat = chat
        let canSend = store.api != nil && !chat.loadingSession
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            TextField("问一问你的笔记", text: $chat.draft, axis: .vertical)
                .id(chat.composerResetCount)
                .lineLimit(1...6)
                .focused($writing)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                .accessibilityIdentifier("ai-input-field")
            HStack(spacing: 4) {
                IconAction(symbol: "at", label: "置顶笔记", id: "ai-pin-picker-button") { showPins = true }
                    .foregroundStyle(Theme.ink2)
                modelControls
                Spacer(minLength: 4)
                if chat.sending {
                    composerButton(symbol: "stop.fill", label: "停止", id: "ai-stop-button", enabled: true) {
                        sendFeedback += 1
                        chat.stop()
                    }
                } else {
                    composerButton(symbol: "arrow.up", label: "发送", id: "ai-send-button", enabled: canSend) {
                        guard let api = store.api else { return }
                        sendFeedback += 1
                        chat.send(api: api, options: store.options, profile: store.insights)
                        writing = false
                    }
                }
            }
            .padding(.leading, 2).padding(.trailing, 8).padding(.bottom, 6)
        }
        .background {
            RoundedRectangle(cornerRadius: 22).fill(Theme.paper)
                .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
        }
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.hairline).allowsHitTesting(false) }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
    }

    private func composerButton(symbol: String, label: String, id: String, enabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(enabled ? 1 : 0.3), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var modelControls: some View {
        let model = store.selectedModelMeta
        let gatewayModel = store.selectedGatewayModel
        let vendor = ModelVendor(model?.vendor ?? (store.options.provider == .openai ? "openai" : "other"))
        return HStack(spacing: 4) {
            Button {
                if store.options.provider == .codex && !store.gatewayModelMeta.isEmpty { showModels = true }
                else { showAISettings = true }
            } label: {
                HStack(spacing: 5) {
                    vendor.badge.font(.caption2)
                    Text(model?.label ?? store.options.provider.label).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(Theme.subtle, in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("模型：\(model?.label ?? store.options.provider.label)")

            if let gatewayModel, !gatewayModel.selectableEfforts.isEmpty {
                Menu {
                    Picker("思考档位", selection: Binding(get: { store.options.reasoningEffort }, set: store.setReasoningEffort)) {
                        Text("自动").tag("")
                        ForEach(gatewayModel.selectableEfforts, id: \.self) { effort in Text(effortLabel(effort)).tag(effort) }
                    }
                } label: {
                    Label(effortLabel(store.options.reasoningEffort), systemImage: "brain")
                        .padding(.horizontal, 10).frame(minHeight: 30)
                        .background(Theme.subtle, in: Capsule())
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("思考档位：\(effortLabel(store.options.reasoningEffort))")
            }
        }
        .font(Theme.TypeScale.meta.weight(.medium))
        .foregroundStyle(Theme.ink2)
    }

    @State private var nearBottom = true

    private func messages(_ chat: AIChatStore) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let turns = chat.session?.turns {
                        ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                            if turn.role == "user" { question(turn.text, insight: index == 0 && chat.session?.origin == "insight") }
                            else {
                                if let steps = turn.steps, !steps.isEmpty {
                                    StepsTimelineView(steps: steps, openNote: openNote)
                                }
                                reply(turn.text, citations: turn.citations ?? [])
                            }
                        }
                    } else if chat.pendingQuestion.isEmpty && chat.loadingSession {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    }
                    if !chat.pendingQuestion.isEmpty { question(chat.pendingQuestion, insight: false) }
                    if chat.sending && !chat.pendingQuestion.isEmpty {
                        StepsTimelineView(steps: chat.liveSteps, reasoning: chat.liveReasoning,
                                          running: true, status: chat.status, openNote: openNote)
                    }
                    if !chat.streamedText.isEmpty { reply(chat.streamedText, citations: chat.liveCitations) }
                    Color.clear.frame(height: 1).id("chat-bottom").accessibilityHidden(true)
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 100
            } action: { _, new in nearBottom = new }
            .onChange(of: chat.pendingQuestion) { _, new in
                if !new.isEmpty { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: chat.streamedText) { _, text in
                guard nearBottom, !text.isEmpty else { return }
                withAnimation(reduceMotion ? nil : .linear(duration: 0.04)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: chat.session?.version) { _, _ in
                if nearBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom {
                    Button { proxy.scrollTo("chat-bottom", anchor: .bottom) } label: {
                        Image(systemName: "arrow.down").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 36, height: 36)
                            .background(Theme.paper, in: Circle())
                            .overlay { Circle().strokeBorder(Theme.hairline) }
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12).padding(.bottom, 4)
                    .accessibilityLabel("回到最新消息")
                }
            }
        }
    }

    private func question(_ text: String, insight: Bool) -> some View {
        let content = insight ? text.components(separatedBy: "\n\n[追问]\n").last ?? text : text
        return Text(content).textSelection(.enabled)
            .font(.callout).foregroundStyle(Theme.ink).lineSpacing(3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.accentSoft, in: .rect(cornerRadius: 18))
            .frame(maxWidth: 300, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 6)
    }

    private func reply(_ text: String, citations: [Citation]) -> some View {
        MarkdownBlockView(text: text, citations: citations, openCitation: openNote)
            .padding(.vertical, 2)
    }

    private static let starters = ["最近我在关注什么？", "帮我回顾这周的读书摘录", "我的笔记里有哪些反复出现的想法？"]

    private func emptyState(_ chat: AIChatStore) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.active)
                .frame(width: 56, height: 56)
                .background(Theme.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text("和你的笔记聊聊").font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            VStack(spacing: 8) {
                ForEach(Self.starters, id: \.self) { prompt in
                    Button {
                        chat.draft = prompt
                        guard let api = store.api else { writing = true; return }
                        sendFeedback += 1
                        chat.send(api: api, options: store.options, profile: store.insights)
                    } label: {
                        Text(prompt).font(.subheadline).foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 14).frame(minHeight: 38)
                            .background(Theme.paper, in: Capsule())
                            .overlay { Capsule().strokeBorder(Theme.hairline) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .contentShape(Rectangle())
        .onTapGesture { writing = false }
    }

    private func openNote(_ id: String) {
        writing = false
        Task { await store.openNote(id) }
    }
}

private struct StepsTimelineView: View {
    let steps: [ChatStep]
    var reasoning = ""
    var running = false
    var status: String?
    let openNote: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var disclosure: Bool?
    @State private var showReasoning = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { disclosure ?? running }, set: { disclosure = $0 })) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 9) {
                        VStack(spacing: 4) {
                            Image(systemName: step.status == "running" ? "circle.dotted" : "checkmark.circle")
                                .foregroundStyle(step.status == "running" ? Theme.active : Theme.ink3)
                            if step.id != steps.last?.id {
                                Rectangle().fill(Theme.line).frame(width: 1)
                            }
                        }.frame(width: 16).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(step.label).fontWeight(.medium).foregroundStyle(Theme.ink)
                                Spacer(minLength: 0)
                                if let ms = step.durationMs { Text(duration(ms)).monospacedDigit().foregroundStyle(Theme.ink3) }
                            }
                            if let detail = step.detail, !detail.isEmpty {
                                Text(detail).foregroundStyle(Theme.ink2)
                            }
                            ForEach(step.items ?? []) { item in
                                Button {
                                    if let id = UUID(uuidString: item.noteId) { openNote(id.uuidString.lowercased()) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Label("[\(item.ref)] \(item.title)", systemImage: "arrow.up.right")
                                            .fontWeight(.medium).foregroundStyle(Theme.active).lineLimit(1)
                                        if !item.excerpt.isEmpty {
                                            Text(item.excerpt).foregroundStyle(Theme.ink2).lineLimit(1)
                                        }
                                    }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .disabled(UUID(uuidString: item.noteId) == nil)
                            }
                        }.padding(.bottom, 9)
                    }
                }
                if !reasoning.isEmpty {
                    DisclosureGroup("思考过程", isExpanded: $showReasoning) {
                        Text(reasoning).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.ink2)
                            .lineSpacing(2)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }
                }
            }
            .font(.caption)
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                if running {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Theme.active)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.active)
                        .accessibilityHidden(true)
                }
                Text(running ? (steps.last(where: { $0.status == "running" })?.label ?? status ?? "正在处理") : summary)
                    .contentTransition(reduceMotion ? .identity : .opacity)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.ink2)
        }
        .tint(Theme.ink3)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.subtle.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    private var summary: String {
        let references = Set(steps.flatMap { ($0.items ?? []).map(\.noteId) }).count
        let elapsed = steps.reduce(0.0) { $0 + Double(max(0, $1.durationMs ?? 0)) }
        var parts = ["已完成 \(steps.count) 步"]
        if let count = steps.first(where: { $0.kind == "retrieve" })?.detail, !count.isEmpty {
            parts.append(count)
        } else if references > 0 {
            parts.append("命中 \(references) 条笔记")
        }
        if elapsed > 0 { parts.append(duration(elapsed)) }
        return parts.joined(separator: " · ")
    }

    private func duration(_ ms: Int) -> String { duration(Double(ms)) }
    private func duration(_ ms: Double) -> String {
        ms >= 1000 ? (ms / 1000).formatted(.number.precision(.fractionLength(1))) + "s" : ms.formatted() + "ms"
    }
}

private enum ModelVendor: String, CaseIterable, Identifiable {
    case gemini, openai, claude, other
    init(_ raw: String) { self = Self(rawValue: raw.lowercased()) ?? .other }
    var id: Self { self }

    var label: String {
        switch self {
        case .gemini: "Gemini"
        case .openai: "OpenAI"
        case .claude: "Claude"
        case .other: "其他"
        }
    }

    var badge: some View {
        let symbol: String
        let color: Color
        switch self {
        case .gemini: (symbol, color) = ("sparkles", .indigo)
        case .openai: (symbol, color) = ("cpu", Theme.active)
        case .claude: (symbol, color) = ("sun.max.fill", .orange)
        case .other: (symbol, color) = ("circle.hexagongrid.fill", Theme.ink2)
        }
        return Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
    }
}

private struct ModelPickerSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let filtered = query.isEmpty ? store.gatewayModelMeta : store.gatewayModelMeta.filter {
            $0.label.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
                || ModelVendor($0.vendor).label.localizedCaseInsensitiveContains(query)
        }
        let groups = Dictionary(grouping: filtered) { ModelVendor($0.vendor) }
        NavigationStack {
            List {
                if query.isEmpty {
                    modelRow("网关默认", selection: "", vendor: .other)
                }
                ForEach(ModelVendor.allCases) { vendor in
                    if let models = groups[vendor] {
                        Section(vendor.label) {
                            ForEach(models) { model in
                                modelRow(model.label, selection: model.id, vendor: vendor, thinking: model.thinking)
                            }
                        }
                    }
                }
            }
            .overlay {
                if !query.isEmpty && filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .weijiSheetBackground()
            .searchable(text: $query, prompt: "搜索模型")
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }

    private func modelRow(_ label: String, selection: String, vendor: ModelVendor, thinking: Bool = false) -> some View {
        Button {
            store.setModel(selection)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                vendor.badge.font(.footnote)
                    .frame(width: 30, height: 30)
                    .background(Theme.subtle, in: .rect(cornerRadius: 8))
                Text(label).font(.body.weight(store.options.model == selection ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                if thinking {
                    Image(systemName: "brain").font(.caption2).foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.subtle, in: Capsule())
                        .accessibilityLabel("支持思考")
                }
                Spacer()
                if store.options.model == selection {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.active)
                        .accessibilityLabel("已选")
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.paper)
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
                if store.identity?.codexAvailable == true {
                    Section {
                        Picker("连接方式", selection: Binding(get: { store.options.provider }, set: store.setProvider)) {
                            Text(AIProvider.codex.label).tag(AIProvider.codex)
                            Text(AIProvider.openai.label).tag(AIProvider.openai)
                        }
                        .pickerStyle(.segmented)
                        Text(store.options.provider == .codex
                             ? "使用服务器内置 AI 模型，无需配置密钥。"
                             : "使用个人 OpenAI API Key 直接请求模型。")
                            .font(Theme.TypeScale.meta)
                            .foregroundStyle(Theme.ink2)
                    } header: {
                        Text("模型来源")
                    }
                    .listRowBackground(Theme.paper)
                }
                if store.options.provider == .openai {
                    Section("OpenAI 接口") {
                        SecureField("API Key", text: $apiKey).autocorrectionDisabled()
                        TextField("模型名称", text: Binding(get: { store.options.model }, set: store.setModel))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .listRowBackground(Theme.paper)
                }
                Section("对话偏好") {
                    Toggle("结合个人画像回答", isOn: $chat.useProfile).tint(Theme.accent)
                }
                .listRowBackground(Theme.paper)
                if let error {
                    Section {
                        InlineError(message: error)
                    }
                    .listRowBackground(Theme.paper)
                }
            }
            .weijiSheetBackground()
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
        .tint(Theme.active)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private func effortLabel(_ effort: String) -> String {
    switch effort {
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case "xhigh": "极高"
    case "": "自动"
    default: effort
    }
}
