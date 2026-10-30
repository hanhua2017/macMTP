import XCTest
@testable import macmtp

final class MTPBridgeProtocolTests: XCTestCase {
    func testLibMTPBridgeConformsToProtocol() async {
        let bridge: any MTPBridgeProtocol = LibMTPBridge.shared
        _ = bridge
    }
}
