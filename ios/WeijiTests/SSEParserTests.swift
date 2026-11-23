import XCTest
@testable import Weiji

final class SSEParserTests: XCTestCase {
    func testMultiByteCJKAcrossChunksAndCRLF() throws {
        var parser = SSEParser()
        let wire = Array("event: delta\r\ndata: 复盘🙂\r\n\r\nevent: done\r\ndata: {}\r\n\r\n".utf8)
        var frames: [SSEParser.Frame] = []
        for offset in stride(from: 0, to: wire.count, by: 2) {
            for byte in wire[offset..<min(offset + 2, wire.count)] {
                if let frame = try parser.push(byte) { frames.append(frame) }
            }
        }
        XCTAssertEqual(frames, [.init(event: "delta", data: "复盘🙂"), .init(event: "done", data: "{}")])
        XCTAssertNoThrow(try parser.finish())
    }

    func testIgnoresPingAndParsesMultilineData() throws {
        var parser = SSEParser()
        let first = try ": ping\nevent: delta\ndata: one\n: keepalive\ndata:  two\n".utf8.compactMap { try parser.push($0) }
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(try parser.push(10), .init(event: "delta", data: "one\n two"))
        _ = try "event: done\ndata: {}\n\n".utf8.compactMap { try parser.push($0) }
        XCTAssertNoThrow(try parser.finish())
    }

    func testRejectsUnclosedTrailingFrameAtEOF() throws {
        for suffix in ["event: delta\ndata: x\n", "data: x"] {
            var parser = SSEParser()
            _ = try "event: done\ndata: {}\n\n".utf8.compactMap { try parser.push($0) }
            XCTAssertTrue(try suffix.utf8.compactMap { try parser.push($0) }.isEmpty)
            XCTAssertThrowsError(try parser.finish())
        }
        var parser = SSEParser()
        _ = try "event: delta\ndata: x\n\n".utf8.compactMap { try parser.push($0) }
        XCTAssertThrowsError(try parser.finish())
    }
}
