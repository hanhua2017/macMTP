import Foundation

/// Some devices silently sanitize names. A bridge success alone must not commit
/// a cut when the expected destination is absent or has the wrong size.
enum MTPUploadVerification {
    static func verify(items: [TransferItem], storageId: UInt32, bridge: any MTPBridgeProtocol) async throws {
        let groups = Dictionary(grouping: items) { ($0.destinationPath as NSString).deletingLastPathComponent }
        for (parent, uploads) in groups {
            let entries = try await bridge.walk(storageId: storageId, path: parent, recursive: false, skipHidden: false)
            for item in uploads {
                guard let entry = entries.first(where: { $0.path == item.destinationPath && !$0.isFolder }) else {
                    throw MTPBridgeError.transferFailed("Device did not preserve the destination filename: \(item.destinationPath). The source has been retained.")
                }
                guard entry.size == item.fileSize else {
                    throw MTPBridgeError.transferFailed("Destination size does not match the source: \(item.destinationPath). The source has been retained.")
                }
            }
        }
    }
}
