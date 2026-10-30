import XCTest
@testable import macmtp

final class LibMTPBridgeDecodeTests: XCTestCase {
    func testDecodeDeviceInfoJSON() throws {
        let json = #"{"error":null,"data":{"mtpDeviceInfo":{"Manufacturer":"iFlytek","Model":"iFlytek AiNote Air2","DeviceVersion":"1.0","SerialNumber":"123","StandardVersion":null,"MTPVendorExtensionID":null,"MTPVersion":null,"MTPExtension":null,"FunctionalMode":null},"usbDeviceInfo":null}}"#
        let data: GoDeviceInfoResult = try LibMTPBridge.decode(json)

        XCTAssertEqual(data.data?.mtpDeviceInfo?.Model, "iFlytek AiNote Air2")
    }
}
