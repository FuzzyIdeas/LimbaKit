import Foundation
@testable import LimbaKit
import LimbaCore
import XCTest

final class DirectoryWatcherTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        // Resolved, because FSEvents reports /private/var paths for the /var temporary folder.
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("limba-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEventsArriveOnTheMainThread() throws {
        let arrived = expectation(description: "event")
        arrived.assertForOverFulfill = false
        let watcher = DirectoryWatcher(url: root, latency: 0.05) { paths in
            XCTAssertTrue(Thread.isMainThread)
            if paths.contains(where: { $0.hasSuffix("/a.strings") }) { arrived.fulfill() }
        }
        XCTAssertNotNil(watcher)
        // The stream starts on a background queue, so give it a moment before the write.
        Thread.sleep(forTimeInterval: 0.3)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.strings"))
        wait(for: [arrived], timeout: 5)
        withExtendedLifetime(watcher) {}
    }

    func testNoEventsAfterTheWatcherIsGone() throws {
        let late = expectation(description: "no event after deinit")
        late.isInverted = true
        var watcher = DirectoryWatcher(url: root, latency: 0.05) { _ in late.fulfill() }
        XCTAssertNotNil(watcher)
        Thread.sleep(forTimeInterval: 0.3)
        watcher = nil
        try Data("x".utf8).write(to: root.appendingPathComponent("b.strings"))
        wait(for: [late], timeout: 1)
    }

    func testAtomicWriteReplacesTheFile() throws {
        let url = root.appendingPathComponent("state.json")
        try StringsFiles.writeAtomically(Data("one".utf8), to: url)
        try StringsFiles.writeAtomically(Data("two".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }
}
