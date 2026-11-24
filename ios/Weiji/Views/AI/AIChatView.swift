import SwiftUI

struct AIChatView: View {
    let store: AppStore
    @State private var showSessions = false
    @State private var showPins = false
    @State private var showAISettings = false
    @State private var showModels = false
    @State private var sendFeedback = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var writing: Bool

    var body: some View {
        @Bindable var chat = store.chat
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                IconAction(symbol: "clock.arrow.circlepath", label: "会话", id: "ai-sessions-button") { showSessions = true }
                    .disabled(store.api == nil)
                Text(chat.session?.title ?? "AI 对话").font(.headline).lineLimit(1)
                Spacer()
                IconAction(symbol: "slider.horizontal.3", label: "AI 设置", id: "ai-settings-button") { showAISettings = true }
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
            InlineError(message: chat.error).padding(.horizontal, 16)
            composer(chat)
        }
        .sheet(isPresented: $showSessions) { SessionsSheetView(store: store) }
        .sheet(isPresented: $showPins) { PinPickerSheet(store: store) }
        .sheet(isPresented: $showAISettings) { AISettingsView(store: store) }
        .sheet(isPresented: $showModels) { ModelPickerSheet(store: store) }
        .sensoryFeedback(.selection, trigger: store.options.model)
        .sensoryFeedback(.selection, trigger: store.options.reasoningEffort)
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedback)
    }

    private func composer(_ chat: AIChatStore) -> some View {
        @Bindable var chat = chat
        return VStack(alignment: .leading, spacing: 6) {
            modelControls
                .padding(.horizontal, 6)
            HStack(alignment: .bottom, spacing: 4) {
                IconAction(symbol: "at", label: "置顶笔记", id: "ai-pin-picker-button") { showPins = true }
                TextField("问一问你的笔记", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($writing)
                    .padding(.vertical, 11)
                    .accessibilityIdentifier("ai-input-field")
                if chat.sending {
                    IconAction(symbol: "stop.circle.fill", label: "停止", id: "ai-stop-button") {
                        sendFeedback += 1
                        chat.stop()
                    }
                    .foregroundStyle(Theme.active)
                } else {
                    IconAction(symbol: "arrow.up.circle.fill", label: "发送", id: "ai-send-button") {
                        guard let api = store.api else { return }
                        writing = false
                        sendFeedback += 1
                        chat.send(api: api, options: store.options, profile: store.insights)
                    }
                    .foregroundStyle(Theme.active)
                    .disabled(store.api == nil || chat.loadingSession || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(4)
            .weijiGlassCard(cornerRadius: 25)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var modelControls: some View {
        let model = store.selectedModelMeta
        let gatewayModel = store.selectedGatewayModel
        let vendor = ModelVendor(model?.vendor ?? (store.options.provider == .openai ? "openai" : "other"))
        return HStack(spacing: 8) {
            Button {
                if store.options.provider == .codex && !store.gatewayModelMeta.isEmpty { showModels = true }
                else { showAISettings = true }
            } label: {
                HStack(spacing: 6) {
                    vendor.badge
                    Text(model?.label ?? store.options.provider.label).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11).frame(minHeight: 34)
            }
            .buttonStyle(.plain)
            .weijiGlassCapsule()
            .accessibilityLabel("模型：\(model?.label ?? store.options.provider.label)")

            if let gatewayModel, !gatewayModel.selectableEfforts.isEmpty {
                Menu {
                    Picker("思考档位", selection: Binding(get: { store.options.reasoningEffort }, set: store.setReasoningEffort)) {
                        Text("自动").tag("")
                        ForEach(gatewayModel.selectableEfforts, id: \.self) { effort in Text(effortLabel(effort)).tag(effort) }
                    }
                } label: {
                    Label(effortLabel(store.options.reasoningEffort), systemImage: "brain")
                        .padding(.horizontal, 11).frame(minHeight: 34)
                }
                .buttonStyle(.plain)
                .weijiGlassCapsule()
                .accessibilityLabel("思考档位：\(effortLabel(store.options.reasoningEffort))")
            } else if let effort = gatewayModel?.fixedEffort, gatewayModel?.thinking == true {
                Label(effortLabel(effort), systemImage: "brain")
                    .foregroundStyle(.secondary).padding(.horizontal, 11).frame(minHeight: 34)
                    .weijiGlassCapsule(interactive: false)
                    .accessibilityLabel("固定思考档位：\(effortLabel(effort))")
            }
        }.font(.caption.weight(.semibold))
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
                    } else if chat.pendingQuestion.isEmpty {
                        if chat.loadingSession { ProgressView().frame(maxWidth: .infinity).padding(24) }
                        else {
                            Text("和你的笔记聊聊").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 46)
                        }
                    }
                    if !chat.pendingQuestion.isEmpty { question(chat.pendingQuestion, insight: false) }
                    if chat.sending && !chat.pendingQuestion.isEmpty {
                        StepsTimelineView(steps: chat.liveSteps, reasoning: chat.liveReasoning,
                                          running: true, status: chat.status, openNote: openNote)
                    }
                    if !chat.streamedText.isEmpty { reply(chat.streamedText, citations: chat.liveCitations) }
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
        MarkdownBlockView(text: text, citations: citations, openCitation: openNote).noteCard()
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
                                .foregroundStyle(step.status == "running" ? Theme.active : .secondary)
                            if step.id != steps.last?.id {
                                Rectangle().fill(Theme.line).frame(width: 1)
                            }
                        }.frame(width: 16).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(step.label).fontWeight(.medium)
                                Spacer(minLength: 0)
                                if let ms = step.durationMs { Text(duration(ms)).monospacedDigit().foregroundStyle(.secondary) }
                            }
                            if let detail = step.detail, !detail.isEmpty {
                                Text(detail).foregroundStyle(.secondary)
                            }
                            ForEach(step.items ?? []) { item in
                                Button {
                                    if let id = UUID(uuidString: item.noteId) { openNote(id.uuidString.lowercased()) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Label("[\(item.ref)] \(item.title)", systemImage: "arrow.up.right")
                                            .fontWeight(.medium).foregroundStyle(Theme.active).lineLimit(1)
                                        if !item.excerpt.isEmpty {
                                            Text(item.excerpt).foregroundStyle(.secondary).lineLimit(1)
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
                        Text(reasoning).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
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
            .font(.caption.weight(.semibold))
        }
        .tint(Theme.active)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .weijiGlassCard(cornerRadius: 14)
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
        case .other: (symbol, color) = ("circle.hexagongrid.fill", .secondary)
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
            HStack(spacing: 10) {
                vendor.badge.frame(width: 22)
                Text(label).foregroundStyle(.primary)
                if thinking {
                    Image(systemName: "brain").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("支持思考")
                }
                Spacer()
                if store.options.model == selection {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.active)
                        .accessibilityLabel("已选")
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    TextField("模型", text: Binding(get: { store.options.model }, set: store.setModel))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
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
