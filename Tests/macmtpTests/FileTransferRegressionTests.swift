import XCTest
import Foundation
@testable import macmtp

@MainActor
final class FileTransferRegressionTests: XCTestCase {
    private var fixture: URL!
    private var remote: URL!
    private var bridge: TransferFixtureBridge!
    private var service: FileTransferService!

    override func setUp() async throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("macmtp-regression-" + UUID().uuidString).resolvingSymlinksInPath()
        remote = fixture.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        bridge = TransferFixtureBridge(root: remote)
        service = FileTransferService(bridge: bridge, notificationHandler: { _, _, _ in }, directoryRefreshHandler: { _ in })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: fixture) }
    private func file(_ name: String, _ text: String = "new") throws -> URL {
        let url = fixture.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func node(_ path: String, directory: Bool = false) -> FileNode {
        FileNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: directory, size: 0, modificationDate: Date())
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { throw NSError(domain: "RegressionTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func finish() async throws { try await wait { !self.service.requestInProgress } }
    private func start(_ paths: [FileNode], _ dest: String, _ direction: TransferDirection = .localToMTP, cut: Bool = false, resolution: ConflictResolution = .overwrite) {
        service.initiateTransfer(sources: paths, destinationDir: dest, direction: direction, storageId: 1, isCut: cut, conflictResolution: resolution)
    }
    func testUploadCutSkipPreservesSkippedSourceAndMovesFreshFile() async throws {
        let skipped = try file("source/same.txt"), fresh = try file("source/fresh.txt")
        _ = try file("remote/target/same.txt", "old")
        start([node(skipped.path), node(fresh.path)], "/target", cut: true, resolution: .skip)
        try await finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: skipped.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("target/same.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("target/fresh.txt"), encoding: .utf8), "new")
    }
    func testDownloadCutSkipPreservesRemoteSource() async throws {
        _ = try file("remote/source/same.txt"); _ = try file("remote/source/fresh.txt")
        let target = try file("return/same.txt", "old").deletingLastPathComponent()
        start([node("/source/same.txt"),node("/source/fresh.txt")], target.path, .mtpToLocal, cut: true, resolution: .skip)
        try await finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("source/same.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("source/fresh.txt").path))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("same.txt"), encoding: .utf8), "old")
    }
    func testEmptyDirectoriesRoundTripIncludingNestedChild() async throws {
        let source = fixture.appendingPathComponent("source/empty/child")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        start([node(source.deletingLastPathComponent().path, directory: true)], "/upload")
        try await finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("upload/empty/child").path))
        XCTAssertEqual(service.activeBatch?.overallProgress, 1)
        let target = fixture.appendingPathComponent("return")
        start([node("/upload/empty", directory: true)], target.path, .mtpToLocal)
        try await finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("empty/child").path))
        XCTAssertEqual(service.activeBatch?.failedFileCount, 0)
    }
    func testCutTreeMigratesEmptyChildBeforeRemovingSource() async throws {
        let source = try file("tree/file.txt").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
        start([node(source.path, directory: true)], "/target", cut: true)
        try await finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("target/tree/empty").path))
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("target/tree/file.txt"), encoding: .utf8), "new")
    }
    func testFailedEmptyDirectoryCreationPreservesWholeCutTree() async throws {
        let source = try file("tree/file.txt").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
        _ = try file("remote/target/tree/empty", "blocking file")
        start([node(source.path, directory: true)], "/target", cut: true)
        try await finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("empty").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("file.txt").path))
        XCTAssertEqual(service.activeBatch?.failedFileCount, 1)
    }
    func testPartiallySkippedDirectoryIsNotDeleted() async throws {
        let source = try file("tree/same.txt").deletingLastPathComponent()
        _ = try file("tree/fresh.txt"); _ = try file("remote/target/tree/same.txt", "old")
        start([node(source.path, directory: true)], "/target", cut: true, resolution: .skip)
        try await finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("same.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testMissingSourceErrorsAreVisibleInBothDirections() async throws {
        for direction in TransferDirection.allCases {
            start([node(direction == .localToMTP ? fixture.appendingPathComponent("missing").path : "/missing")], direction == .localToMTP ? "/target" : fixture.path, direction)
            try await finish()
            XCTAssertNotNil(service.transferError)
            XCTAssertNil(service.activeBatch)
        }
    }
    func testSecondRequestDoesNotCancelInFlightCutOrChangeItsSources() async throws {
        let first = try file("source/first.txt"), second = try file("source/second.txt")
        await bridge.suspendNextUpload()
        start([node(first.path)], "/target", cut: true)
        try await wait { await self.bridge.uploadStarted }
        let original = try XCTUnwrap(service.activeBatch)
        start([node(second.path)], "/other", cut: false)
        XCTAssertTrue(service.activeBatch === original)
        XCTAssertEqual(original.state, .transferring)
        XCTAssertNotNil(service.transferError)
        await bridge.resumeUpload()
        try await finish()
        XCTAssertEqual(original.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("other").path))
    }
    func testSecondRequestIsRejectedBeforeFirstCreatesBatch() async throws {
        let first = try file("source/first"), second = try file("source/second")
        start([node(first.path)], "/target")
        start([node(second.path)], "/other", cut: true)
        XCTAssertNotNil(service.transferError)
        try await finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("target/first").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("other").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
    func testDeviceRenamedUploadReportsFailureAndPreservesCutSource() async throws {
        let source = try file("source/newline\nname.txt")
        await bridge.rewriteNextUploadName("normalized_name.txt")
        start([node(source.path)], "/target", cut: true)
        try await finish()
        XCTAssertEqual(service.activeBatch?.failedFileCount, 1)
        XCTAssertTrue(service.activeBatch?.items.first?.error?.contains("destination filename") == true)
        XCTAssertNotNil(service.transferError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testDeviceTruncatedUploadReportsFailureAndPreservesCutSource() async throws {
        let source = try file("source/file.txt")
        await bridge.truncateNextUpload()
        start([node(source.path)], "/target", cut: true)
        try await finish()
        XCTAssertEqual(service.activeBatch?.failedFileCount, 1)
        XCTAssertTrue(service.activeBatch?.items.first?.error?.contains("size does not match") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testCancelledInFlightRequestRetainsOwnershipUntilBridgeReturns() async throws {
        let first = try file("source/first"), second = try file("source/second")
        await bridge.suspendNextUpload()
        start([node(first.path)], "/target", cut: true)
        try await wait { await self.bridge.uploadStarted }
        service.cancelTransfer()
        start([node(second.path)], "/other")
        XCTAssertEqual(service.activeBatch?.state, .cancelled)
        await bridge.resumeUpload()
        try await finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("other").path))
    }
}
