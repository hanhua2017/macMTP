import Foundation
@testable import macmtp

/// A real filesystem on each side, with controllable in-flight bridge calls.
actor TransferFixtureBridge: MTPBridgeProtocol {
    let root: URL
    private var holdUpload = false
    private var nextUploadName: String?
    private var truncateUpload = false
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    private(set) var uploadStarted = false

    init(root: URL) { self.root = root.resolvingSymlinksInPath() }
    func rewriteNextUploadName(_ name: String) { nextUploadName = name }
    func truncateNextUpload() { truncateUpload = true }
    func suspendNextUpload() { holdUpload = true }
    func resumeUpload() { uploadContinuation?.resume(); uploadContinuation = nil }
    func local(_ path: String) -> URL { root.appendingPathComponent(String(path.dropFirst())) }
    func initialize() async throws -> GoDeviceInfoData { GoDeviceInfoData(mtpDeviceInfo: nil, usbDeviceInfo: nil) }
    func fetchCapabilities() async throws -> MTPDeviceCapabilities { .unknown }
    func fetchStorages() async throws -> [GoStorageData] { [] }
    func dispose() async throws {}
    func makeDirectory(storageId: UInt32, path: String) async throws {
        try FileManager.default.createDirectory(at: local(path), withIntermediateDirectories: false)
    }
    func deleteFiles(storageId: UInt32, paths: [String]) async throws {
        for path in paths { try FileManager.default.removeItem(at: local(path)) }
    }
    func renameFile(storageId: UInt32, path: String, newName: String) async throws {
        let source = local(path)
        try FileManager.default.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent(newName))
    }
    func moveFile(storageId: UInt32, sourcePath: String, destinationParentPath: String) async throws {
        try FileManager.default.moveItem(at: local(sourcePath), to: local(destinationParentPath).appendingPathComponent((sourcePath as NSString).lastPathComponent))
    }
    func copyFile(storageId: UInt32, sourcePath: String, destinationParentPath: String) async throws {
        try FileManager.default.copyItem(at: local(sourcePath), to: local(destinationParentPath).appendingPathComponent((sourcePath as NSString).lastPathComponent))
    }
    func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool] {
        paths.map { FileManager.default.fileExists(atPath: local($0).path) }
    }
    func listDirectory(storageId: UInt32, path: String, recursive: Bool) async throws -> [GoFileInfo] {
        try await walk(storageId: storageId, path: path, recursive: recursive, skipHidden: false)
    }
    func walk(storageId: UInt32, path: String, recursive: Bool, skipHidden: Bool) async throws -> [GoFileInfo] {
        let fm = FileManager.default, directory = local(path)
        let relativePaths = try recursive
            ? fm.subpathsOfDirectory(atPath: directory.path)
            : fm.contentsOfDirectory(atPath: directory.path)
        return try relativePaths.filter { !skipHidden || !($0 as NSString).lastPathComponent.hasPrefix(".") }.map { relative in
            let url = directory.appendingPathComponent(relative)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let remote = (path as NSString).appendingPathComponent(relative)
            return GoFileInfo(size: (attrs[.size] as? Int64) ?? 0, isFolder: attrs[.type] as? FileAttributeType == .typeDirectory,
                              dateAdded: "2026-10-29T00:00:00.000Z", name: url.lastPathComponent,
                              path: remote, parentPath: (remote as NSString).deletingLastPathComponent,
                              extension: url.pathExtension, parentId: 0, objectId: 0)
        }
    }
    func uploadFiles(storageId: UInt32, sources: [String], destination: String,
                     onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
                     onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void) async throws {
        uploadStarted = true
        if holdUpload { holdUpload = false; await withCheckedContinuation { uploadContinuation = $0 } }
        for source in sources {
            try copyReplacing(URL(fileURLWithPath: source), to: local(destination))
            let target = local(destination).appendingPathComponent((source as NSString).lastPathComponent)
            if let nextUploadName {
                try FileManager.default.moveItem(at: target, to: local(destination).appendingPathComponent(nextUploadName))
                self.nextUploadName = nil
            } else if truncateUpload {
                try Data().write(to: target)
                truncateUpload = false
            }
        }
    }
    func downloadFiles(storageId: UInt32, sources: [String], destination: String,
                       onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
                       onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void) async throws {
        for source in sources { try copyReplacing(local(source), to: URL(fileURLWithPath: destination)) }
    }
    private func copyReplacing(_ source: URL, to directory: URL) throws {
        let fm = FileManager.default, target = directory.appendingPathComponent(source.lastPathComponent)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
            if isDir.boolValue { throw CocoaError(.fileWriteFileExists) }
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: source, to: target)
    }
}
