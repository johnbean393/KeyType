//
//  LanguageDetectorTests.swift
//  MacContextCaptureTests
//
//  Smoke tests around `NLLanguageRecognizer`. The recognizer's exact behavior is platform-
//  defined, so the assertions stay loose (presence + plausible language code).
//

import XCTest
@testable import MacContextCapture

final class LanguageDetectorTests: XCTestCase {
    func testReturnsNilForVeryShortInput() {
        XCTAssertNil(LanguageDetector.detectLanguage(in: "hi"))
    }

    func testDetectsEnglishProse() {
        let result = LanguageDetector.detectLanguage(in: "The quick brown fox jumps over the lazy dog.")
        XCTAssertEqual(result, "en")
    }

    func testDetectsFrench() {
        let result = LanguageDetector.detectLanguage(in: "Bonjour, je m'appelle Jean et j'habite à Paris depuis deux ans.")
        XCTAssertEqual(result, "fr")
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(LanguageDetector.detectLanguage(in: "   \n   \t   "))
    }
}
