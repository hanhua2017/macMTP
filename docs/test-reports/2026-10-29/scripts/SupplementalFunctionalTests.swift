import XCTest
import Foundation
@testable import macmtp

@MainActor
final class SupplementalFunctionalTests: XCTestCase {
    func testAdditionalScenarios() async throws {
        let h = LiveFunctionalTests()
        h.resultsFilename = "supplemental-results.json"
        let bridge = h.bridge, service = h.service
        _ = try await bridge.initialize()
        let availableStorages = try await bridge.fetchStorages()
        h.sid = try XCTUnwrap(availableStorages.first?.Sid)
        let root = "/macmtp-test-20261029-supplement"
        let initial = try await h.list("/")
        guard !initial.contains(where: { $0.path == root }) else { throw NSError(domain: "FixtureAlreadyExists", code: 1) }
        try await h.mkdir(root)
        for (label,resolution) in [("overwrite",ConflictResolution.overwrite),("skip",.skip),("different",.overwriteIfDifferent),("same",.skipIfSameSize)] {
            await h.scenario("EX-DOWNLOAD-CONFLICT-\(label)", "TC-CFL-02,TC-CFL-03,TC-CFL-04,TC-CFL-05") {
                let remote = root + "/" + label
                try await h.mkdir(remote)
                let newSame = try h.write("extra/source-\(label)/same.bin", Data("NEW!".utf8)), newDiff = try h.write("extra/source-\(label)/diff.bin", Data("new-longer".utf8)), fresh = try h.write("extra/source-\(label)/fresh.bin", Data("fresh".utf8))
                try await h.upload([newSame,newDiff,fresh], remote)
                let oldSame = try h.write("extra/destination-\(label)/same.bin", Data("OLD!".utf8)), oldDiff = try h.write("extra/destination-\(label)/diff.bin", Data("old".utf8))
                let oldSameHash = try h.hash(oldSame), oldDiffHash = try h.hash(oldDiff)
                let destination = (oldSame as NSString).deletingLastPathComponent
                let batch = try await h.transfer([h.node(remote + "/same.bin"),h.node(remote + "/diff.bin"),h.node(remote + "/fresh.bin")], destination, direction: .mtpToLocal, resolution: resolution)
                let sameExpected = resolution == .overwrite ? try h.hash(newSame) : oldSameHash
                let diffExpected = resolution == .skip ? oldDiffHash : try h.hash(newDiff)
                let good = try h.hash(oldSame) == sameExpected && h.hash(oldDiff) == diffExpected && h.hash(destination + "/fresh.bin") == h.hash(fresh)
                return (good, "completed=\(batch.completedFileCount); skipped=\(batch.items.filter { $0.status == .skipped }.count); same/different/fresh SHA256 checked")
            }
        }
        await h.scenario("EX-CANCEL-CONFLICT", "TC-CFL-06,TC-QUE-04") {
            let source = try h.write("extra/cancel-conflict/one.bin", Data("one".utf8))
            let remote = root + "/cancel-conflict"
            try await h.mkdir(remote); try await h.upload([source],remote)
            service.activeBatch = nil
            service.initiateTransfer(sources: [h.node(source)], destinationDir: remote, direction: .localToMTP, storageId: h.sid)
            try await h.waitUntil { service.showConflictDialog }
            service.resolveConflicts(with: .cancel)
            try await h.waitUntil { !service.showConflictDialog && service.activeBatch == nil }
            let batch = try await h.transfer([h.node(source)],root + "/after-cancel")
            return (batch.completedFileCount == 1, "conflict wait cancelled; subsequent task completed=\(batch.completedFileCount)")
        }
        await h.scenario("EX-PARTIAL-FAILURE", "TC-QUE-07,TC-QUE-08") {
            let remote = root + "/overwrite"
            let dest = h.local.appendingPathComponent("extra/partial-failure")
            try h.fm.createDirectory(at: dest.appendingPathComponent("same.bin"), withIntermediateDirectories: true)
            let batch = try await h.transfer([h.node(remote + "/same.bin"),h.node(remote + "/diff.bin"),h.node(remote + "/fresh.bin")], dest.path, direction: .mtpToLocal)
            return (batch.failedFileCount == 1 && batch.completedFileCount == 2, "state=\(batch.state); completed=\(batch.completedFileCount); failed=\(batch.failedFileCount); destination same.bin is directory")
        }
        await h.scenario("EX-DOWNLOAD-CUT-SKIP", "TC-CLP-04") {
            let remote = root + "/skip"
            let source = remote + "/fresh.bin"
            let target = try h.write("extra/cut-skip/fresh.bin", Data("existing".utf8))
            let batch = try await h.transfer([h.node(source)],(target as NSString).deletingLastPathComponent,direction: .mtpToLocal,cut:true,resolution:.skip)
            let items = try await h.list(remote)
            return (items.contains { $0.path == source }, "skipped=\(batch.items.filter { $0.status == .skipped }.count); skippedRemoteSourcePreserved=\(items.contains { $0.path == source })")
        }
        await h.scenario("EX-CUT-EMPTY-CHILD", "TC-CLP-06") {
            let source = h.local.appendingPathComponent("extra/cut-tree")
            try h.fm.createDirectory(at: source.appendingPathComponent("empty-child"), withIntermediateDirectories: true)
            _ = try h.write("extra/cut-tree/file.txt", Data("keep-empty-child".utf8))
            let batch = try await h.transfer([h.node(source.path,directory:true)],root + "/cut-tree",cut:true)
            let tree = try await h.list(root + "/cut-tree/cut-tree", recursive:true)
            let migrated = tree.contains { $0.name == "empty-child" }
            let preserved = h.fm.fileExists(atPath: source.appendingPathComponent("empty-child").path)
            return (migrated || preserved, "filesCompleted=\(batch.completedFileCount); targetEmptyChild=\(migrated); sourceEmptyChild=\(preserved)")
        }
        await h.scenario("EX-NEWLINE-PAYLOAD", "TC-DRG-09") {
            let path = "/tmp/macmtp-newline\nname.txt"
            let parsed = FileExplorerPane.droppedFiles(fromInternalPayload: "local:file:" + path)
            return (parsed.count == 1 && parsed.first?.path == path, "inputPath has newline; parsedCount=\(parsed.count); parsedPaths=\(parsed.map(\.path))")
        }
        await h.scenario("EX-PAUSE-RESUME", "TC-QUE-02") {
            let first = h.local.appendingPathComponent("large/first.bin").path, second = h.local.appendingPathComponent("large/second.bin").path
            service.activeBatch = nil
            service.initiateTransfer(sources: [h.node(first),h.node(second)],destinationDir:root + "/pause",direction:.localToMTP,storageId:h.sid,conflictResolution:.overwrite)
            try await h.waitUntil(180) { service.activeBatch?.items.contains { $0.status == .transferring && $0.bytesTransferred > 0 } == true }
            let batch = try XCTUnwrap(service.activeBatch)
            service.pauseTransfer()
            try await h.waitUntil(180) { batch.completedFileCount >= 1 }
            try await Task.sleep(nanoseconds:300_000_000)
            let paused = batch.state == .paused && batch.completedFileCount == 1
            service.resumeTransfer()
            try await h.waitUntil(180) { batch.state.isTerminal }
            return (paused && batch.completedFileCount == 2,"pause after actual nonzero byte progress; pausedAtOne=\(paused); completedAfterResume=\(batch.completedFileCount)")
        }
        await h.scenario("EX-LOGICAL-RECONNECT", "TC-CON-08") {
            try await bridge.dispose()
            _ = try await bridge.initialize()
            let storages = try await bridge.fetchStorages()
            return (storages.first?.Sid == h.sid, "logical disconnect/reconnect storageId=\(String(describing: storages.first?.Sid)); physical cable not unplugged")
        }
        try await bridge.deleteFiles(storageId: h.sid, paths: [root])
        let after = try await h.list("/")
        h.record("EX-CLEANUP","fixture cleanup", Set(after.map(\.path)) == Set(initial.map(\.path)), "supplemental test root removed; original root path set compared")
        try await bridge.dispose()
        let json = try JSONSerialization.data(withJSONObject: h.results, options:[.prettyPrinted,.sortedKeys])
        try json.write(to:h.evidence.appendingPathComponent("supplemental-results.json"))
        XCTAssertTrue(h.results.allSatisfy { $0["status"] == "PASS" },"Product expectations failed; see supplemental-results.json")
    }
}
