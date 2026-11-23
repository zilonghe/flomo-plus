import Foundation

struct SSEParser {
    struct Frame: Equatable, Sendable {
        let event: String
        let data: String
    }

    private var line: [UInt8] = []
    private var event: String?
    private var data: [String] = []
    private var unfinished = false
    private var receivedDone = false

    mutating func push(_ byte: UInt8) throws -> Frame? {
        guard byte == 10 else { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else {
            defer { event = nil; data.removeAll(keepingCapacity: true); unfinished = false }
            guard !data.isEmpty else { return nil }
            let frame = Frame(event: event ?? "message", data: data.joined(separator: "\n"))
            if frame.event == "done" { receivedDone = true }
            return frame
        }
        guard let text = String(bytes: line, encoding: .utf8) else { throw WeijiAPIError.interrupted }
        guard !text.hasPrefix(":") else { return nil }
        unfinished = true
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count == 2 ? parts[1] : ""
        if value.first == " " { value = value.dropFirst() }
        switch parts[0] {
        case "event": event = value.isEmpty ? nil : String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    func finish() throws {
        try Task.checkCancellation()
        guard receivedDone, line.isEmpty, !unfinished else { throw WeijiAPIError.interrupted }
    }
}
