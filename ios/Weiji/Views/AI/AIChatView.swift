import SwiftUI

struct AIChatView: View {
    let store: AppStore
    @Binding var showSessions: Bool
    @State private var showPins = false
    @State private var openSettingsAfterModels = false
    @State private var showModels = false
    @State private var modelOverride: ModelChoice?
    @State private var pickedModel: ModelChoice?
    @State private var showLens = false
    @State private var lensPrompt: String?
    @State private var editedLens: InsightLens?
    @State private var showAllLenses = false
    @State private var ranges: [String: String] = [:]
    @State private var rerunAfterModels = false
    @State private var confirmReportDelete = false
    @State private var sendFeedback = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var writing: Bool

    static func pinChipTitle(for note: Note?) -> String {
        let text = note?.body.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        if !text.isEmpty { return String(text.prefix(24)) }
        if let book = note?.reading?.bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !book.isEmpty { return book }
        return "引用笔记"
    }

    static func displayedTurns(session: ChatSession?, loadingSession: Bool, sourceNoteId: String?,
                               notesById: [String: Note]) -> [Turn]? {
        if let turns = session?.turns, !turns.isEmpty { return turns }
        if session == nil, !loadingSession, let sourceNoteId,
           let turns = notesById[sourceNoteId]?.turns, !turns.isEmpty { return turns }
        return session?.turns
    }

    private var insights: InsightsStore { store.insights }

    private var defaultChoice: ModelChoice {
        .init(model: store.options.model, effort: store.options.reasoningEffort)
    }

    private var requestOptions: AIOptions {
        var options = store.options
        if let modelOverride {
            options.model = modelOverride.model
            options.reasoningEffort = modelOverride.effort
        }
        return options
    }

    private var reportBusy: Bool {
        switch store.reportRoute {
        case .live: insights.running
        case .history: insights.loadingReport
        case nil: false
        }
    }

    var body: some View {
        @Bindable var chat = store.chat
        let turns = Self.displayedTurns(session: chat.session, loadingSession: chat.loadingSession,
                                       sourceNoteId: chat.sourceNoteId, notesById: store.notesById)
        let hasConversation = store.reportRoute != nil || chat.session != nil || !(turns?.isEmpty ?? true)
            || !chat.pendingQuestion.isEmpty || chat.loadingSession
        NavigationStack {
            VStack(spacing: 0) {
                header(hasConversation: hasConversation)
                if !chat.pins.isEmpty { pins(chat) }
                if hasConversation || chat.sending {
                    messages(chat, turns: turns)
                } else {
                    emptyState(chat)
                }
                InlineError(message: chat.error).padding(.horizontal, 24)
                composer(chat)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: store.tab) {
            if store.tab == .ai, let api = store.api { await insights.loadLibrary(api: api) }
        }
        .task(id: store.presentedReport?.id) { store.prepareReportFollowUp() }
        .onChange(of: store.chatRouteVersion) {
            if store.reportRoute != .live { modelOverride = nil }
            nearBottom = true
        }
        .onChange(of: store.options.provider) { modelOverride = nil }
        .onChange(of: store.tab) { _, tab in if tab != .ai { writing = false } }
        .sheet(isPresented: $showPins) { PinPickerSheet(store: store) }
        .sheet(isPresented: $showLens) { CustomLensSheet(store: store, lens: editedLens, prompt: lensPrompt) }
        .sheet(isPresented: $showModels, onDismiss: finishModelPicker) {
            ModelPickerSheet(store: store, choice: modelOverride ?? defaultChoice, onSelect: { pickedModel = $0 }) {
                openSettingsAfterModels = true
                showModels = false
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("删除这份报告？", isPresented: $confirmReportDelete, titleVisibility: .visible) {
            Button("删除报告", role: .destructive) {
                guard let api = store.api, let report = store.presentedReport else { return }
                Task {
                    if await insights.deleteReport(report.id, api: api) { store.requestNewChat() }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendFeedback)
    }

    private func header(hasConversation: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                historyButton.fixedSize()
                Spacer(minLength: 0)
                SpaceSwitcher(store: store)
                Spacer(minLength: 0)
                headerActions(hasConversation: hasConversation, compact: false)
            }
            HStack(spacing: 2) {
                historyButton
                Spacer(minLength: 0)
                SpaceSwitcher(store: store)
                Spacer(minLength: 0)
                headerActions(hasConversation: hasConversation, compact: true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }

    private var historyButton: some View {
        Button {
            writing = false
            showSessions = true
        } label: {
            ViewThatFits(in: .horizontal) {
                Text("历史").fixedSize()
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.subheadline).foregroundStyle(Theme.ink).minTouchTarget()
        }
        .buttonStyle(.plain)
        .disabled(store.api == nil)
        .accessibilityLabel("历史")
        .accessibilityIdentifier("ai-sessions-button")
    }

    private func headerActions(hasConversation: Bool, compact: Bool) -> some View {
        HStack(spacing: 2) {
            if hasConversation {
                Button { store.requestNewChat() } label: {
                    Group {
                        if compact { Image(systemName: "square.and.pencil") }
                        else { Text("新对话").fixedSize() }
                    }
                    .font(.subheadline).foregroundStyle(Theme.ink).minTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新对话")
                .accessibilityIdentifier("ai-new-button")
            }
            Menu {
                Button("切换模型与思考深度") { showModels = true }.disabled(store.api == nil)
                if modelOverride != nil { Button("使用默认模型") { modelOverride = nil } }
                Button("新建自定义视角") { openLensEditor() }.disabled(store.api == nil)
                Button("AI 设置") { store.openSettings(.ai) }
                    .accessibilityIdentifier("ai-settings-button")
                if let report = store.presentedReport {
                    Button("复制 Markdown") { UIPasteboard.general.string = report.content }
                    Button("换模型重跑") {
                        rerunAfterModels = true
                        showModels = true
                    }
                    .disabled(!store.canRerunReport || insights.running || store.chat.sending)
                    Button("删除报告", role: .destructive) { confirmReportDelete = true }
                        .disabled(insights.deletingReport || store.chat.sending)
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.ink).minTouchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多操作")
        }
        .fixedSize()
    }

    private func finishModelPicker() {
        defer {
            rerunAfterModels = false
            pickedModel = nil
            openSettingsAfterModels = false
        }
        if openSettingsAfterModels { store.openSettings(.ai); return }
        guard let pickedModel else { return }
        modelOverride = pickedModel == defaultChoice ? nil : pickedModel
        if rerunAfterModels { store.requestRerunReport(options: requestOptions) }
    }

    private func pins(_ chat: AIChatStore) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(chat.pins, id: \.self) { id in
                    Button { openNote(id) } label: {
                        Label(Self.pinChipTitle(for: store.notesById[id]), systemImage: "pin")
                            .font(.footnote).foregroundStyle(Theme.ink2).lineLimit(1).minTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ai-pin-chip-" + id)
                    .contextMenu { Button("移除引用", role: .destructive) { chat.togglePin(id) } }
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("ai-pin-chip-list")
    }

    private func composer(_ chat: AIChatStore) -> some View {
        @Bindable var chat = chat
        let reportReady = store.reportRoute == nil || (store.presentedReport != nil
            && (chat.insight != nil || chat.session != nil))
        let canSend = store.api != nil && !chat.loadingSession && !reportBusy && reportReady
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            if let modelOverride {
                let name = store.gatewayModelMeta.first { $0.id == modelOverride.model }?.label
                    ?? (modelOverride.model.isEmpty ? "网关默认" : modelOverride.model)
                Text("本次模型：\(name) · \(effortLabel(modelOverride.effort))")
                    .font(.footnote).tracking(0.5).foregroundStyle(Theme.ink2)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Button { showPins = true } label: {
                    Image(systemName: "at").foregroundStyle(Theme.ink2).minTouchTarget()
                }
                .buttonStyle(.plain)
                .disabled(chat.loadingSession || reportBusy || store.api == nil)
                .accessibilityLabel("引用笔记")
                .accessibilityIdentifier("ai-pin-picker-button")
                TextField(store.presentedReport == nil ? "问问你的笔记" : "继续追问", text: $chat.draft, axis: .vertical)
                    .id(chat.composerResetCount)
                    .lineLimit(1...5)
                    .foregroundStyle(Theme.ink)
                    .focused($writing)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Theme.paper, in: .rect(cornerRadius: 12))
                    .disabled(reportBusy || !reportReady)
                    .accessibilityIdentifier("ai-input-field")
                if chat.sending || (store.reportRoute == .live && insights.running) {
                    composerButton(symbol: "stop.fill", label: "停止", id: "ai-stop-button", enabled: true) {
                        sendFeedback += 1
                        if chat.sending { chat.stop() } else { insights.stopReport() }
                    }
                } else {
                    composerButton(symbol: "arrow.up", label: "发送", id: "ai-send-button", enabled: canSend) {
                        guard let api = store.api else { return }
                        sendFeedback += 1
                        chat.send(api: api, options: requestOptions, profile: insights)
                        writing = false
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func composerButton(symbol: String, label: String, id: String, enabled: Bool,
                                action: @escaping () -> Void) -> some View {
        let isStop = symbol == "stop.fill"
        return Button(action: action) {
            Image(systemName: symbol).font(.subheadline.weight(.bold))
                .foregroundStyle(isStop ? Theme.inverseText : .white)
                .frame(width: 36, height: 36)
                .background((isStop ? Theme.inverseBg : Theme.accent).opacity(enabled ? 1 : 0.35), in: Circle())
                .minTouchTarget()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    @State private var nearBottom = true

    private func messages(_ chat: AIChatStore, turns: [Turn]?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    reportMessage
                    if let turns {
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
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(store.reportRoute == nil ? .bottom : .top, for: .alignment)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 100
            } action: { _, new in nearBottom = new }
            .onChange(of: insights.liveReportText) { _, _ in
                if nearBottom && store.reportRoute == .live { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
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
                        Image(systemName: "arrow.down").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 36, height: 36)
                            .background(Theme.paper, in: Circle())
                            .minTouchTarget()
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
            .background(Theme.paper, in: .rect(cornerRadius: 12))
            .frame(maxWidth: 300, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 6)
            .contextMenu { Button("存为视角") { openLensEditor(prompt: content) } }
    }

    private func reply(_ text: String, citations: [Citation]) -> some View {
        MarkdownBlockView(text: text, citations: citations, openCitation: openNote)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private var reportMessage: some View {
        if let route = store.reportRoute {
            let text = route == .live ? insights.liveReportText : insights.viewedReportText
            let error = route == .live ? insights.liveReportError : insights.viewedReportError
            if text.isEmpty && reportBusy {
                ProgressView().accessibilityLabel("正在载入报告")
            } else if !text.isEmpty {
                reply(text, citations: store.presentedReport?.citations ?? [])
            } else if error == nil {
                Text("报告未完成").font(.footnote).foregroundStyle(Theme.ink2)
            }
            InlineError(message: error)
        }
    }

    private static let rangeTitles = [("7d", "近 7 天"), ("week", "本周"), ("month", "本月"), ("all", "全部")]

    private func range(for lens: InsightLens) -> String {
        let suggested = lens.suggestedRange ?? "7d"
        return ranges[lens.id] ?? (Self.rangeTitles.contains { $0.0 == suggested } ? suggested : "7d")
    }

    private func run(_ lens: InsightLens) {
        writing = false
        store.requestRunReport(lens, range: range(for: lens), options: requestOptions)
    }

    private func openLensEditor(_ lens: InsightLens? = nil, prompt: String? = nil) {
        editedLens = lens
        lensPrompt = prompt
        showLens = true
    }

    private var visibleLenses: [InsightLens] {
        if showAllLenses { return insights.lenses }
        return Array(insights.lenses.filter(\.builtin).prefix(5))
    }

    private func emptyState(_ chat: AIChatStore) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(chat.pins.isEmpty ? "问问你的笔记" : "围绕引用笔记提问")
                        .font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                    if insights.running {
                        Button("查看正在生成的报告") { store.resumeLiveReport() }.minTapHeight()
                    }
                    if chat.pins.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(visibleLenses) { lens in
                                HStack(spacing: 8) {
                                    Button { run(lens) } label: {
                                        Text(lens.name).foregroundStyle(Theme.ink)
                                            .frame(maxWidth: .infinity, alignment: .leading).minTapHeight()
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(insights.running)
                                    .contextMenu {
                                        if !lens.builtin { Button("编辑视角") { openLensEditor(lens) } }
                                    }
                                    Menu {
                                        ForEach(Self.rangeTitles, id: \.0) { key, value in
                                            Button(value) { ranges[lens.id] = key }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(Self.rangeTitles.first { $0.0 == range(for: lens) }?.1 ?? "近 7 天")
                                            Image(systemName: "chevron.right")
                                                .font(.caption2.weight(.medium))
                                                .accessibilityHidden(true)
                                        }
                                        .foregroundStyle(Theme.ink2).minTouchTarget()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(lens.name)的笔记范围")
                                }
                                .font(.subheadline)
                            }
                            if insights.lenses.count > visibleLenses.count || showAllLenses {
                                Button { showAllLenses.toggle() } label: {
                                    Text(showAllLenses ? "收起视角" : "更多视角")
                                        .font(.footnote).foregroundStyle(Theme.ink2).minTouchTarget()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    InlineError(message: insights.error)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func openNote(_ id: String) {
        writing = false
        Task { await store.openNote(id, from: .ai) }
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
        DisclosureGroup(isExpanded: Binding(get: { disclosure ?? false }, set: { disclosure = $0 })) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 9) {
                        VStack(spacing: 4) {
                            Image(systemName: step.status == "running" ? "circle.dotted" : "checkmark.circle")
                                .foregroundStyle(step.status == "running" ? Theme.ink : Theme.ink3)
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
                                    }.frame(maxWidth: .infinity, alignment: .leading).minTapHeight()
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
            Text(running ? (steps.last(where: { $0.status == "running" })?.label ?? status ?? "正在处理") : summary)
                .font(.footnote).foregroundStyle(Theme.ink2).minTapHeight()
                .contentTransition(reduceMotion ? .identity : .opacity)
        }
        .tint(Theme.ink2)
    }

    private var summary: String {
        let references = Set(steps.flatMap { ($0.items ?? []).map(\.noteId) }).count
        return references > 0 ? "参考了 \(references) 条笔记" : "查看检索步骤"
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

}

struct ModelChoice: Equatable {
    var model: String
    var effort: String
}

struct ModelPickerSheet: View {
    let store: AppStore
    @State var choice: ModelChoice
    let onSelect: (ModelChoice) -> Void
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var efforts: [String] {
        let selected = choice.model.isEmpty ? store.gatewayDefault : choice.model
        return store.gatewayModelMeta.first { $0.id == selected }?.selectableEfforts ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                if store.options.provider == .openai {
                    TextField("模型名称", text: $choice.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("配置 OpenAI API Key", action: openSettings).minTapHeight()
                } else {
                    if !efforts.isEmpty {
                        Picker("思考深度", selection: $choice.effort) {
                            Text("自动").tag("")
                            ForEach(efforts, id: \.self) { effort in Text(effortLabel(effort)).tag(effort) }
                        }
                    }
                    if query.isEmpty { modelRow("网关默认", id: "") }
                    ForEach(filtered) { model in modelRow(model.label, id: model.id) }
                }
            }
            .listStyle(.plain)
            .weijiSheetBackground()
            .searchable(text: $query, prompt: "搜索模型")
            .navigationTitle("模型与思考深度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSelect(choice)
                        dismiss()
                    }
                }
            }
            .tint(Theme.ink)
        }
    }

    private var filtered: [ModelMeta] {
        store.gatewayModelMeta.filter {
            query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
                || ModelVendor($0.vendor).label.localizedCaseInsensitiveContains(query)
        }
    }

    private func modelRow(_ label: String, id: String) -> some View {
        Button {
            choice.model = id
            if !efforts.contains(choice.effort) { choice.effort = "" }
        } label: {
            HStack {
                Text(label)
                Spacer()
                if choice.model == id { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .foregroundStyle(Theme.ink).minTapHeight()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice.model == id ? .isSelected : [])
        .listRowBackground(Theme.canvas)
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
