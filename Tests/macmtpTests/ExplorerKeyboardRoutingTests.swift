import AppKit
import XCTest
@testable import macmtp

@MainActor
final class ExplorerKeyboardRoutingTests: XCTestCase {
    func testTextViewsAndFieldEditorsRetainTheirKeyboardEvents() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        XCTAssertTrue(ExplorerKeyboardRouting.isEditingText(editor))
        XCTAssertTrue(ExplorerKeyboardRouting.isEditingText(NSTextView()))
        XCTAssertTrue(ExplorerKeyboardRouting.isEditingText(NSTextField()))
        XCTAssertTrue(ExplorerKeyboardRouting.isEditingText(NSSearchField()))
        XCTAssertFalse(ExplorerKeyboardRouting.isEditingText(NSView()))
        XCTAssertFalse(ExplorerKeyboardRouting.isEditingText(nil))
    }
}
