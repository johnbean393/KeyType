//
//  CaretGeometryQualityTests.swift
//  MacContextCaptureTests
//

import XCTest
@testable import MacContextCapture

final class CaretGeometryQualityTests: XCTestCase {
    func testQualityOrdering() {
        XCTAssertLessThan(AXCaretGeometryQuality.estimated, AXCaretGeometryQuality.derived)
        XCTAssertLessThan(AXCaretGeometryQuality.derived, AXCaretGeometryQuality.exact)
    }

    func testQualityLabels() {
        XCTAssertEqual(AXCaretGeometryQuality.exact.label, "exact")
        XCTAssertEqual(AXCaretGeometryQuality.derived.label, "derived")
        XCTAssertEqual(AXCaretGeometryQuality.estimated.label, "estimated")
    }
}
