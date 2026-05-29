//
//  WritingDirectionTests.swift
//  MacContextCaptureTests
//

import XCTest
@testable import MacContextCapture

final class WritingDirectionTests: XCTestCase {
    func testEmptyStringIsLTR() {
        XCTAssertFalse(WritingDirection.isRightToLeft(""))
    }

    func testEnglishIsLTR() {
        XCTAssertFalse(WritingDirection.isRightToLeft("hello world"))
    }

    func testArabicIsRTL() {
        // "Arabic: مرحبا"; first strong character is Arabic so the whole text is treated RTL.
        XCTAssertTrue(WritingDirection.isRightToLeft("مرحبا"))
    }

    func testHebrewIsRTL() {
        XCTAssertTrue(WritingDirection.isRightToLeft("שלום"))
    }

    func testLeadingPunctuationFollowedByArabicIsRTL() {
        XCTAssertTrue(WritingDirection.isRightToLeft("\"مرحبا\""))
    }

    func testDigitsOnlyDefaultsToLTR() {
        XCTAssertFalse(WritingDirection.isRightToLeft("12345"))
    }
}
