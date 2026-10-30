import XCTest
@testable import macmtp

final class MTPBridgeFactoryTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mtpEngine")
        super.tearDown()
    }

    func testDefaultEngineIsLibMTP() {
        XCTAssertEqual(MTPBridgeFactory.selectedEngine(), .libmtp)
    }

    func testUnknownEngineFallsBackToLibMTP() {
        UserDefaults.standard.set("missing", forKey: "mtpEngine")
        XCTAssertEqual(MTPBridgeFactory.selectedEngine(), .libmtp)
    }

    @MainActor
    func testUSBWatcherVerificationBridgeFollowsSelectedEngine() {
        UserDefaults.standard.set("libmtp", forKey: "mtpEngine")

        XCTAssertTrue(USBWatcher.bridgeForMTPVerification() is LibMTPBridge)
    }
}
