import Foundation
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let localDirectoryNeedsRefresh = Notification.Name("localDirectoryNeedsRefresh")
    static let menuNewFolderRequested = Notification.Name("menuNewFolderRequested")
    static let menuRefreshRequested = Notification.Name("menuRefreshRequested")
}

private final class TransferProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastPublishByKey: [String: Date] = [:]

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func shouldPublish(key: String, sent: Int64, total: Int64, now: Date = Date()) -> Bool {
        if total > 0 && sent >= total {
            return true
        }

        lock.lock()
        defer { lock.unlock() }

        if let last = lastPublishByKey[key], now.timeIntervalSince(last) < minimumInterval {
            return false
        }

        lastPublishByKey[key] = now
        return true
    }
}

@MainActor
public final class FileTransferService: ObservableObject {

    public struct TransferSnapshot: Equatable, Sendable {
        public var isTransferring: Bool = false
        public var progress: Double = 0
        public var fileName: String = ""
    }
    
    
    public static let shared = FileTransferService()
    
    
    @Published public var activeBatch: TransferBatch?
    @Published public var transferSnapshot = TransferSnapshot()
    
    @Published public var showConflictDialog = false
    
    @Published public var conflictingFiles: [ConflictingFilePair] = []
    
    @Published public var totalFileCount: Int = 0
    
    
    private let bridge: any MTPBridgeProtocol
    private let notificationHandler: ((String, String, Bool) -> Void)?
    private let directoryRefreshHandler: ((TransferDirection) -> Void)?
    @Published public var transferError: String?
    // Own the request through scanning, conflict decisions and in-flight cancellation.
    private(set) var requestInProgress = false
    private var cancelRequested = false
    private var pauseRequested = false
    private var conflictContinuation: CheckedContinuation<(ConflictResolution, Bool), Never>?
    
    private var conflictProcessIndex: Int = 0
    
    private var completedBytesAccumulated: Int64 = 0
    
    private var speedSamples: [(time: Date, bytes: Int64)] = []
    private let maxSpeedSamples = 10
    
    private var verifiedDirectories = Set<String>()
    
    
    private init() {
        bridge = MTPBridgeFactory.sharedBridge()
        notificationHandler = nil
        directoryRefreshHandler = nil
    }

    init(bridge: any MTPBridgeProtocol,
         notificationHandler: @escaping (String, String, Bool) -> Void,
         directoryRefreshHandler: @escaping (TransferDirection) -> Void) {
        self.bridge = bridge
        self.notificationHandler = notificationHandler
        self.directoryRefreshHandler = directoryRefreshHandler
    }
    
    
    public func pauseTransfer() {
        guard activeBatch?.state == .transferring else { return }
        pauseRequested = true
        activeBatch?.pause()
    }
    
    public func resumeTransfer() {
        guard activeBatch?.state == .paused else { return }
        pauseRequested = false
        activeBatch?.resume()
    }
    
    public func cancelTransfer() {
        cancelRequested = true
        activeBatch?.cancel()
        
        if let continuation = conflictContinuation {
            conflictContinuation = nil
            continuation.resume(returning: (.cancel, true))
            showConflictDialog = false
        }
        
    }
    
    public func resolveConflicts(with resolution: ConflictResolution, rememberForBatch: Bool = true) {
        guard let continuation = conflictContinuation else { return }
        conflictContinuation = nil
        continuation.resume(returning: (resolution, rememberForBatch))
        showConflictDialog = false
    }
    
    
    public func initiateTransfer(
        sources: [FileNode],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32? = nil,
        isCut: Bool = false,
        conflictResolution: ConflictResolution? = nil
    ) {
        guard !requestInProgress, activeBatch?.state.isTerminal != false else {
            reportTransferError(MTPBridgeError.operationInProgress)
            return
        }
        requestInProgress = true
        cancelRequested = false
        pauseRequested = false
        transferError = nil
        activeBatch = nil
        publishTransferSnapshot()
        let cutSources = isCut ? sources.map(\.path) : []
        Task {
            defer { requestInProgress = false }
            do {
                try await performTransfer(
                    sources: sources,
                    destinationDir: destinationDir,
                    direction: direction,
                    storageId: storageId,
                    initialConflictResolution: conflictResolution,
                    cutSourcePaths: cutSources
                )
            } catch {
                ErrorLogger.log(error, message: "File transfer failed")
                activeBatch?.cancel()
                publishTransferSnapshot()
                reportTransferError(error)
            }
        }
    }
    
    
    private func reportTransferError(_ error: Error) {
        transferError = error.localizedDescription
        postTransferNotification(title: "Transfer Failed", body: error.localizedDescription, isError: true)
    }

    public func postTransferNotification(title: String, body: String, isError: Bool = false) {
        if let notificationHandler {
            notificationHandler(title, body, isError)
            return
        }
        Task { @MainActor in
            do {
                let center = UNUserNotificationCenter.current()
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = isError ? .default : nil
                let request = UNNotificationRequest(
                    identifier: "transfer-\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
            } catch {
                ErrorLogger.log(error, message: "Failed to post notification")
            }
        }
    }
    
    
    private func performTransfer(
        sources: [FileNode],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32?,
        initialConflictResolution: ConflictResolution?,
        cutSourcePaths: [String]
    ) async throws {
        if let batch = activeBatch, !batch.state.isTerminal {
            throw MTPBridgeError.operationInProgress
        }

        completedBytesAccumulated = 0
        speedSamples.removeAll()
        verifiedDirectories.removeAll()
        showConflictDialog = false
        conflictingFiles = []
        totalFileCount = 0
        if let oldContinuation = conflictContinuation {
            conflictContinuation = nil
            oldContinuation.resume(returning: (.cancel, true))
        }
        
        if (direction == .localToMTP || direction == .mtpToLocal) && storageId == nil {
            throw NSError(domain: "FileTransferService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage ID is required for MTP transfers"])
        }
        
        let mStorageId = storageId ?? 0
        
        let expandedItems = try await expandSources(sources: sources, direction: direction, storageId: mStorageId)

        guard !cancelRequested, !expandedItems.isEmpty else {
            return
        }
        
        self.totalFileCount = expandedItems.filter { !$0.isDirectory }.count
        
        let fileItems = expandedItems.filter { !$0.isDirectory }
        let conflicts = try await scanForConflicts(
            items: fileItems,
            destinationDir: destinationDir,
            direction: direction,
            storageId: mStorageId
        )
        
        guard !cancelRequested else { return }
        var chosenResolution: ConflictResolution = initialConflictResolution ?? .askEach
        var rememberForBatch = true
        var resolvedConflicts: [String: ConflictResolution] = [:]
        
        if !conflicts.isEmpty {
            if let initialConflictResolution {
                if initialConflictResolution == .cancel {
                    activeBatch = nil
                    return
                }
                for conflict in conflicts {
                    resolvedConflicts[conflict.sourcePath] = initialConflictResolution
                }
            } else {
                conflictProcessIndex = 0
                while conflictProcessIndex < conflicts.count {
                    self.conflictingFiles = Array(conflicts[conflictProcessIndex...])
                    self.showConflictDialog = true

                    (chosenResolution, rememberForBatch) = await withCheckedContinuation { continuation in
                        self.conflictContinuation = continuation
                    }

                    if chosenResolution == .cancel {
                        self.activeBatch = nil
                        return
                    }

                    if rememberForBatch {
                        for i in conflictProcessIndex..<conflicts.count {
                            resolvedConflicts[conflicts[i].sourcePath] = chosenResolution
                        }
                        await MainActor.run {
                            self.showConflictDialog = false
                        }
                        break
                    } else {
                        resolvedConflicts[conflicts[conflictProcessIndex].sourcePath] = chosenResolution
                        conflictProcessIndex += 1
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
            }
        }
        
        var transferQueue: [TransferItem] = []
        for item in expandedItems {
            let relativePath = item.relativePath
            let destPath = (destinationDir as NSString).appendingPathComponent(relativePath)
            
            let sourceFull = item.absolutePath
            let fileName = (relativePath as NSString).lastPathComponent
            
            var status: TransferStatus = .queued
            
            if let fileResolution = resolvedConflicts[sourceFull] {
                switch fileResolution {
                case .skip:
                    status = .skipped
                case .skipIfSameSize:
                    if let conflict = conflicts.first(where: { $0.sourcePath == sourceFull }),
                       conflict.sourceSize == conflict.destinationSize {
                        status = .skipped
                    }
                case .overwriteIfDifferent:
                    if let conflict = conflicts.first(where: { $0.sourcePath == sourceFull }),
                       conflict.sourceSize == conflict.destinationSize {
                        status = .skipped
                    }
                case .overwrite:
                    status = .queued
                default:
                    status = .queued
                }
            }
            
            let transItem = TransferItem(
                sourcePath: sourceFull,
                destinationPath: destPath,
                fileName: fileName,
                fileSize: item.size,
                direction: direction,
                status: status,
                isDirectory: item.isDirectory
            )
            transferQueue.append(transItem)
        }
        
        guard !cancelRequested else { return }
        let batch = TransferBatch()
        batch.items = transferQueue
        self.activeBatch = batch
        publishTransferSnapshot()
        
        batch.start()
        publishTransferSnapshot()
        
        await runQueue(
            storageId: mStorageId,
            direction: direction,
            cutSourcePaths: cutSourcePaths
        )
    }
    
    
    private func runQueue(
        storageId: UInt32,
        direction: TransferDirection,
        cutSourcePaths: [String]
    ) async {
        guard let batch = activeBatch else { return }
        
        // Directories are real queue entries, including empty directories. A failed
        // directory must remain failed so a cut never deletes its source tree.
        for index in batch.items.indices where batch.items[index].isDirectory {
            while pauseRequested && !cancelRequested {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !cancelRequested else { break }
            batch.currentItemIndex = index
            do {
                try await ensureDirectoryExists(path: batch.items[index].destinationPath,
                                                direction: direction, storageId: storageId)
                batch.items[index].markCompleted()
            } catch {
                batch.items[index].markFailed(error.localizedDescription)
            }
            publishTransferSnapshot()
        }

        var groups: [String: [Int]] = [:] // destParent -> array of indices
        for index in batch.items.indices {
            if batch.items[index].isDirectory || batch.items[index].status == .skipped { continue }
            let destParent = (batch.items[index].destinationPath as NSString).deletingLastPathComponent
            groups[destParent, default: []].append(index)
        }
        
        let chunkSize = Self.uploadChunkSize(for: MTPBridgeFactory.selectedEngine())
        
        for (destParent, indices) in groups {
            if cancelRequested { break }
            
            do {
                try await ensureDirectoryExists(path: destParent, direction: direction, storageId: storageId)
            } catch {
                ErrorLogger.log(error, message: "FileTransferService: Failed to create parent directory \(destParent)")
                for idx in indices {
                    var itm = batch.items[idx]
                    itm.markFailed(error.localizedDescription)
                    batch.items[idx] = itm
                }
                continue // Skip this group
            }
            
            for chunkStart in stride(from: 0, to: indices.count, by: chunkSize) {
                if cancelRequested { break }
                
                while pauseRequested && !cancelRequested {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                
                if cancelRequested { break }
                
                let chunkIndices = Array(indices[chunkStart..<min(chunkStart + chunkSize, indices.count)])
                let sources = chunkIndices.map { batch.items[$0].sourcePath }
                let progressBatchID = ObjectIdentifier(batch)
                let progressThrottle = TransferProgressThrottle(
                    minimumInterval: MTPBridgeFactory.selectedEngine() == .libmtp ? 0.15 : 0.05
                )
                
                for idx in chunkIndices {
                    var itm = batch.items[idx]
                    itm.status = .preprocessing
                    batch.items[idx] = itm
                }
                
                do {
                    switch direction {
                    case .localToMTP:
                        try await bridge.uploadFiles(
                            storageId: storageId,
                            sources: sources,
                            destination: destParent,
                            onPreprocess: { _ in },
                            onProgress: { [weak self] progressInfo in
                                guard let self = self else { return }
                                let sent = progressInfo.activeFileSize.sent
                                let total = progressInfo.activeFileSize.total
                                guard progressThrottle.shouldPublish(key: progressInfo.fullPath, sent: sent, total: total) else {
                                    return
                                }
                                let speedMB = progressInfo.speed
                                let name = progressInfo.name
                                Task { @MainActor in
                                    self.updateActiveItemProgress(
                                        expectedBatchID: progressBatchID,
                                        sourcePath: progressInfo.fullPath,
                                        fileName: name,
                                        sent: sent,
                                        speedMB: speedMB
                                    )
                                }
                            }
                        )
                    case .mtpToLocal:
                        try await bridge.downloadFiles(
                            storageId: storageId,
                            sources: sources,
                            destination: destParent,
                            onPreprocess: { _ in },
                            onProgress: { [weak self] progressInfo in
                                guard let self = self else { return }
                                let sent = progressInfo.activeFileSize.sent
                                let total = progressInfo.activeFileSize.total
                                guard progressThrottle.shouldPublish(key: progressInfo.fullPath, sent: sent, total: total) else {
                                    return
                                }
                                let speedMB = progressInfo.speed
                                let name = progressInfo.name
                                Task { @MainActor in
                                    self.updateActiveItemProgress(
                                        expectedBatchID: progressBatchID,
                                        sourcePath: progressInfo.fullPath,
                                        fileName: name,
                                        sent: sent,
                                        speedMB: speedMB
                                    )
                                }
                            }
                        )
                    }
                    
                    if direction == .localToMTP {
                        try await MTPUploadVerification.verify(
                            items: chunkIndices.map { batch.items[$0] }, storageId: storageId, bridge: bridge)
                    }

                    for idx in chunkIndices {
                        var itm = batch.items[idx]
                        if itm.status != .completed {
                            itm.markCompleted()
                            batch.items[idx] = itm
                            completedBytesAccumulated += itm.fileSize
                            publishTransferSnapshot()
                        }
                    }
                    
                } catch {
                    ErrorLogger.log(error, message: "FileTransferService: File copy failed for chunk in \(destParent)")
                    for idx in chunkIndices {
                        var itm = batch.items[idx]
                        if itm.status != .completed {
                            itm.markFailed(error.localizedDescription)
                            batch.items[idx] = itm
                        }
                    }
                }
            }
        }
        
        if cancelRequested {
            batch.cancel()
            publishTransferSnapshot()
            let completed = completedBytesAccumulated > 0 ? " (\(FormatUtils.formatBytes(completedBytesAccumulated)) transferred)" : ""
            postTransferNotification(
                title: "Transfer Cancelled",
                body: "\(batch.completedFileCount) of \(batch.totalFileCount) files copied\(completed)",
                isError: false
            )
        } else {
            let failedCount = batch.failedFileCount
            if failedCount > 0 {
                transferError = batch.items.filter { $0.status == .failed }.prefix(5)
                    .map { "\($0.fileName): \($0.error ?? "Transfer failed")" }.joined(separator: "\n")
            }
            batch.complete()
            publishTransferSnapshot()
            
            var sourceCleanupFailed = false
            let deletableSources = Self.completedCutSources(selectedPaths: cutSourcePaths, items: batch.items)
            for path in deletableSources {
                guard !cancelRequested else { break }
                do {
                    if direction == .mtpToLocal {
                        try await bridge.deleteFiles(storageId: storageId, paths: [path])
                    } else {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    }
                } catch {
                    ErrorLogger.log(error, message: "Failed to remove cut source \(path)")
                    sourceCleanupFailed = true
                    reportTransferError(error)
                }
            }

            if sourceCleanupFailed {
                postTransferNotification(title: "Transfer Completed with Errors",
                                         body: "Files copied, but some sources could not be removed.", isError: true)
            } else if failedCount > 0 {
                postTransferNotification(
                    title: "Transfer Completed with Errors",
                    body: "\(batch.completedFileCount) files copied, \(failedCount) failed",
                    isError: true
                )
            } else {
                let totalBytes = FormatUtils.formatBytes(batch.totalBytesTransferred)
                postTransferNotification(
                    title: "Transfer Complete",
                    body: "\(batch.completedFileCount) items (\(totalBytes)) copied, \(batch.items.filter { $0.status == .skipped }.count) skipped",
                    isError: false
                )
            }
            if let directoryRefreshHandler {
                directoryRefreshHandler(direction)
            } else {
                switch direction {
                case .localToMTP:
                    Task { await MTPDeviceManager.shared.refreshFiles() }
                case .mtpToLocal:
                    NotificationCenter.default.post(name: .localDirectoryNeedsRefresh, object: nil)
                }
            }
        }
        
        let completedBatch = batch
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.activeBatch === completedBatch {
                self.activeBatch = nil
                self.publishTransferSnapshot()
            }
        }
    }
    
    
    static func completedCutSources(selectedPaths: [String], items: [TransferItem]) -> [String] {
        let completed = selectedPaths.filter { path in
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let selectedItems = items.filter { $0.sourcePath == path || $0.sourcePath.hasPrefix(prefix) }
            return !selectedItems.isEmpty && selectedItems.allSatisfy { $0.status == .completed }
        }
        // Avoid removing nested selections twice when the parent was also selected.
        return Array(Set(completed)).filter { path in
            !completed.contains { $0 != path && path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }.sorted()
    }

    static func uploadChunkSize(for engine: MTPBridgeEngine) -> Int {
        1
    }

    private func updateActiveItemProgress(
        expectedBatchID: ObjectIdentifier,
        sourcePath: String,
        fileName: String,
        sent: Int64,
        speedMB: Double
    ) {
        guard let batch = activeBatch,
              ObjectIdentifier(batch) == expectedBatchID,
              let index = indexForProgressUpdate(batch: batch, sourcePath: sourcePath, fileName: fileName) else {
            ErrorLogger.debug("FileTransferService.progress unmatched fullPath=\(sourcePath) name=\(fileName)")
            return
        }
        
        var item = batch.items[index]
        guard !item.status.isTerminal else { return }
        batch.currentItemIndex = index
        item.bytesTransferred = min(sent, item.fileSize)
        item.speed = speedMB * 1024 * 1024 // Convert MB/s to Bytes/s
        
        if item.speed > 0 {
            let remainingBytes = Double(item.fileSize - item.bytesTransferred)
            item.estimatedTimeRemaining = remainingBytes / item.speed
        }
        
        // A progress callback only reports bytes received; bridge success determines completion.
        item.markTransferring()
        
        batch.items[index] = item
        
        batch.recordSpeedSample(bytesTransferredNow: batch.totalBytesTransferred)
        publishTransferSnapshot()
    }

    private func indexForProgressUpdate(batch: TransferBatch, sourcePath: String, fileName: String) -> Int? {
        let normalizedSourcePath = normalizedTransferPath(sourcePath)
        let normalizedFileName = fileName.isEmpty ? (sourcePath as NSString).lastPathComponent : fileName

        if let index = batch.items.firstIndex(where: {
            normalizedTransferPath($0.sourcePath) == normalizedSourcePath ||
            normalizedTransferPath($0.destinationPath) == normalizedSourcePath
        }) {
            return index
        }

        if let index = batch.items.firstIndex(where: {
            ($0.status == .transferring || $0.status == .preprocessing || $0.status == .queued) &&
            ($0.fileName == normalizedFileName ||
             ($0.sourcePath as NSString).lastPathComponent == normalizedFileName ||
             ($0.destinationPath as NSString).lastPathComponent == normalizedFileName)
        }) {
            return index
        }

        if batch.currentItemIndex >= 0 && batch.currentItemIndex < batch.items.count {
            return batch.currentItemIndex
        }

        return batch.items.indices.first
    }

    private func normalizedTransferPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private func publishTransferSnapshot() {
        guard let batch = activeBatch else {
            transferSnapshot = TransferSnapshot()
            return
        }

        transferSnapshot = TransferSnapshot(
            isTransferring: batch.isActive,
            progress: max(0, min(batch.overallProgress, 1)),
            fileName: batch.currentItem?.fileName ?? ""
        )
    }
    
    
    private struct ScannedItem {
        let absolutePath: String
        let relativePath: String // Relative to the drag selection parent
        let isDirectory: Bool
        let size: Int64
        let modificationDate: Date
    }
    
    
    private func getRelativePath(path: String, baseParent: String) -> String {
        let prefix = baseParent.hasSuffix("/") ? baseParent : baseParent + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        } else if path == baseParent {
            return (path as NSString).lastPathComponent
        } else {
            return path
        }
    }
    
    private func expandSources(sources: [FileNode], direction: TransferDirection, storageId: UInt32) async throws -> [ScannedItem] {
        var expanded: [ScannedItem] = []
        
        for source in sources {
            let parentDir = source.parentPath.isEmpty
                ? (source.path as NSString).deletingLastPathComponent
                : source.parentPath
            
            if direction == .localToMTP {
                try expandLocalPath(
                    path: source.path,
                    baseParent: parentDir,
                    into: &expanded
                )
            } else {
                try await expandMTPPath(
                    path: source.path,
                    baseParent: parentDir,
                    storageId: storageId,
                    into: &expanded
                )
            }
        }
        
        return expanded
    }
    
    private func expandLocalPath(path: String, baseParent: String, depth: Int = 0, into list: inout [ScannedItem]) throws {
        guard depth < 100 else {
            throw MTPBridgeError.operationFailed("Directory structure is too deep")
        }
        
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        
        let relativePath = getRelativePath(path: path, baseParent: baseParent)
        
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? Int64) ?? 0
        let date = (attributes[.modificationDate] as? Date) ?? Date()
        
        if isDir.boolValue {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: true, size: 0, modificationDate: date))
            
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            for child in contents {
                let childPath = (path as NSString).appendingPathComponent(child)
                try expandLocalPath(path: childPath, baseParent: baseParent, depth: depth + 1, into: &list)
            }
        } else {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: false, size: size, modificationDate: date))
        }
    }
    
    private func expandMTPPath(path: String, baseParent: String, storageId: UInt32, into list: inout [ScannedItem]) async throws {
        let relativePath = getRelativePath(path: path, baseParent: baseParent)
        let parentDir = (path as NSString).deletingLastPathComponent
        
        let parentContents: [GoFileInfo]
        do {
            parentContents = try await bridge.walk(storageId: storageId, path: parentDir, recursive: false, skipHidden: false)
        } catch {
            ErrorLogger.log(error, message: "bridge.walk(parentDir) failed")
            throw error
        }
        
        guard let selfNode = parentContents.first(where: { $0.path == path }) else {
            throw MTPBridgeError.operationFailed("Source does not exist: \(path)")
        }
        
        let date = parseGoDate(selfNode.dateAdded)
        
        if selfNode.isFolder {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: true, size: 0, modificationDate: date))
            do {
                let children = try await bridge.walk(storageId: storageId, path: path, recursive: true, skipHidden: false)
                for child in children {
                    let childRel = getRelativePath(path: child.path, baseParent: baseParent)
                    let childDate = parseGoDate(child.dateAdded)
                    list.append(ScannedItem(absolutePath: child.path, relativePath: childRel, isDirectory: child.isFolder, size: child.size, modificationDate: childDate))
                }
            } catch {
                ErrorLogger.log(error, message: "recursive walk failed")
                throw error
            }
        } else {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: false, size: selfNode.size, modificationDate: date))
        }
    }
    
    
    private func scanForConflicts(
        items: [ScannedItem],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32
    ) async throws -> [ConflictingFilePair] {
        var conflicts: [ConflictingFilePair] = []
        
        let destinationPaths = items.map { item -> String in
            (destinationDir as NSString).appendingPathComponent(item.relativePath)
        }
        
        if direction == .localToMTP {
            let existences = try await bridge.checkFilesExist(storageId: storageId, paths: destinationPaths)
            
            var parentDirsToWalk = Set<String>()
            for (index, exists) in existences.enumerated() where exists {
                let destPath = destinationPaths[index]
                let destParent = (destPath as NSString).deletingLastPathComponent
                parentDirsToWalk.insert(destParent)
            }
            
            var mtpFilesMetadata = [String: GoFileInfo]()
            for parent in parentDirsToWalk {
                if let contents = try? await bridge.walk(storageId: storageId, path: parent, recursive: false, skipHidden: false) {
                    for node in contents {
                        mtpFilesMetadata[node.path] = node
                    }
                }
            }
            
            for (index, exists) in existences.enumerated() where exists {
                let srcItem = items[index]
                let destPath = destinationPaths[index]
                
                let destSize = mtpFilesMetadata[destPath]?.size ?? 0
                let destDateStr = mtpFilesMetadata[destPath]?.dateAdded ?? ""
                let destDate = parseGoDate(destDateStr)
                
                conflicts.append(
                    ConflictingFilePair(
                        fileName: (destPath as NSString).lastPathComponent,
                        sourcePath: srcItem.absolutePath,
                        sourceSize: srcItem.size,
                        sourceDate: srcItem.modificationDate,
                        destinationPath: destPath,
                        destinationSize: destSize,
                        destinationDate: destDate
                    )
                )
            }
        } else {
            let fileManager = FileManager.default
            for (index, destPath) in destinationPaths.enumerated() {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: destPath, isDirectory: &isDir) {
                    let srcItem = items[index]
                    
                    let attributes = (try? fileManager.attributesOfItem(atPath: destPath)) ?? [:]
                    let destSize = (attributes[.size] as? Int64) ?? 0
                    let destDate = (attributes[.modificationDate] as? Date) ?? Date()
                    
                    conflicts.append(
                        ConflictingFilePair(
                            fileName: (destPath as NSString).lastPathComponent,
                            sourcePath: srcItem.absolutePath,
                            sourceSize: srcItem.size,
                            sourceDate: srcItem.modificationDate,
                            destinationPath: destPath,
                            destinationSize: destSize,
                            destinationDate: destDate
                        )
                    )
                }
            }
        }
        
        return conflicts
    }
    
    
    private func ensureDirectoryExists(path: String, direction: TransferDirection, storageId: UInt32) async throws {
        if path == "/" || path.isEmpty || verifiedDirectories.contains(path) { return }
        
        if direction == .localToMTP {
            let existResult = try await bridge.checkFilesExist(storageId: storageId, paths: [path])
            if existResult.first == true {
                let parent = (path as NSString).deletingLastPathComponent
                let entries = try await bridge.walk(storageId: storageId, path: parent, recursive: false, skipHidden: false)
                guard entries.contains(where: { $0.path == path && $0.isFolder }) else {
                    throw MTPBridgeError.operationFailed("Destination is not a directory: \(path)")
                }
                verifiedDirectories.insert(path)
                return
            }
            
            let parent = (path as NSString).deletingLastPathComponent
            if parent != "/" && !parent.isEmpty {
                try await ensureDirectoryExists(path: parent, direction: direction, storageId: storageId)
            }
            
            try await bridge.makeDirectory(storageId: storageId, path: path)
            verifiedDirectories.insert(path)
        } else {
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: path])
                }
            } else {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            verifiedDirectories.insert(path)
        }
    }
    
    
    private func parseGoDate(_ dateStr: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: dateStr) ?? Date()
    }
}
