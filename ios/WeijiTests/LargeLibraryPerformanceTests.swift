import Foundation
import XCTest
@testable import Weiji

final class LargeLibraryPerformanceTests: XCTestCase {
    @MainActor
    func test8221CachedNotesAppearWithin1500msBeforeSessionReturns() async throws {
        let release = DispatchSemaphore(value: 0)
        let (config, transport) = try StubProtocol.make { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            if release.wait(timeout: .now() + 8) == .timedOut { XCTFail("Session response was never released") }
            return .init(status: 0, body: "", failure: .notConnectedToInternet)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            release.signal()
            transport.invalidateAndCancel()
            StubProtocol.remove(config)
            try? FileManager.default.removeItem(at: directory)
        }
        let notes = (0..<8_221).map { i in
            Note(id: "cached-\(i)", body: "第 \(i) 条 #工作/执行 " + String(repeating: "笔记正文 ", count: 75),
                 createdAt: "2026-11-23T11:00:00Z", revision: 1)
        }
        let cache = NoteCacheStore(directory: directory)
        let key = NoteCacheStore.Key(origin: config.origin, userId: "account")
        try await cache.save(notes, for: key)
        try await cache.bind(config, userId: key.userId)

        let store = AppStore(initial: config, temporary: true, cache: NoteCacheStore(directory: directory),
                             makeTransport: StubProtocol.transport)
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .milliseconds(1_500))
        store.start()
        while store.results.first == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = start.duration(to: .now)
        XCTAssertNotNil(store.results.first)
        XCTAssertLessThan(elapsed, .milliseconds(1_500))
        XCTAssertEqual(store.results.count, notes.count)
        XCTAssertEqual(store.authScreenState, .offline)
        XCTAssertTrue(store.syncing)
        XCTAssertNil(store.api)
        release.signal()
        while store.syncing && start.duration(to: .now) < .seconds(3) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.syncing)
        XCTAssertEqual(store.results.count, notes.count)
    }

    func test8221NotesSortSearchTagsHeatmapAndCacheIsolation() async throws {
        let count = 8_221
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let formatter = ISO8601DateFormatter()
        var ordered: [Note] = []
        for position in 0..<count {
            let time = now.addingTimeInterval(-Double(position / 100) * 86_400 - Double(position % 100))
            let group = position.isMultiple(of: 2) ? "复盘" : "执行"
            let needle = position == 7_499 ? "远端唯一索引词" : "普通内容"
            ordered.append(Note(id: String(format: "note-%05d", (position * 7_919) % count),
                                body: "第 \(position) 条 \(needle) #工作/\(group) #工作",
                                createdAt: formatter.string(from: time), revision: position + 1))
        }
        let scrambled = ordered.sorted { $0.id < $1.id }
        XCTAssertNotEqual(scrambled.map(\.id), ordered.map(\.id))
        let start = ContinuousClock.now
        let index = NoteIndex(scrambled, now: now, calendar: calendar)
        let buildTime = start.duration(to: .now)
        let lookup = ContinuousClock.now
        let found = index.search("远端唯一索引词", filter: NoteFilter(tag: "工作"))
        let searchTime = lookup.duration(to: .now)
        XCTAssertLessThan(buildTime, .milliseconds(1_500))
        XCTAssertLessThan(searchTime, .milliseconds(200))
        XCTAssertEqual(index.entries.map(\.note.id), ordered.map(\.id))
        XCTAssertEqual(found.map(\.id), [ordered[7_499].id])
        XCTAssertEqual(index.byId.count, count)
        XCTAssertEqual(index.tags.first?.count, count)
        XCTAssertEqual(index.tags.first?.children.map(\.count).sorted(), [4_110, 4_111])
        XCTAssertEqual(index.heatmap.count, 84)
        XCTAssertEqual(index.heatmap.reduce(0) { $0 + $1.count }, count)

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NoteCacheStore(directory: directory)
        let accountA = NoteCacheStore.Key(origin: "http://example.com", userId: "a")
        let accountB = NoteCacheStore.Key(origin: "http://example.com", userId: "b")
        let serverB = NoteCacheStore.Key(origin: "https://example.com", userId: "a")
        try await cache.save(scrambled, for: accountA)
        let absentAccount = try await cache.load(accountB)
        let absentServer = try await cache.load(serverB)
        XCTAssertNil(absentAccount)
        XCTAssertNil(absentServer)
        try await cache.save([ordered[0]], for: accountB)
        try await cache.save([ordered[1]], for: serverB)
        let restored = try await NoteCacheStore(directory: directory).load(accountA)
        XCTAssertEqual(restored?.map(\.id), scrambled.map(\.id))
        XCTAssertEqual(restored?.map(\.revision), scrambled.map(\.revision))
        try await cache.invalidate(accountA)
        let erased = try await cache.load(accountA)
        let otherAccount = try await cache.load(accountB)
        let otherServer = try await cache.load(serverB)
        XCTAssertNil(erased)
        XCTAssertEqual(otherAccount?.first?.id, ordered[0].id)
        XCTAssertEqual(otherServer?.first?.id, ordered[1].id)
    }
}
