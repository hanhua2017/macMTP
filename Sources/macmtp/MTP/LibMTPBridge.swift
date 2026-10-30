import Foundation
import CLibMTPBridge
import Darwin

public enum LibMTPTransferProgressMapper {
    public static func makeProgress(
        fullPath: String,
        name: String,
        sent: UInt64,
        total: UInt64,
        expectedSize: UInt64,
        startedAt: Date,
        now: Date = Date(),
        totalFiles: Int64,
        filesSent: Int64
    ) -> GoTransferProgressInfo {
        let clampedSent = min(sent, expectedSize)
        let elapsed = max(now.timeIntervalSince(startedAt), 0.001)
        let speedMB = Double(clampedSent) / elapsed / 1024.0 / 1024.0
        let progress = expectedSize == 0 ? Float(0) : Float(Double(clampedSent) / Double(expectedSize))
        let size = GoTransferSizeInfo(
            total: Int64(clamping: expectedSize),
            sent: Int64(clamping: clampedSent),
            progress: progress
        )
        return GoTransferProgressInfo(
            fullPath: fullPath,
            name: name,
            elapsedTime: Int64(elapsed),
            speed: speedMB,
            totalFiles: totalFiles,
            totalDirectories: 0,
            filesSent: filesSent,
            filesSentProgress: totalFiles == 0 ? 0 : Float(Double(filesSent) / Double(totalFiles)),
            activeFileSize: size,
            bulkFileSize: size,
            status: "transferring"
        )
    }
}

private final class LibMTPBridgeHandle: @unchecked Sendable {
    let raw: OpaquePointer?

    init(raw: OpaquePointer?) {
        self.raw = raw
    }

    deinit {
        if let raw {
            mtp_bridge_destroy(raw)
        }
    }
}

private final class LibMTPTransferCallbackContext: @unchecked Sendable {
    let startedAt: Date
    let totalFiles: Int64
    let filesSent: Int64
    let expectedSize: UInt64
    let onProgress: @Sendable (GoTransferProgressInfo) -> Void

    init(
        startedAt: Date,
        totalFiles: Int64,
        filesSent: Int64,
        expectedSize: UInt64,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) {
        self.startedAt = startedAt
        self.totalFiles = totalFiles
        self.filesSent = filesSent
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    func report(
        fullPath: UnsafePointer<CChar>?,
        name: UnsafePointer<CChar>?,
        sent: UInt64,
        total: UInt64
    ) {
        guard let fullPath, let name else { return }
        onProgress(
            LibMTPTransferProgressMapper.makeProgress(
                fullPath: String(cString: fullPath),
                name: String(cString: name),
                sent: sent,
                total: total,
                expectedSize: expectedSize,
                startedAt: startedAt,
                totalFiles: totalFiles,
                filesSent: filesSent
            )
        )
    }
}

private func libMTPTransferProgressCallback(
    fullPath: UnsafePointer<CChar>?,
    name: UnsafePointer<CChar>?,
    sent: UInt64,
    total: UInt64,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<LibMTPTransferCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .report(fullPath: fullPath, name: name, sent: sent, total: total)
}

public actor LibMTPBridge: MTPBridgeProtocol {
    public static let shared = LibMTPBridge()

    private let handle: LibMTPBridgeHandle

    private init() {
        self.handle = LibMTPBridgeHandle(raw: mtp_bridge_create())
    }

    internal static func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = JSONDecoder()
        guard let data = json.data(using: .utf8) else {
            throw MTPBridgeError.invalidResponse
        }
        return try decoder.decode(T.self, from: data)
    }

    private func lastError() -> String {
        guard let raw = handle.raw, let ptr = mtp_bridge_last_error(raw) else {
            return "libmtp bridge is not initialized"
        }
        let message = String(cString: ptr)
        return message.isEmpty ? "Unknown libmtp error" : message
    }

    private func takeString(_ ptr: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let ptr else {
            throw MTPBridgeError.operationFailed(lastError())
        }
        let value = String(cString: ptr)
        mtp_bridge_free_string(ptr)
        return value
    }

    public func initialize() async throws -> GoDeviceInfoData {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        if mtp_bridge_connect(raw) != 0 {
            throw MTPBridgeError.operationFailed(lastError())
        }
        let json = try takeString(mtp_bridge_device_info_json(raw))
        let result: GoDeviceInfoResult = try Self.decode(json)
        guard let data = result.data else {
            throw MTPBridgeError.operationFailed(result.error ?? "Failed to initialize libmtp device")
        }
        return data
    }

    public func fetchCapabilities() async throws -> MTPDeviceCapabilities {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        let json = try takeString(mtp_bridge_capabilities_json(raw))
        let result: MTPDeviceCapabilitiesResult = try Self.decode(json)
        guard let data = result.data else {
            throw MTPBridgeError.operationFailed(result.error ?? "Failed to fetch libmtp capabilities")
        }
        return data
    }

    public func fetchStorages() async throws -> [GoStorageData] {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        let json = try takeString(mtp_bridge_storages_json(raw))
        let result: GoStoragesResult = try Self.decode(json)
        guard let data = result.data else {
            throw MTPBridgeError.operationFailed(result.error ?? "Failed to fetch libmtp storages")
        }
        return data
    }

    public func listDirectory(storageId: UInt32, path: String, recursive: Bool = false) async throws -> [GoFileInfo] {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        let normalized = MTPPathResolver.normalize(path)
        let json = try normalized.withCString { cPath in
            try takeString(mtp_bridge_list_directory_json(raw, storageId, cPath, recursive ? 1 : 0))
        }
        let result: GoWalkResult = try Self.decode(json)
        guard let data = result.data else {
            throw MTPBridgeError.operationFailed(result.error ?? "Failed to list libmtp directory")
        }
        return data
    }

    public func makeDirectory(storageId: UInt32, path: String) async throws {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        let normalized = MTPPathResolver.normalize(path)
        let result = normalized.withCString { mtp_bridge_create_folder(raw, storageId, $0) }
        if result != 0 {
            throw MTPBridgeError.operationFailed(lastError())
        }
    }

    public func deleteFiles(storageId: UInt32, paths: [String]) async throws {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        for path in paths {
            let normalized = MTPPathResolver.normalize(path)
            let result = normalized.withCString { mtp_bridge_delete_path(raw, storageId, $0) }
            if result != 0 {
                throw MTPBridgeError.operationFailed(lastError())
            }
        }
    }

    public func renameFile(storageId: UInt32, path: String, newName: String) async throws {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        let normalized = MTPPathResolver.normalize(path)
        let result = normalized.withCString { cPath in
            newName.withCString { cName in
                mtp_bridge_rename_path(raw, storageId, cPath, cName)
            }
        }
        if result != 0 {
            throw MTPBridgeError.operationFailed(lastError())
        }
    }

    public func moveFile(storageId: UInt32, sourcePath: String, destinationParentPath: String) async throws {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        let normalizedSource = MTPPathResolver.normalize(sourcePath)
        let normalizedDestination = MTPPathResolver.normalize(destinationParentPath)
        let result = normalizedSource.withCString { cSource in
            normalizedDestination.withCString { cDestination in
                mtp_bridge_move_path(raw, storageId, cSource, cDestination)
            }
        }
        if result != 0 {
            throw MTPBridgeError.operationFailed(lastError())
        }
    }

    public func copyFile(storageId: UInt32, sourcePath: String, destinationParentPath: String) async throws {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }
        let normalizedSource = MTPPathResolver.normalize(sourcePath)
        let normalizedDestination = MTPPathResolver.normalize(destinationParentPath)

        var objectId: UInt32 = 0
        var isFolder: Int32 = 0
        let resolveResult = normalizedSource.withCString {
            mtp_bridge_resolve_object_id(raw, storageId, $0, &objectId, &isFolder)
        }
        if resolveResult != 0 {
            throw MTPBridgeError.operationFailed(lastError())
        }

        var parentId: UInt32 = 0
        var destinationIsFolder: Int32 = 0
        let parentResult = normalizedDestination.withCString {
            mtp_bridge_resolve_object_id(raw, storageId, $0, &parentId, &destinationIsFolder)
        }
        if parentResult != 0 {
            throw MTPBridgeError.operationFailed(lastError())
        }
        guard destinationIsFolder != 0 else {
            throw MTPBridgeError.operationFailed("MTP copy destination is not a folder")
        }

        let copyParentId = normalizedDestination == "/" ? UInt32(0) : parentId
        if mtp_bridge_copy_object(raw, objectId, storageId, copyParentId) != 0 {
            throw MTPBridgeError.operationFailed(lastError())
        }
    }

    public func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool] {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }

        let normalizedPaths = paths.map(MTPPathResolver.normalize)
        var cPaths = [UnsafePointer<CChar>?]()
        cPaths.reserveCapacity(normalizedPaths.count)
        for path in normalizedPaths {
            guard let duplicated = strdup(path) else {
                cPaths.forEach { pointer in
                    if let pointer {
                        free(UnsafeMutableRawPointer(mutating: pointer))
                    }
                }
                throw MTPBridgeError.operationFailed("Failed to allocate MTP path list")
            }
            cPaths.append(UnsafePointer(duplicated))
        }
        defer {
            cPaths.forEach { pointer in
                if let pointer {
                    free(UnsafeMutableRawPointer(mutating: pointer))
                }
            }
        }

        let json = try cPaths.withUnsafeMutableBufferPointer { buffer in
            try takeString(mtp_bridge_file_exists_json(raw, storageId, buffer.baseAddress, Int32(buffer.count)))
        }
        let result: GoFileExistsResult = try Self.decode(json)
        guard let data = result.data else {
            throw MTPBridgeError.operationFailed(result.error ?? "Failed to check libmtp file existence")
        }

        var resultMap = [String: Bool]()
        for entry in data {
            resultMap[entry.fullpath] = entry.exists
        }
        return normalizedPaths.map { resultMap[$0] ?? false }
    }

    public func uploadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }

        let fileManager = FileManager.default
        let files = sources.filter { source in
            var isDirectory: ObjCBool = false
            return !(fileManager.fileExists(atPath: source, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
        let totalFiles = Int64(files.count)
        let normalizedDestination = MTPPathResolver.normalize(destination)
        var filesSent: Int64 = 0

        for source in files {
            let attributes = try fileManager.attributesOfItem(atPath: source)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let name = URL(fileURLWithPath: source).lastPathComponent
            onPreprocess(
                GoTransferPreprocessData(
                    fullPath: source,
                    name: name,
                    size: Int64(clamping: size)
                )
            )

            let progressContext = LibMTPTransferCallbackContext(
                startedAt: Date(),
                totalFiles: totalFiles,
                filesSent: filesSent,
                expectedSize: size,
                onProgress: onProgress
            )
            let result = source.withCString { cSource in
                normalizedDestination.withCString { cDestination in
                    mtp_bridge_upload_file(
                        raw,
                        storageId,
                        cSource,
                        cDestination,
                        libMTPTransferProgressCallback,
                        Unmanaged.passUnretained(progressContext).toOpaque()
                    )
                }
            }
            if result != 0 {
                throw MTPBridgeError.transferFailed(lastError())
            }
            filesSent += 1
        }
    }

    public func downloadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws {
        guard let raw = handle.raw else {
            throw MTPBridgeError.operationFailed("libmtp bridge is not initialized")
        }

        let normalizedSources = sources.map(MTPPathResolver.normalize)
        var files = [(source: String, metadata: GoFileInfo)]()
        for source in normalizedSources {
            let parent = MTPPathResolver.parentPath(of: source)
            let metadata = try await listDirectory(storageId: storageId, path: parent, recursive: false)
                .first { MTPPathResolver.normalize($0.path) == source }
            guard let metadata else {
                throw MTPBridgeError.transferFailed("MTP download source was not found")
            }
            if !metadata.isFolder {
                files.append((source, metadata))
            }
        }

        let fileManager = FileManager.default
        let totalFiles = Int64(files.count)
        var filesSent: Int64 = 0
        for (source, metadata) in files {
            let destinationURL = URL(fileURLWithPath: destination)
                .appendingPathComponent(metadata.name)
            let temporaryURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(metadata.name).macmtp-\(UUID().uuidString).partial")
            defer {
                try? fileManager.removeItem(at: temporaryURL)
            }
            onPreprocess(
                GoTransferPreprocessData(
                    fullPath: source,
                    name: metadata.name,
                    size: metadata.size
                )
            )

            let progressContext = LibMTPTransferCallbackContext(
                startedAt: Date(),
                totalFiles: totalFiles,
                filesSent: filesSent,
                expectedSize: UInt64(max(metadata.size, 0)),
                onProgress: onProgress
            )
            let result = source.withCString { cSource in
                temporaryURL.path.withCString { cDestination in
                    mtp_bridge_download_file(
                        raw,
                        storageId,
                        cSource,
                        cDestination,
                        libMTPTransferProgressCallback,
                        Unmanaged.passUnretained(progressContext).toOpaque()
                    )
                }
            }
            if result != 0 {
                throw MTPBridgeError.transferFailed(lastError())
            }
            if rename(temporaryURL.path, destinationURL.path) != 0 {
                throw MTPBridgeError.transferFailed("Failed to replace downloaded file at \(destinationURL.path)")
            }
            filesSent += 1
        }
    }

    public func walk(storageId: UInt32, path: String, recursive: Bool, skipHidden: Bool) async throws -> [GoFileInfo] {
        try await listDirectory(storageId: storageId, path: path, recursive: recursive)
    }

    public func dispose() async throws {
        guard let raw = handle.raw else { return }
        mtp_bridge_disconnect(raw)
    }
}
