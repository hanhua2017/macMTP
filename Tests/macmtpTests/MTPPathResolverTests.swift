import XCTest
@testable import macmtp

final class MTPPathResolverTests: XCTestCase {
    func testNormalizeRootAndRepeatedSlashes() {
        XCTAssertEqual(MTPPathResolver.normalize(""), "/")
        XCTAssertEqual(MTPPathResolver.normalize("/"), "/")
        XCTAssertEqual(MTPPathResolver.normalize("//Music///Rock/"), "/Music/Rock")
    }

    func testParentPath() {
        XCTAssertEqual(MTPPathResolver.parentPath(of: "/Music/Rock/song.mp3"), "/Music/Rock")
        XCTAssertEqual(MTPPathResolver.parentPath(of: "/Music"), "/")
        XCTAssertEqual(MTPPathResolver.parentPath(of: "/"), "/")
    }

    func testFileName() {
        XCTAssertEqual(MTPPathResolver.fileName(of: "/Music/Rock/song.mp3"), "song.mp3")
        XCTAssertEqual(MTPPathResolver.fileName(of: "/Music"), "Music")
        XCTAssertEqual(MTPPathResolver.fileName(of: "/"), "")
    }

    func testJoin() {
        XCTAssertEqual(MTPPathResolver.join(parent: "/", name: "Music"), "/Music")
        XCTAssertEqual(MTPPathResolver.join(parent: "/Music", name: "Rock"), "/Music/Rock")
        XCTAssertEqual(MTPPathResolver.join(parent: "/Music/", name: "/Rock/"), "/Music/Rock")
    }
}
