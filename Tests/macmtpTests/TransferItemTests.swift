import XCTest
@testable import macmtp

final class TransferItemTests: XCTestCase {
    func testMarkTransferringDoesNotReplaceTerminalStatus() {
        for terminalStatus in [TransferStatus.completed, .failed, .skipped] {
            var item = TransferItem(
                sourcePath: "/source/file.txt",
                destinationPath: "/destination/file.txt",
                fileSize: 12,
                direction: .localToMTP,
                status: terminalStatus
            )

            item.markTransferring()

            XCTAssertEqual(item.status, terminalStatus)
        }
    }
}
