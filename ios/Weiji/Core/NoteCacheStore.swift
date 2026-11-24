import Foundation
import CommonCrypto

struct NoteFilter: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case all = "全部", journal = "随记", reading = "读书"
        var id: Self { self }
    }
    var kind: Kind = .all
    var tag: String?
    var day: String?
}

struct NoteIndex: Sendable {
    struct Entry: Sendable {
        let note: Note
        let searchText: String
        let tagPrefixes: Set<String>
        let day: String
    }
    struct HeatDay: Identifiable, Sendable { let id: String; let count: Int }

    let entries: [Entry]
    let byId: [String: Note]
    let tags: [TagParser.Node]
    let exactTags: [String]
    let heatmap: [HeatDay]
    let readingCount: Int

    init(_ notes: [Note] = [], now: Date = .now, calendar: Calendar = .current) {
        let sorted = notes.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.calendar = Calendar(identifier: .gregorian)
        dayFormat.timeZone = calendar.timeZone
        dayFormat.dateFormat = "yyyy-MM-dd"
        var counts: [String: Int] = [:]
        var dayCounts: [String: Int] = [:]
        var exact = Set<String>()
        var reading = 0
        entries = sorted.map { note in
            let noteTags = TagParser.tags(in: note.body)
            exact.formUnion(noteTags)
            var prefixes = Set<String>()
            for tag in noteTags {
                var path = ""
                for segment in tag.split(separator: "/") {
                    path += (path.isEmpty ? "" : "/") + segment
                    prefixes.insert(path)
                }
            }
            for tag in prefixes { counts[tag, default: 0] += 1 }
            let date = iso.date(from: note.createdAt) ?? seconds.date(from: note.createdAt)
            let day = date.map { dayFormat.string(from: $0) } ?? ""
            dayCounts[day, default: 0] += 1
            if note.reading != nil { reading += 1 }
            let text = [note.body, note.reading?.bookTitle, note.reading?.author, note.reading?.chapter]
                .compactMap { $0 }.joined(separator: "\n").lowercased()
            return Entry(note: note, searchText: text, tagPrefixes: prefixes, day: day)
        }
        byId = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tags = TagParser.tree(counts)
        exactTags = exact.sorted()
        readingCount = reading
        heatmap = (0..<84).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = dayFormat.string(from: date)
            return HeatDay(id: key, count: dayCounts[key, default: 0])
        }
    }

    func search(_ query: String, filter: NoteFilter = .init()) -> [Note] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        return entries.compactMap { entry in
            guard words.allSatisfy({ entry.searchText.contains($0) }),
                  filter.tag.map(entry.tagPrefixes.contains) ?? true,
                  filter.day.map({ entry.day == $0 }) ?? true else { return nil }
            switch filter.kind {
            case .all: return entry.note
            case .journal: return entry.note.reading == nil ? entry.note : nil
            case .reading: return entry.note.reading != nil ? entry.note : nil
            }
        }
    }
}

actor NoteCacheStore {
    struct Key: Equatable, Sendable {
        let origin: String
        let userId: String

        var filename: String {
            NoteCacheStore.digest(origin + "|" + userId) + ".json"
        }
    }

    private struct Binding: Codable {
        let tokenDigest: String
        let userId: String
    }

    private let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Weiji/Notes", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load(_ key: Key) throws -> [Note]? {
        let url = directory.appending(path: key.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([Note].self, from: Data(contentsOf: url))
    }

    func save(_ notes: [Note], for key: Key) throws {
        try Task.checkCancellation()
        try write(notes, to: directory.appending(path: key.filename))
    }

    func bind(_ configuration: ServerConfiguration, userId: String) throws {
        try Task.checkCancellation()
        try write(Binding(tokenDigest: Self.digest(configuration.token), userId: userId),
                  to: bindingURL(configuration.origin))
    }

    func loadOfflineEntry(_ configuration: ServerConfiguration) throws -> (key: Key, notes: [Note])? {
        guard let binding = try matchingBinding(configuration) else { return nil }
        let key = Key(origin: configuration.origin, userId: binding.userId)
        guard let notes = try load(key) else { return nil }
        return (key, notes)
    }

    func loadOffline(_ configuration: ServerConfiguration) throws -> [Note]? {
        try loadOfflineEntry(configuration)?.notes
    }

    func revoke(_ configuration: ServerConfiguration) throws {
        guard try matchingBinding(configuration) != nil else { return }
        try FileManager.default.removeItem(at: bindingURL(configuration.origin))
    }

    func clearSession(_ configuration: ServerConfiguration, key: Key?) throws {
        let binding = try matchingBinding(configuration)
        if binding != nil { try revoke(configuration) }
        if let account = key ?? binding.map({ Key(origin: configuration.origin, userId: $0.userId) }) {
            try invalidate(account)
        }
    }

    private func matchingBinding(_ configuration: ServerConfiguration) throws -> Binding? {
        let url = bindingURL(configuration.origin)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let binding = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: url))
        return binding.tokenDigest == Self.digest(configuration.token) ? binding : nil
    }

    private func bindingURL(_ origin: String) -> URL {
        directory.appending(path: "auth-" + Self.digest(origin) + ".json")
    }

    private static func digest(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func invalidate(_ key: Key) throws {
        let url = directory.appending(path: key.filename)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
