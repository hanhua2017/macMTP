import XCTest
@testable import macmtp

final class FileTransferServiceTests: XCTestCase {
    @MainActor
    func testUploadChunkSizeUsesSingleFileForLibMTP() {
        XCTAssertEqual(FileTransferService.uploadChunkSize(for: .libmtp), 1)
    }
}
