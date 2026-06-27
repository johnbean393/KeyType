import AutocompleteCore
import XCTest
@testable import MacContextCapture

final class TextRangeGeometryResolverTests: XCTestCase {
    private let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    @MainActor
    func testUTF16RangeForBeforeCursorDescriptor() {
        let context = TextFieldContext(beforeCursor: "in the mdidle, ", afterCursor: "of it", target: target)
        let descriptor = TextRangeDescriptor(container: .beforeCursor, startOffset: 7, endOffset: 13)

        let range = TextRangeGeometryResolver.utf16Range(for: descriptor, context: context)

        XCTAssertEqual(range, NSRange(location: 7, length: 6))
    }

    @MainActor
    func testUTF16RangeForAfterCursorDescriptorIncludesBeforeCursorOffset() {
        let context = TextFieldContext(beforeCursor: "in the ", afterCursor: "mdidle of it", target: target)
        let descriptor = TextRangeDescriptor(container: .afterCursor, startOffset: 0, endOffset: 6)

        let range = TextRangeGeometryResolver.utf16Range(for: descriptor, context: context)

        XCTAssertEqual(range, NSRange(location: 7, length: 6))
    }

    @MainActor
    func testUTF16RangeAccountsForEmojiBeforeWord() {
        let context = TextFieldContext(beforeCursor: "🙂 mdidle ", target: target)
        let descriptor = TextRangeDescriptor(container: .beforeCursor, startOffset: 2, endOffset: 8)

        let range = TextRangeGeometryResolver.utf16Range(for: descriptor, context: context)

        XCTAssertEqual(range, NSRange(location: 3, length: 6))
    }
}
