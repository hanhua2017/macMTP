import XCTest
import Foundation
@testable import macmtp

@MainActor
final class CleanupUIFixtureTests: XCTestCase {
    func testCleanupUIFixture() async throws {
        let h = LiveFunctionalTests()
        _ = try await h.bridge.initialize()
        let storages = try await h.bridge.fetchStorages()
        h.sid = try XCTUnwrap(storages.first?.Sid)
        let root = "/macmtp-ui-test-20261029"
        let before = try await h.list("/")
        let contents = try await h.list(root, recursive: true)
        let expected = Set(["one.txt", "two.pdf", "三号 文件.epub"])
        XCTAssertEqual(Set(contents.map(\.name)), expected)
        guard Set(contents.map(\.name)) == expected else {
            throw NSError(domain: "UnexpectedFixtureContents", code: 1)
        }
        var hashes: [String: String] = [:]
        for entry in contents {
            let local = try await h.read(entry.path, "ui-final-cleanup")
            hashes[entry.name] = try h.hash(local)
        }
        try await h.bridge.deleteFiles(storageId: h.sid, paths: [root])
        let after = try await h.list("/")
        let preserved = Set(after.map(\.path)) == Set(before.map(\.path)).subtracting([root])
        XCTAssertTrue(preserved)
        let result: [String: Any] = ["fixture":root, "deleted": !after.contains { $0.path == root }, "otherRootPathsUnchanged":preserved, "rootCountAfter":after.count,"preDeletionSHA256":hashes]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:h.evidence.appendingPathComponent("ui-cleanup.json"))
        print("UI-CLEANUP PASS: fixture deleted; other root paths unchanged=\(preserved); root count=\(after.count)")
        try await h.bridge.dispose()
    }
}
