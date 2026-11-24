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

struct Turn: Codable, Sendable {
    let role: String
    let text: String
    var citations: [Citation]? = nil
}

struct SessionInfo: Decodable, Sendable {
    struct User: Decodable, Sendable { let id: String; let name: String }
    let user: User
    let codexAvailable: Bool
    let codexMode: String?
    var defaultProvider: AIProvider { codexAvailable ? .codex : .openai }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, openai
    var id: String { rawValue }
    var label: String { self == .codex ? "Codex" : "OpenAI" }
}

struct ModelOptions: Decodable, Sendable { let models: [String]; let defaultModel: String? }

struct AIOptions: Sendable {
    var provider: AIProvider = .openai
    var model = ""
    var apiKey = ""

    var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["provider": .string(provider.rawValue), "stream": .bool(true)]
        if !model.isEmpty { fields["model"] = .string(model) }
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
