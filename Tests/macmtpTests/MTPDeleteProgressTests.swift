import XCTest
@testable import macmtp

final class MTPDeleteProgressTests: XCTestCase {
    func testDeleteProgressFractionIsClamped() {
        XCTAssertEqual(
            MTPDeviceManager.DeleteProgress(currentPath: "/a.txt", completedCount: 2, totalCount: 4).fractionCompleted,
            0.5
        )
        XCTAssertEqual(
            MTPDeviceManager.DeleteProgress(currentPath: "/a.txt", completedCount: 5, totalCount: 4).fractionCompleted,
            1
        )
        XCTAssertEqual(
            MTPDeviceManager.DeleteProgress(currentPath: "/a.txt", completedCount: 0, totalCount: 0).fractionCompleted,
            0
        )
    }
}
