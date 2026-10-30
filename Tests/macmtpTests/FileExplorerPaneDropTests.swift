import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import macmtp

final class FileExplorerPaneDropTests: XCTestCase {
    func testParsesInternalMTPDropPayload() {
        let payload = "mtp:file:/Books/example.epub\nmtp:dir:/Books/Nested"

        let files = FileExplorerPane.droppedFiles(fromInternalPayload: payload)

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "/Books/example.epub")
        XCTAssertFalse(files[0].isLocal)
        XCTAssertFalse(files[0].isDirectory)
        XCTAssertEqual(files[0].name, "example.epub")
        XCTAssertEqual(files[1].path, "/Books/Nested")
        XCTAssertFalse(files[1].isLocal)
        XCTAssertTrue(files[1].isDirectory)
        XCTAssertEqual(files[1].name, "Nested")
    }

    func testAcceptedDropTypesIncludeInternalFileItems() {
        XCTAssertTrue(FileExplorerPane.acceptedDropTypes.contains(FileExplorerPane.internalFileItemsType))
    }

    func testStrippedInternalTypesPreserveEntireSelection() {
        let provider = NSItemProvider()
        provider.registerObject(URL(fileURLWithPath: "/tmp/第一本.epub") as NSURL, visibility: .all)
        register("local:file:/tmp/第一本.epub\nlocal:file:/tmp/第二本.pdf\nlocal:dir:/tmp/书籍", type: UTType.utf8PlainText.identifier, on: provider)

        assertDrop(provider, paths: ["/tmp/第一本.epub", "/tmp/第二本.pdf", "/tmp/书籍"], directories: [false, false, true])
    }

    func testInternalPayloadWinsEvenWhenPlainTextIsPresent() {
        let provider = NSItemProvider()
        register("local:file:/tmp/one\nlocal:file:/tmp/two", type: FileExplorerPane.internalFileItemsType, on: provider)
        register("local:file:/tmp/wrong", type: UTType.utf8PlainText.identifier, on: provider)

        assertDrop(provider, paths: ["/tmp/one", "/tmp/two"])
    }

    func testUnrelatedTextFallsBackToFileURL() {
        let provider = NSItemProvider()
        provider.registerObject(URL(fileURLWithPath: "/tmp/one.epub") as NSURL, visibility: .all)
        register("unrelated text", type: UTType.utf8PlainText.identifier, on: provider)

        assertDrop(provider, paths: ["/tmp/one.epub"])
    }

    func testFailedInternalLoadFallsBackToPlainText() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: FileExplorerPane.internalFileItemsType, visibility: .all) { completion in
            completion(nil, NSError(domain: "DropTest", code: 1))
            return nil
        }
        register("mtp:file:/Books/one\nmtp:file:/Books/two", type: UTType.utf8PlainText.identifier, on: provider)

        assertDrop(provider, paths: ["/Books/one", "/Books/two"], isLocal: false)
    }

    func testFinderFilenamesPreserveEntireSelection() throws {
        let provider = NSItemProvider()
        let data = try PropertyListSerialization.data(fromPropertyList: ["/tmp/one", "/tmp/two"], format: .xml, options: 0)
        provider.registerDataRepresentation(forTypeIdentifier: "NSFilenamesPboardType", visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        provider.registerObject(URL(fileURLWithPath: "/tmp/one") as NSURL, visibility: .all)

        assertDrop(provider, paths: ["/tmp/one", "/tmp/two"])
    }

    func testURLOnlyProvidersRemainSupported() {
        for path in ["/tmp/one.epub", "/tmp/two.pdf"] {
            let provider = NSItemProvider()
            provider.registerObject(URL(fileURLWithPath: path) as NSURL, visibility: .all)
            assertDrop(provider, paths: [path])
        }
    }

    func testStructuredPayloadPreservesNewlineColonAndUnicodePaths() {
        let paths = ["/tmp/换行\nname:one.txt", "/tmp/第二个\r\n文件.txt"]
        let payload = FileExplorerPane.internalPayload(for: paths.map {
            DroppedFile(path: $0, isLocal: true, name: ($0 as NSString).lastPathComponent, isDirectory: false)
        })
        XCTAssertEqual(FileExplorerPane.droppedFiles(fromInternalPayload: payload).map(\.path), paths)
        let provider = NSItemProvider()
        provider.registerObject(URL(fileURLWithPath: paths[0]) as NSURL, visibility: .all)
        register(payload, type: UTType.utf8PlainText.identifier, on: provider)
        assertDrop(provider, paths: paths)
    }

    func testMalformedLegacyPayloadDoesNotResolveATruncatedPath() {
        XCTAssertTrue(FileExplorerPane.droppedFiles(fromInternalPayload: "local:file:/tmp/newline\nname.txt").isEmpty)
        XCTAssertTrue(FileExplorerPane.droppedFiles(fromInternalPayload: "local:unknown:/tmp/name").isEmpty)
    }

    private func register(_ text: String, type: String, on provider: NSItemProvider) {
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
    }

    private func assertDrop(
        _ provider: NSItemProvider,
        paths: [String],
        directories: [Bool]? = nil,
        isLocal: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let done = expectation(description: "Resolve dropped files")
        FileExplorerPane.loadDroppedFiles(from: provider) { files in
            XCTAssertEqual(files.map(\.path), paths, file: file, line: line)
            XCTAssertEqual(files.map(\.isLocal), paths.map { _ in isLocal }, file: file, line: line)
            if let directories {
                XCTAssertEqual(files.map(\.isDirectory), directories, file: file, line: line)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

}
