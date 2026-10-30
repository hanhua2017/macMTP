import Foundation

public protocol MTPBridgeProtocol: Sendable {
    func initialize() async throws -> GoDeviceInfoData
    func fetchCapabilities() async throws -> MTPDeviceCapabilities
    func fetchStorages() async throws -> [GoStorageData]
    func listDirectory(storageId: UInt32, path: String, recursive: Bool) async throws -> [GoFileInfo]
    func makeDirectory(storageId: UInt32, path: String) async throws
    func deleteFiles(storageId: UInt32, paths: [String]) async throws
    func renameFile(storageId: UInt32, path: String, newName: String) async throws
    func moveFile(storageId: UInt32, sourcePath: String, destinationParentPath: String) async throws
    func copyFile(storageId: UInt32, sourcePath: String, destinationParentPath: String) async throws
    func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool]
    func uploadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws
    func downloadFiles(
        storageId: UInt32,
        sources: [String],
        destination: String,
        onPreprocess: @escaping @Sendable (GoTransferPreprocessData) -> Void,
        onProgress: @escaping @Sendable (GoTransferProgressInfo) -> Void
    ) async throws
    func walk(storageId: UInt32, path: String, recursive: Bool, skipHidden: Bool) async throws -> [GoFileInfo]
    func dispose() async throws
}
