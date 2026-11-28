import Foundation

struct Reading: Codable, Sendable {
    var bookTitle: String?
    var author: String?
    var chapter: String?
    var sourceDate: String?
    var fingerprint: String?
}

struct Note: Codable, Identifiable, Sendable {
    let id: String
    var body: String
    let createdAt: String
    var reading: Reading? = nil
    var turns: [Turn] = []
    let revision: Int

    static func extractOriginalWriting(from note: Note) -> String? {
        let body: Substring
        if note.reading == nil {
            body = note.body[...]
        } else {
            guard let separator = note.body.range(of: "\n\n原文：") else { return nil }
            body = note.body[..<separator.lowerBound]
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var writePayload: NotePayload {
        NotePayload(id: id, body: body, createdAt: createdAt, reading: reading, turns: turns)
    }
}

struct NotePayload: Codable, Sendable {
    let id: String
    let body: String
    let createdAt: String
    let reading: Reading?
    let turns: [Turn]
}

struct NoteMutation: Encodable, Sendable {
    let id: String
    let expectedRevision: Int
    var note: NotePayload? = nil
    var delete: Bool? = nil
}

struct Tombstone: Codable, Sendable { let id: String; let revision: Int }
struct NotesResponse: Decodable, Sendable { let notes: [Note]; let deleted: [Tombstone] }
struct NoteRecord: Decodable, Sendable { let note: Note?; let deleted: Tombstone? }

struct RelatedNoteSummary: Decodable, Identifiable, Sendable {
    let id: String
    let body: String
    let createdAt: String
    let reading: Reading?
}

struct RelatedNotes: Decodable, Sendable {
    struct Item: Decodable, Identifiable, Sendable {
        let id: String
        let score: Double
        let relevancePercent: Int
        let sharedTags: [String]
        let note: RelatedNoteSummary
    }
    let focus: RelatedNoteSummary
    let mode: String
    let indexed: Int
    let total: Int
    let related: [Item]
}

struct Citation: Codable, Sendable {
    let ref: String
    let noteId: String
    let excerpt: String
    var createdAt: String? = nil
    var bookTitle: String? = nil
}

struct ChatStepItem: Codable, Equatable, Identifiable, Sendable {
    let ref: String
    let noteId: String
    let title: String
    let excerpt: String
    var id: String { ref + ":" + noteId }
}

struct ChatStep: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let status: String?
    let label: String
    let detail: String?
    let durationMs: Int?
    let items: [ChatStepItem]?
}

struct Turn: Codable, Sendable {
    let role: String
    let text: String
    let citations: [Citation]?
    let steps: [ChatStep]?

    init(role: String, text: String, citations: [Citation]? = nil, steps: [ChatStep]? = nil) {
        self.role = role
        self.text = text
        self.citations = citations
        self.steps = steps
    }
}

struct SessionInfo: Decodable, Sendable {
    struct User: Decodable, Sendable { let id: String; let name: String; let role: String? }
    let user: User
    let codexAvailable: Bool
    let codexMode: String?
    let authMode: String?
    var defaultProvider: AIProvider { codexAvailable ? .codex : .openai }
}

struct ObsidianSyncStats: Decodable, Equatable, Sendable {
    let scanned: Int
    let fetched: Int
    let created: Int
    let updated: Int
    let skipped: Int
    let excluded: Int
    let conflicts: Int
}

struct ObsidianSyncRun: Decodable, Equatable, Sendable {
    let at: String
    let trigger: String
    let ok: Bool
    let error: String?
    let indexWarning: String?
    let stats: ObsidianSyncStats?
}

struct ObsidianSyncStatus: Decodable, Equatable, Sendable {
    let configured: Bool
    let running: Bool?
    let intervalMs: Int?
    let prefixes: [String]?
    let lastRun: ObsidianSyncRun?
}

struct ObsidianSyncResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let stats: ObsidianSyncStats
    let status: ObsidianSyncStatus
}

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, openai
    var id: String { rawValue }
    var label: String { self == .codex ? "内置服务" : "自定义 Key" }
}

struct ModelMeta: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let vendor: String
    let thinking: Bool
    let efforts: [String]
    let fixedEffort: String?
    let defaultEffort: String?

    static let supportedEfforts = ["low", "medium", "high", "xhigh"]
    private static let fourLevelEffortModels: Set<String> = [
        "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra",
        "gpt-6-astra", "gpt-6-luna", "gpt-6-sol", "gpt-6-chat-thinking",
        "gpt-6.1-sol", "gpt-6.1-terra",
        "gpt-6.2-astra", "gpt-6.2-sol",
    ]
    private static let threeLevelEffortModels: Set<String> = [
        "gemini-3-flash", "gemini-3.1-flash-lite", "gemini-3.5-flash-lite", "gemini-3.8-flash-tiered",
        "o1", "o3", "o3-mini", "o4-mini",
    ]

    var selectableEfforts: [String] {
        guard thinking, fixedEffort == nil else { return [] }
        return Self.supportedEfforts.filter(efforts.contains)
    }

    static func inferred(from id: String) -> Self {
        let name = id.lowercased()
        let vendor: String
        if name.contains("gemini") { vendor = "gemini" }
        else if name.contains("claude") { vendor = "claude" }
        else if name.range(of: #"^(?:gpt|o[1-9]|codex)"#, options: .regularExpression) != nil { vendor = "openai" }
        else { vendor = "other" }

        let fixed = ["medium", "high", "xhigh"].first { name.hasSuffix("-" + $0) }
        let efforts: [String]
        if fixed != nil { efforts = [] }
        else if Self.fourLevelEffortModels.contains(name) {
            efforts = supportedEfforts
        } else if Self.threeLevelEffortModels.contains(name) {
            efforts = Array(supportedEfforts.prefix(3))
        } else { efforts = [] }

        let base = fixed.map { String(id.dropLast($0.count + 1)) } ?? id
        let label = base.split(separator: "-").map { word in
            word.lowercased() == "gpt" ? "GPT" : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ").replacingOccurrences(of: "GPT ", with: "GPT-")
        return Self(id: id, label: label.isEmpty ? id : label, vendor: vendor, thinking: fixed != nil || !efforts.isEmpty,
                    efforts: efforts, fixedEffort: fixed, defaultEffort: fixed)
    }
}

struct ModelOptions: Decodable, Sendable {
    let models: [String]
    let defaultModel: String?
    let modelMeta: [ModelMeta]?

    var resolvedMeta: [ModelMeta] {
        let metadata = Dictionary((modelMeta ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return models.map { metadata[$0] ?? .inferred(from: $0) }
    }
}

struct AIOptions: Sendable {
    var provider: AIProvider = .openai
    var model = ""
    var apiKey = ""
    var reasoningEffort = ""

    var fields: [String: JSONValue] {
        var fields = nonStreamingFields
        fields["stream"] = .bool(true)
        return fields
    }

    var nonStreamingFields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["provider": .string(provider.rawValue)]
        if !model.isEmpty { fields["model"] = .string(model) }
        if !reasoningEffort.isEmpty { fields["reasoningEffort"] = .string(reasoningEffort) }
        if provider == .openai { fields["apiKey"] = .string(apiKey) }
        return fields
    }
}

enum JSONValue: Encodable, Sendable {
    case string(String), bool(Bool), number(Int), strings([String]), scope(InsightScope)
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .string(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .strings(let value): try box.encode(value)
        case .scope(let value): try box.encode(value)
        }
    }
}

struct ChatSession: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceNoteId: String?
    let version: Int
    let updatedAt: String
    let origin: String
    let turns: [Turn]?
}
struct ChatPage: Decodable, Sendable { let sessions: [ChatSession]; let nextCursor: String? }
struct ChatResponse: Decodable, Sendable { let session: ChatSession? }
struct DeletedResponse: Decodable, Sendable { let deleted: String }

struct Profile: Decodable, Sendable { let content: String; let enabled: Bool; let noteCount: Int }
struct ProfileResponse: Decodable, Sendable { let profile: Profile? }
struct ProfileEdit: Encodable, Sendable { var content: String?; let enabled: Bool }

struct WritingStyleAnchor: Codable, Identifiable, Sendable {
    let id: String
    let createdAt: String
    let excerpt: String
}

struct WritingStyle: Codable, Sendable {
    let rules: String
    let anchorNoteIds: [String]
    let anchors: [WritingStyleAnchor]
    let missingAnchorCount: Int
    let scope: InsightScope
    let noteCount: Int
    let updatedAt: String
    let ready: Bool
}

struct WritingStyleResponse: Codable, Sendable {
    let style: WritingStyle?

    private enum CodingKeys: String, CodingKey { case style }

    init(style: WritingStyle?) { self.style = style }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.style) else {
            throw DecodingError.keyNotFound(CodingKeys.style, .init(codingPath: container.codingPath, debugDescription: "Missing writing style response key."))
        }
        style = try container.decodeIfPresent(WritingStyle.self, forKey: .style)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style, forKey: .style)
    }
}
struct WritingStyleGenerateResponse: Codable, Sendable {
    let style: WritingStyle
    let suggestedAnchors: [WritingStyleAnchor]
}

struct WritingStyleEdit: Codable, Sendable {
    var rules: String? = nil
    var anchorNoteIds: [String]? = nil
    var scope: InsightScope? = nil
}

struct BlindTestSource: Codable, Sendable {
    let kind: String
    let noteId: String?
    let text: String
}

struct BlindTestCandidate: Codable, Sendable {
    let slot: String
    let variant: String
    let text: String
}

struct BlindTestResponse: Codable, Sendable {
    let source: BlindTestSource
    let candidates: [BlindTestCandidate]
}

struct InsightScope: Codable, Equatable, Sendable {
    var range = "all"
    var tzOffsetMinutes = -TimeZone.current.secondsFromGMT() / 60
    var tags: [String] = []
    var tagMode = "any"
    var startDate: String?
    var endDate: String?
}

struct InsightStats: Decodable, Sendable {
    let noteCount: Int
    let dayCount: Int
    let tagCount: Int
    var label: String { "\(noteCount) 条笔记 · \(dayCount) 天 · \(tagCount) 标签" }
}

struct InsightLens: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let prompt: String
    let category: String
    let builtin: Bool
    let suggestedRange: String?
}
struct LensEdit: Encodable, Sendable {
    var id: String?
    var name = ""
    var description = ""
    var prompt = ""
    var category = "自定义"
    var suggestedRange: String?

    init(lens: InsightLens? = nil) {
        guard let lens else { return }
        id = lens.id
        name = lens.name
        description = lens.description
        prompt = lens.prompt
        category = lens.category
        suggestedRange = lens.suggestedRange
    }
}
struct LensList: Decodable, Sendable { let lenses: [InsightLens] }
struct LensResponse: Decodable, Sendable { let lens: InsightLens }

struct InsightReport: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let lensName: String
    let content: String?
    let excerpt: String?
    let citations: [Citation]?
    let createdAt: String
}
struct ReportList: Decodable, Sendable { let reports: [InsightReport] }
struct ReportResponse: Decodable, Sendable { let report: InsightReport }

struct SemanticStatus: Decodable, Sendable {
    let indexed: Int?
    let total: Int?
    let mode: String?
}

struct StreamCitations: Decodable, Sendable { let citations: [Citation] }
struct StreamReasoning: Decodable, Sendable { let text: String }
struct StreamDelta: Decodable { let text: String }
struct StreamStatus: Decodable { let message: String? }

func clippedUTF16(_ value: String, to limit: Int) -> String {
    guard limit > 0 else { return "" }
    guard value.utf16.count > limit else { return value }
    var size = 0
    return String(value.prefix(while: {
        size += String($0).utf16.count
        return size <= limit
    }))
}
