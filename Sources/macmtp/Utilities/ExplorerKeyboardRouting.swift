import AppKit

/// Explorer shortcuts must defer to AppKit's text editor, including field editors.
enum ExplorerKeyboardRouting {
    static func isEditingText(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }
}
