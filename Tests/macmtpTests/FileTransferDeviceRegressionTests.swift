import XCTest
import CryptoKit
import Foundation
@testable import macmtp

/// Opt-in: only uses a new UUID-named fixture on the connected MTP device.
@MainActor
final class FileTransferDeviceRegressionTests: XCTestCase {
    func testDeviceRegressions() async throws {
        guard ProcessInfo.processInfo.environment["MACMTP_RUN_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Set MACMTP_RUN_DEVICE_TESTS=1 with an idle MTP device; close the app first.")
        }
        let bridge = LibMTPBridge.shared
        _ = try await bridge.initialize()
        let storages = try await bridge.fetchStorages()
        let sid = try XCTUnwrap(storages.first?.Sid)
        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent("macmtp-fix-device-" + UUID().uuidString)
        let remote = "/macmtp-fix-" + UUID().uuidString
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        let before = try await bridge.walk(storageId: sid, path: "/", recursive: false, skipHidden: false)
        let service = FileTransferService(bridge: bridge, notificationHandler: { _,_,_ in }, directoryRefreshHandler: { _ in })
        var records: [[String: String]] = []
        func record(_ id: String, _ ok: Bool, _ result: String) {
            records.append(["id": id,"status":ok ? "PASS" : "FAIL","actual":result])
            print("DEVICE \(id) \(ok ? "PASS" : "FAIL"): \(result)")
            XCTAssertTrue(ok, "\(id): \(result)")
        }
        func write(_ path: String, _ data: Data = Data("new-source".utf8)) throws -> URL {
            let url = local.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        func node(_ path: String, dir: Bool = false) -> FileNode {
            FileNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: dir, size: 0, modificationDate: Date())
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(180)
            while !condition() {
                guard Date() < deadline else { throw NSError(domain:"DeviceRegressionTimeout",code:1) }
                try await Task.sleep(nanoseconds:5_000_000)
            }
        }
        func transfer(_ nodes: [FileNode], _ target: String, _ direction: TransferDirection = .localToMTP,
                      cut: Bool = false, resolution: ConflictResolution = .overwrite) async throws -> TransferBatch {
            service.initiateTransfer(sources:nodes,destinationDir:target,direction:direction,storageId:sid,isCut:cut,conflictResolution:resolution)
            try await wait { !service.requestInProgress }
            if let batch = service.activeBatch { return batch }
            throw MTPBridgeError.transferFailed(service.transferError ?? "No batch was created")
        }
        func upload(_ urls: [URL], _ target: String) async throws {
            try await bridge.uploadFiles(storageId:sid,sources:urls.map(\.path),destination:target,onPreprocess:{_ in},onProgress:{_ in})
        }
        func hash(_ url: URL) throws -> String {
            SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()
        }
        func remoteHash(_ path: String, _ tag: String) async throws -> String {
            let dest = local.appendingPathComponent("readback/"+tag)
            try fm.createDirectory(at:dest,withIntermediateDirectories:true)
            try await bridge.downloadFiles(storageId:sid,sources:[path],destination:dest.path,onPreprocess:{_ in},onProgress:{_ in})
            return try hash(dest.appendingPathComponent((path as NSString).lastPathComponent))
        }
        func exists(_ path: String) async throws -> Bool {
            try await bridge.checkFilesExist(storageId:sid,paths:[path]).first == true
        }
        func saveRecords() throws {
            guard let path = ProcessInfo.processInfo.environment["MACMTP_DEVICE_RESULTS"] else { return }
            try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        }
        try await bridge.makeDirectory(storageId:sid,path:remote)
        do {
            let three = try [write("source/one.txt",Data(repeating:65,count:1024)),write("source/two.pdf",Data(repeating:66,count:2048)),write("source/三号 文件.epub",Data(repeating:67,count:3072))]
            let batch = try await transfer(three.map{node($0.path)},remote+"/roundtrip")
            var hashesMatch = batch.completedFileCount == 3 && batch.failedFileCount == 0
            for source in three {
                let returned = try await remoteHash(remote+"/roundtrip/"+source.lastPathComponent,source.lastPathComponent)
                let sourceHash = try hash(source)
                hashesMatch = hashesMatch && returned == sourceHash
            }
            record("ROUNDTRIP",hashesMatch,"3 uploaded and read back; all SHA-256 matched=\(hashesMatch)")

            let skipped = try write("cut-upload/same.txt"), fresh = try write("cut-upload/fresh.txt")
            let old = try write("old/same.txt",Data("old-target".utf8))
            try await bridge.makeDirectory(storageId:sid,path:remote+"/skip-upload")
            try await upload([old],remote+"/skip-upload")
            let skippedBatch = try await transfer([node(skipped.path),node(fresh.path)],remote+"/skip-upload",cut:true,resolution:.skip)
            let targetHash = try await remoteHash(remote+"/skip-upload/same.txt","skip-upload")
            let oldHash = try hash(old)
            record("BUG-01-UPLOAD",fm.fileExists(atPath:skipped.path) && !fm.fileExists(atPath:fresh.path) && targetHash == oldHash,"skipped=\(skippedBatch.items.filter{$0.status == .skipped}.count); skipped source preserved; fresh source removed; old target hash checked")

            let target = try write("cut-download/same.txt",Data("existing-local".utf8))
            let sameHash = try hash(target)
            let down = try await transfer([node(remote+"/roundtrip/one.txt"),node(remote+"/skip-upload/same.txt")],target.deletingLastPathComponent().path,.mtpToLocal,cut:true,resolution:.skip)
            let remoteSkippedExists = try await exists(remote+"/skip-upload/same.txt")
            let remoteMovedExists = try await exists(remote+"/roundtrip/one.txt")
            let targetAfterHash = try hash(target)
            record("BUG-01-DOWNLOAD",remoteSkippedExists && !remoteMovedExists && targetAfterHash == sameHash,"completed=\(down.completedFileCount); skipped remote source preserved=\(remoteSkippedExists); completed source removed=\(!remoteMovedExists)")

            let empty = local.appendingPathComponent("empty")
            try fm.createDirectory(at:empty.appendingPathComponent("child"),withIntermediateDirectories:true)
            let emptyBatch = try await transfer([node(empty.path,dir:true)],remote+"/empty-upload")
            let emptyExists = try await exists(remote+"/empty-upload/empty/child")
            record("BUG-02-UPLOAD",emptyExists && emptyBatch.failedFileCount == 0,"empty nested directory exists=\(emptyExists); queue entries=\(emptyBatch.items.count)")
            let emptyReturn = local.appendingPathComponent("empty-return")
            let emptyDown = try await transfer([node(remote+"/empty-upload/empty",dir:true)],emptyReturn.path,.mtpToLocal)
            let emptyReturned = fm.fileExists(atPath:emptyReturn.appendingPathComponent("empty/child").path)
            record("BUG-02-DOWNLOAD",emptyReturned && emptyDown.overallProgress == 1,"nested empty directory returned=\(emptyReturned); progress=\(emptyDown.overallProgress)")

            let tree = try write("tree/file.txt").deletingLastPathComponent()
            try fm.createDirectory(at:tree.appendingPathComponent("empty-child"),withIntermediateDirectories:false)
            _ = try await transfer([node(tree.path,dir:true)],remote+"/tree-upload",cut:true)
            let migrated = try await exists(remote+"/tree-upload/tree/empty-child")
            record("BUG-03-UPLOAD",migrated && !fm.fileExists(atPath:tree.path),"target empty-child=\(migrated); source tree removed only after all entries complete")
            let treeReturn = local.appendingPathComponent("tree-return")
            _ = try await transfer([node(remote+"/tree-upload/tree",dir:true)],treeReturn.path,.mtpToLocal,cut:true)
            let remoteTreeExists = try await exists(remote+"/tree-upload/tree")
            record("BUG-03-DOWNLOAD",!remoteTreeExists && fm.fileExists(atPath:treeReturn.appendingPathComponent("tree/empty-child").path),"downloaded tree retains empty child; remote source removed=\(!remoteTreeExists)")

            let large = try write("busy/large.bin",Data(repeating:0xAB,count:32*1024*1024)), second = try write("busy/second.txt")
            let largeHash = try hash(large)
            service.initiateTransfer(sources:[node(large.path)],destinationDir:remote+"/busy",direction:.localToMTP,storageId:sid,isCut:true,conflictResolution:.overwrite)
            try await wait { service.activeBatch?.items.contains{$0.bytesTransferred > 0 && $0.status == .transferring} == true }
            let active = try XCTUnwrap(service.activeBatch)
            service.initiateTransfer(sources:[node(second.path)],destinationDir:remote+"/rejected",direction:.localToMTP,storageId:sid)
            let rejectedWithoutCancellation = service.activeBatch === active && active.state == .transferring && service.transferError != nil
            try await wait { !service.requestInProgress }
            let largeRemoteHash = try await remoteHash(remote+"/busy/large.bin","busy")
            let rejectedTarget = try await exists(remote+"/rejected")
            record("BUG-04",rejectedWithoutCancellation && active.state == .completed && !rejectedTarget && largeRemoteHash == largeHash && !fm.fileExists(atPath:large.path),"real in-flight 32 MiB cut A completed with matching SHA-256; B rejected; A cut metadata retained")

            service.initiateTransfer(sources:[node(local.appendingPathComponent("missing").path)],destinationDir:remote,direction:.localToMTP,storageId:sid)
            try await wait { !service.requestInProgress }
            record("BUG-05",service.transferError != nil && service.activeBatch == nil,"missing local source produces visible error property; no batch/write")

            let newline = try write("newline/换行\nname:one.txt")
            let originalNewlineHash = try hash(newline)
            let payload = FileExplorerPane.internalPayload(for:[DroppedFile(path:newline.path,isLocal:true,name:newline.lastPathComponent,isDirectory:false)])
            let parsed = FileExplorerPane.droppedFiles(fromInternalPayload:payload)
            let namedBatch = try await transfer(parsed.map{node($0.path)},remote+"/newline",cut:true)
            let actualEntries = try await bridge.walk(storageId:sid,path:remote+"/newline",recursive:false,skipHidden:false)
            if namedBatch.failedFileCount > 0 {
                let preserved = fm.fileExists(atPath:newline.path)
                let errors = namedBatch.items.compactMap(\.error)
                let explicitError = !errors.isEmpty && service.transferError != nil
                record("BUG-06",parsed.first?.path == newline.path && preserved && explicitError,
                       "payload intact; device rejected name; visible errors=\(errors); destination names=\(actualEntries.map(\.name)); cut source preserved=\(preserved)")
            } else {
                let newlineHash = try await remoteHash(remote+"/newline/"+newline.lastPathComponent,"newline")
                record("BUG-06",parsed.first?.path == newline.path && newlineHash == originalNewlineHash,
                       "newline/colon/Chinese name preserved by payload and device; SHA-256 checked")
            }

            try await bridge.deleteFiles(storageId:sid,paths:[remote])
            let after = try await bridge.walk(storageId:sid,path:"/",recursive:false,skipHidden:false)
            record("CLEANUP",Set(after.map(\.path)) == Set(before.map(\.path)),"fixture removed; original root path set unchanged; count=\(after.count)")
            try saveRecords()
            try await bridge.dispose()
        } catch {
            records.append(["id":"UNEXPECTED","status":"FAIL","actual":String(describing:error)])
            try? await bridge.deleteFiles(storageId:sid,paths:[remote])
            try? saveRecords()
            try? await bridge.dispose()
            throw error
        }
    }
}
