import XCTest
@testable import macmtp

final class LibMTPProgressTests: XCTestCase {
    func testProgressMapperBuildsExistingModel() {
        let info = LibMTPTransferProgressMapper.makeProgress(
            fullPath: "/Music/song.mp3",
            name: "song.mp3",
            sent: 50,
            total: 100,
            expectedSize: 100,
            startedAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 2),
            totalFiles: 1,
            filesSent: 0
        )

        XCTAssertEqual(info.fullPath, "/Music/song.mp3")
        XCTAssertEqual(info.name, "song.mp3")
        XCTAssertEqual(info.activeFileSize.sent, 50)
        XCTAssertEqual(info.activeFileSize.total, 100)
        XCTAssertEqual(info.activeFileSize.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(info.status, "transferring")
    }

    func testProgressMapperClampsPTPFramingToFileSize() {
        let info = LibMTPTransferProgressMapper.makeProgress(
            fullPath: "/Music/song.mp3",
            name: "song.mp3",
            sent: 104,
            total: 104,
            expectedSize: 100,
            startedAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 2),
            totalFiles: 1,
            filesSent: 0
        )

        XCTAssertEqual(info.activeFileSize.sent, 100)
        XCTAssertEqual(info.activeFileSize.total, 100)
        XCTAssertEqual(info.activeFileSize.progress, 1, accuracy: 0.001)
    }
}
