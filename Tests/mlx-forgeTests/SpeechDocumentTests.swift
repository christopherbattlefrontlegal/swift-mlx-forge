import AppKit
import XCTest
@testable import mlx_forge

final class SpeechDocumentTests: XCTestCase {
    func testImportsEntireUnicodeDocument() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "A reader’s voice: café.\n", count: 5000)
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SpeechDocument.read(url), text)
    }

    func testRejectsEmptyDocument() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try " \n\t".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SpeechDocument.read(url))
    }

    func testImportsWordAndRichText() throws {
        let original = NSAttributedString(string: "Narration from a document.\nSecond paragraph.")
        for (ext, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("rtf", .rtf)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try original.data(from: NSRange(location: 0, length: original.length), documentAttributes: [.documentType: type])
            try data.write(to: url)
            XCTAssertEqual(try SpeechDocument.read(url).trimmingCharacters(in: .whitespacesAndNewlines), original.string)
        }
    }
}
