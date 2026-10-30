import XCTest
import Foundation
import CryptoKit
@testable import macmtp

@MainActor
final class LiveFunctionalTests: XCTestCase {
    let bridge = LibMTPBridge.shared
    let service = FileTransferService.shared
    let fm = FileManager.default
    let local = URL(fileURLWithPath: "/tmp/macmtp-fulltest-20261029/data")
    let evidence = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACMTP_EVIDENCE_DIR"] ?? FileManager.default.currentDirectoryPath + "/docs/test-reports/2026-10-29/evidence")
    let remote = "/macmtp-test-20261029-1554"
    var sid: UInt32 = 0
    var results: [[String: String]] = []
    var resultsFilename = "live-results.json"

    func record(_ id: String, _ cases: String, _ ok: Bool, _ actual: String) {
        results.append(["id": id, "cases": cases, "status": ok ? "PASS" : "FAIL", "actual": actual])
        print("LIVE \(id) \(ok ? "PASS" : "FAIL"): \(actual)")
        try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(resultsFilename))
    }
    func scenario(_ id: String, _ cases: String, _ operation: () async throws -> (Bool, String)) async {
        do { let (ok, actual) = try await operation(); record(id, cases, ok, actual) }
        catch { record(id, cases, false, "error: \(error.localizedDescription)") }
    }
    func write(_ path: String, _ data: Data) throws -> String {
        let url = local.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.path
    }
    func hash(_ path: String) throws -> String { SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined() }
    func node(_ path: String, directory: Bool = false) -> FileNode {
        FileNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: directory, size: 0, modificationDate: Date())
    }
    func mkdir(_ path: String) async throws { try await bridge.makeDirectory(storageId: sid, path: path) }
    func list(_ path: String, recursive: Bool = false) async throws -> [GoFileInfo] { try await bridge.listDirectory(storageId: sid, path: path, recursive: recursive) }
    func upload(_ paths: [String], _ destination: String) async throws {
        try await bridge.uploadFiles(storageId: sid, sources: paths, destination: destination, onPreprocess: { _ in }, onProgress: { _ in })
    }
    func read(_ path: String, _ tag: String) async throws -> String {
        let dest = local.appendingPathComponent("readback/\(tag)")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try await bridge.downloadFiles(storageId: sid, sources: [path], destination: dest.path, onPreprocess: { _ in }, onProgress: { _ in })
        return dest.appendingPathComponent((path as NSString).lastPathComponent).path
    }
    func waitUntil(_ timeout: Double = 180, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { throw NSError(domain: "LiveTestTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    func transfer(_ nodes: [FileNode], _ destination: String, direction: TransferDirection = .localToMTP, cut: Bool = false, resolution: ConflictResolution = .overwrite) async throws -> TransferBatch {
        service.activeBatch = nil
        service.initiateTransfer(sources: nodes, destinationDir: destination, direction: direction, storageId: sid, isCut: cut, conflictResolution: resolution)
        try await waitUntil { self.service.activeBatch?.state.isTerminal == true }
        return try XCTUnwrap(service.activeBatch)
    }

    func testLiveFunctionalMatrix() async throws {
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        let info = try await bridge.initialize()
        let storages = try await bridge.fetchStorages()
        sid = try XCTUnwrap(storages.first?.Sid)
        let caps = try await bridge.fetchCapabilities()
        record("HW-CONNECT", "TC-CON-02,TC-CON-11", !storages.isEmpty, "device=\(String(describing: info.mtpDeviceInfo?.Model)); storages=\(storages.count); storageId=\(sid); capabilities=\(caps)")
        // Remove only the uniquely named fixture created by the aborted first attempt.
        for previousRoot in ["/macmtp-test-20261029-1542", "/macmtp-test-20261029-1550"] {
            if try await list("/").contains(where: { $0.path == previousRoot }) {
                try await bridge.deleteFiles(storageId: sid, paths: [previousRoot])
            }
        }
        let before = try await list("/")
        guard !before.contains(where: { $0.path == remote }) else { throw NSError(domain: "FixtureAlreadyExists", code: 1) }
        try await mkdir(remote)
        let files = try [write("source/one.txt", Data(repeating: 65, count: 1024)), write("source/two.pdf", Data(repeating: 66, count: 2048)), write("source/三号 文件.epub", Data(repeating: 67, count: 3072))]
        await scenario("HW-ROUNDTRIP", "TC-TRN-01,TC-TRN-09") {
            try await self.mkdir(self.remote + "/basic")
            try await self.upload(files, self.remote + "/basic")
            var pairs: [String] = []; var ok = true
            for source in files {
                let name = (source as NSString).lastPathComponent
                let returned = try await self.read(self.remote + "/basic/" + name, "basic")
                let lhs = try self.hash(source), rhs = try self.hash(returned)
                ok = ok && lhs == rhs && self.fm.fileExists(atPath: source)
                pairs.append("\(name):\(lhs)=\(rhs)")
            }
            return (ok, pairs.joined(separator: "; "))
        }
        await scenario("HW-MANAGEMENT", "TC-FIL-01,TC-FIL-03,TC-FIL-06") {
            let dir = self.remote + "/manage"
            try await self.mkdir(dir)
            try await self.upload([files[0]], dir)
            try await self.bridge.renameFile(storageId: self.sid, path: dir + "/one.txt", newName: "改名 测试.txt")
            let renamed = try await self.list(dir)
            try await self.mkdir(dir + "/nested")
            try await self.upload([files[1]], dir + "/nested")
            try await self.bridge.deleteFiles(storageId: self.sid, paths: [dir])
            let after = try await self.list(self.remote)
            return (renamed.contains { $0.name == "改名 测试.txt" } && !after.contains { $0.path == dir }, "renameNames=\(renamed.map(\.name)); recursivelyDeleted=\(!after.contains { $0.path == dir })")
        }
        await scenario("HW-COPY-MOVE", "TC-CLP-08,TC-CLP-09") {
            try await self.mkdir(self.remote + "/copy")
            try await self.mkdir(self.remote + "/move")
            try await self.bridge.copyFile(storageId: self.sid, sourcePath: self.remote + "/basic/one.txt", destinationParentPath: self.remote + "/copy")
            try await self.bridge.moveFile(storageId: self.sid, sourcePath: self.remote + "/copy/one.txt", destinationParentPath: self.remote + "/move")
            let copied = try await self.list(self.remote + "/copy"), moved = try await self.list(self.remote + "/move")
            let returned = try await self.read(self.remote + "/move/one.txt", "moved")
            return (try copied.isEmpty && moved.count == 1 && (try self.hash(returned)) == (try self.hash(files[0])), "copySourceAfterMove=\(copied.count); moved=\(moved.map(\.name)); hash=\(try self.hash(returned))")
        }
        await scenario("HW-SERVICE-BATCH", "TC-TRN-01,TC-TRN-02") {
            let batch = try await self.transfer(files.map { self.node($0) }, self.remote + "/service")
            var ok = batch.completedFileCount == 3 && batch.failedFileCount == 0
            for path in files {
                let returned = try await self.read(self.remote + "/service/" + (path as NSString).lastPathComponent, "service")
                ok = try ok && (try self.hash(returned)) == (try self.hash(path))
            }
            return (ok, "completed=\(batch.completedFileCount); failed=\(batch.failedFileCount); all 3 SHA256 compared")
        }
        await scenario("HW-ZERO", "TC-TRN-08") {
            let zero = try self.write("zero/zero.bin", Data())
            let batch = try await self.transfer([self.node(zero)], self.remote + "/zero")
            let returned = try await self.read(self.remote + "/zero/zero.bin", "zero")
            return (try batch.completedFileCount == 1 && (try self.hash(zero)) == (try self.hash(returned)), "completed=\(batch.completedFileCount); batchProgress=\(batch.overallProgress); returnedSize=\((try self.fm.attributesOfItem(atPath: returned))[.size]!)")
        }
        await scenario("HW-TREE", "TC-TRN-06,TC-TRN-12") {
            let a = try self.write("tree/level1/a.txt", Data("first".utf8))
            let b = try self.write("tree/level1/level2/a.txt", Data("second".utf8))
            let hidden = try self.write("tree/.hidden-dir/.hidden.txt", Data("hidden".utf8))
            let batch = try await self.transfer([self.node(self.local.appendingPathComponent("tree").path, directory: true)], self.remote + "/recursive")
            let destination = self.local.appendingPathComponent("tree-return")
            try self.fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let down = try await self.transfer([self.node(self.remote + "/recursive/tree", directory: true)], destination.path, direction: .mtpToLocal)
            let pairs = [a,b,hidden]
            let ok = try pairs.allSatisfy { path in
                let relative = String(path.dropFirst(self.local.path.count + 1))
                return try self.hash(path) == self.hash(destination.appendingPathComponent(relative).path)
            }
            return (ok && batch.completedFileCount == 3 && down.completedFileCount == 3, "upload=\(batch.completedFileCount); download=\(down.completedFileCount); repeated basename and hidden file SHA256 compared")
        }
        await scenario("HW-EMPTY-DIR", "TC-TRN-07") {
            let dir = self.local.appendingPathComponent("empty-dir")
            try self.fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let batch = try await self.transfer([self.node(dir.path, directory: true)], self.remote)
            let items = try await self.list(self.remote)
            return (items.contains { $0.name == "empty-dir" }, "queueItems=\(batch.items.count); targetEmptyDirExists=\(items.contains { $0.name == "empty-dir" })")
        }
        for (label,resolution) in [("overwrite",ConflictResolution.overwrite),("skip",.skip),("different",.overwriteIfDifferent),("same",.skipIfSameSize)] {
            await scenario("HW-CONFLICT-\(label)", "TC-CFL-02,TC-CFL-03,TC-CFL-04,TC-CFL-05") {
                let dest = self.remote + "/conflict-" + label
                try await self.mkdir(dest)
                let oldSame = try self.write("old/\(label)/same.bin", Data("OLD!".utf8)), oldDiff = try self.write("old/\(label)/diff.bin", Data("old".utf8))
                try await self.upload([oldSame,oldDiff], dest)
                let newSame = try self.write("new/\(label)/same.bin", Data("NEW!".utf8)), newDiff = try self.write("new/\(label)/diff.bin", Data("new-longer".utf8))
                let batch = try await self.transfer([self.node(newSame),self.node(newDiff)], dest, resolution: resolution)
                let same = try await self.read(dest + "/same.bin", label), diff = try await self.read(dest + "/diff.bin", label)
                let expectedSame = resolution == .overwrite ? newSame : oldSame
                let expectedDiff = resolution == .skip ? oldDiff : newDiff
                let ok = try self.hash(same) == self.hash(expectedSame) && self.hash(diff) == self.hash(expectedDiff)
                return (ok, "completed=\(batch.completedFileCount); skipped=\(batch.items.filter { $0.status == .skipped }.count); sameHash=\(try self.hash(same)); differentHash=\(try self.hash(diff))")
            }
        }
        await scenario("HW-CUT-SKIP", "TC-CLP-04") {
            let dir = self.remote + "/cut-skip"
            try await self.mkdir(dir)
            let old = try self.write("cut-old/skip.txt", Data("target".utf8))
            try await self.upload([old], dir)
            let source = try self.write("cut-source/skip.txt", Data("source".utf8))
            let batch = try await self.transfer([self.node(source)], dir, cut: true, resolution: .skip)
            return (self.fm.fileExists(atPath: source), "status=\(batch.items.map { $0.status.rawValue }); skippedSourcePreserved=\(self.fm.fileExists(atPath: source))")
        }
        await scenario("HW-CUT-SUCCESS", "TC-CLP-03") {
            let source = try self.write("cut-success/source.txt", Data("move-this".utf8))
            let expected = try self.hash(source)
            let up = try await self.transfer([self.node(source)], self.remote + "/cut-success", cut: true)
            let localGone = !self.fm.fileExists(atPath: source)
            let dest = self.local.appendingPathComponent("cut-return")
            try self.fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let down = try await self.transfer([self.node(self.remote + "/cut-success/source.txt")], dest.path, direction: .mtpToLocal, cut: true)
            let remoteAfter = try await self.list(self.remote + "/cut-success")
            return (try localGone && remoteAfter.isEmpty && (try self.hash(dest.appendingPathComponent("source.txt").path)) == expected, "uploadCompleted=\(up.completedFileCount); downloadCompleted=\(down.completedFileCount); localSourceRemoved=\(localGone); remoteSourceRemoved=\(remoteAfter.isEmpty)")
        }
        await scenario("HW-100-FILES", "TC-TRN-10") {
            var nodes: [FileNode] = []
            for index in 0..<100 { nodes.append(self.node(try self.write("many/f\(index).bin", Data(repeating: UInt8(index), count: 1024)))) }
            let start = Date()
            let batch = try await self.transfer(nodes, self.remote + "/many")
            let out = self.local.appendingPathComponent("many-return")
            try self.fm.createDirectory(at: out, withIntermediateDirectories: true)
            let down = try await self.transfer(nodes.map { self.node(self.remote + "/many/" + $0.name) }, out.path, direction: .mtpToLocal)
            let ok = try nodes.allSatisfy { try self.hash($0.path) == self.hash(out.appendingPathComponent($0.name).path) }
            return (ok && batch.completedFileCount == 100 && down.completedFileCount == 100, "uploaded=\(batch.completedFileCount); downloaded=\(down.completedFileCount); SHA256Matched=\(ok); elapsedSeconds=\(Date().timeIntervalSince(start))")
        }
        await scenario("HW-INVALID-SOURCE", "TC-QUE-07") {
            let source = self.local.appendingPathComponent("missing/not-present.txt").path
            self.service.activeBatch = nil
            self.service.initiateTransfer(sources: [self.node(source)], destinationDir: self.remote + "/missing", direction: .localToMTP, storageId: self.sid)
            try await Task.sleep(nanoseconds: 300_000_000)
            return (self.service.activeBatch?.failedFileCount == 1, "activeBatch=\(String(describing: self.service.activeBatch?.state)); failed=\(self.service.activeBatch?.failedFileCount ?? 0); source does not exist, error expected")
        }
        await scenario("HW-BUSY", "TC-QUE-05") {
            let active = TransferBatch(); active.items = [TransferItem(sourcePath: files[0], destinationPath: self.remote + "/busy/one.txt", fileSize: 1024, direction: .localToMTP)]; active.start()
            self.service.activeBatch = active
            self.service.initiateTransfer(sources: [self.node(files[1])], destinationDir: self.remote + "/busy", direction: .localToMTP, storageId: self.sid)
            try await Task.sleep(nanoseconds: 300_000_000)
            return (active.state == .transferring, "existingBatchStateAfterRejectedSecondRequest=\(active.state); controlled pre-existing batch, no background transfer")
        }
        service.activeBatch = nil
        await scenario("HW-PAUSE-RESUME", "TC-QUE-02") {
            let first = try self.write("large/first.bin", Data(repeating: 81, count: 32 * 1024 * 1024))
            let second = try self.write("large/second.bin", Data(repeating: 82, count: 32 * 1024 * 1024))
            self.service.activeBatch = nil
            self.service.initiateTransfer(sources: [self.node(first),self.node(second)], destinationDir: self.remote + "/pause", direction: .localToMTP, storageId: self.sid, conflictResolution: .overwrite)
            try await self.waitUntil(180) { self.service.activeBatch?.items.contains { $0.status == .transferring && $0.bytesTransferred > 0 } == true }
            self.service.pauseTransfer()
            let batch = try XCTUnwrap(self.service.activeBatch)
            try await self.waitUntil(60) { batch.completedFileCount >= 1 }
            try await Task.sleep(nanoseconds: 300_000_000)
            let pausedCorrectly = batch.state == .paused && batch.completedFileCount == 1
            self.service.resumeTransfer()
            try await self.waitUntil(60) { batch.state.isTerminal }
            return (pausedCorrectly && batch.completedFileCount == 2, "pausedAtOne=\(pausedCorrectly); completedAfterResume=\(batch.completedFileCount)")
        }
        await scenario("HW-CANCEL", "TC-QUE-03,TC-CLP-05") {
            let first = self.local.appendingPathComponent("large/first.bin").path, second = self.local.appendingPathComponent("large/second.bin").path
            try await self.mkdir(self.remote + "/cancel")
            self.service.activeBatch = nil
            self.service.initiateTransfer(sources: [self.node(first),self.node(second)], destinationDir: self.remote + "/cancel", direction: .localToMTP, storageId: self.sid, isCut: true, conflictResolution: .overwrite)
            try await self.waitUntil { self.service.activeBatch?.state == .transferring }
            let batch = try XCTUnwrap(self.service.activeBatch)
            self.service.cancelTransfer()
            // Actor request waits for any in-flight synchronous transfer; then verify files.
            let items = try await self.list(self.remote + "/cancel")
            try await Task.sleep(nanoseconds: 300_000_000)
            return (batch.state == .cancelled && items.count <= 1 && self.fm.fileExists(atPath: first) && self.fm.fileExists(atPath: second), "state=\(batch.state); destinationFileCount=\(items.count); bothSourcesPreserved=\(self.fm.fileExists(atPath: first) && self.fm.fileExists(atPath: second))")
        }
        await scenario("HW-CLEANUP", "fixture cleanup") {
            self.service.activeBatch = nil
            try await self.bridge.deleteFiles(storageId: self.sid, paths: [self.remote])
            let after = try await self.list("/")
            let previous = Set(before.map(\.path)), current = Set(after.map(\.path))
            return (previous == current, "testRootDeleted=\(!after.contains { $0.path == self.remote }); originalRootPathSetUnchanged=\(previous == current)")
        }
        try await bridge.dispose()
        let failed = results.filter { $0["status"] == "FAIL" }
        print("LIVE_SUMMARY total=\(results.count) passed=\(results.count - failed.count) failed=\(failed.count)")
        XCTAssertTrue(failed.isEmpty, "Observed product failures: \(failed.compactMap { $0["id"] }.joined(separator: ", "))")
    }
}
