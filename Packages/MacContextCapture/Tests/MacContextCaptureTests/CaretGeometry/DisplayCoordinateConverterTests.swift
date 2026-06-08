//
//  DisplayCoordinateConverterTests.swift
//  MacContextCaptureTests
//
//  Pure CG <-> AppKit conversion math; built against synthetic DisplayGeometry values
//  so the tests don't depend on a real `NSScreen` configuration.
//

import XCTest
import CoreGraphics
@testable import MacContextCapture

final class DisplayCoordinateConverterTests: XCTestCase {
    /// Single 1920x1080 display where CG (top-left) and AppKit (bottom-left) frames cover the
    /// same global region.
    private let singleDisplay = DisplayGeometry(
        appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056),
        coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 2
    )

    func testCGToAppKitFlipsAroundDisplayHeight() throws {
        // A 20-tall rect at CG y=100 should land at AppKit y = 1080 - 100 - 20 = 960.
        let cgRect = CGRect(x: 50, y: 100, width: 2, height: 20)
        let appKit = try XCTUnwrap(
            DisplayCoordinateConverter.appKitRect(
                fromCoreGraphicsRect: cgRect,
                displays: [singleDisplay]
            )
        )
        XCTAssertEqual(appKit.minX, 50, accuracy: 0.001)
        XCTAssertEqual(appKit.minY, 960, accuracy: 0.001)
        XCTAssertEqual(appKit.width, 2, accuracy: 0.001)
        XCTAssertEqual(appKit.height, 20, accuracy: 0.001)
    }

    func testReturnsNilWhenRectIsOutsideAllDisplays() {
        let cgRect = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        XCTAssertNil(
            DisplayCoordinateConverter.appKitRect(
                fromCoreGraphicsRect: cgRect,
                displays: [singleDisplay]
            )
        )
    }

    func testPixelRectScalesByBackingScaleFactor() throws {
        // A 4-px-wide caret in pixel coords on a @2x display should resolve to 2 pt wide.
        let pixelRect = CGRect(x: 200, y: 400, width: 4, height: 40)
        let candidates = DisplayCoordinateConverter.appKitRectsFromPixelRect(
            pixelRect,
            displays: [singleDisplay]
        )
        let first = try XCTUnwrap(candidates.first)
        XCTAssertEqual(first.width, 2, accuracy: 0.001)
        XCTAssertEqual(first.height, 20, accuracy: 0.001)
        XCTAssertEqual(first.minX, 100, accuracy: 0.001)
        // 1080 - (400/2) - 20 = 860.
        XCTAssertEqual(first.minY, 860, accuracy: 0.001)
    }

    func testAppKitPointToCGFlipsAroundDisplayHeight() throws {
        // AppKit (bottom-left) y=960 should map back to CG (top-left) y=120 on a 1080-tall display.
        let cg = try XCTUnwrap(
            DisplayCoordinateConverter.coreGraphicsPoint(
                fromAppKitPoint: CGPoint(x: 50, y: 960),
                displays: [singleDisplay]
            )
        )
        XCTAssertEqual(cg.x, 50, accuracy: 0.001)
        XCTAssertEqual(cg.y, 120, accuracy: 0.001)
    }

    func testCGRectToAppKitPointRoundTrips() throws {
        // The point conversion must invert the rect conversion: a caret's CG midpoint → AppKit → CG
        // returns the original midpoint. This is the exact path used for window selection.
        let cgRect = CGRect(x: 300, y: 220, width: 2, height: 24)
        let appKit = try XCTUnwrap(
            DisplayCoordinateConverter.appKitRect(fromCoreGraphicsRect: cgRect, displays: [singleDisplay])
        )
        let backToCG = try XCTUnwrap(
            DisplayCoordinateConverter.coreGraphicsPoint(
                fromAppKitPoint: CGPoint(x: appKit.midX, y: appKit.midY),
                displays: [singleDisplay]
            )
        )
        XCTAssertEqual(backToCG.x, cgRect.midX, accuracy: 0.001)
        XCTAssertEqual(backToCG.y, cgRect.midY, accuracy: 0.001)
    }

    func testAppKitPointToCGOnSecondaryDisplay() throws {
        let secondary = DisplayGeometry(
            appKitFrame: CGRect(x: 1920, y: 180, width: 1440, height: 900),
            visibleFrame: CGRect(x: 1920, y: 204, width: 1440, height: 876),
            coreGraphicsBounds: CGRect(x: 1920, y: 0, width: 1440, height: 900),
            backingScaleFactor: 2
        )
        // AppKit point inside the secondary display. localY = appKitFrame.maxY(1080) - 1010 = 70,
        // so CG y = coreGraphicsBounds.minY(0) + 70 = 70.
        let cg = try XCTUnwrap(
            DisplayCoordinateConverter.coreGraphicsPoint(
                fromAppKitPoint: CGPoint(x: 2500, y: 1010),
                displays: [singleDisplay, secondary]
            )
        )
        XCTAssertEqual(cg.x, 2500, accuracy: 0.001)
        XCTAssertEqual(cg.y, 70, accuracy: 0.001)
    }

    func testAppKitPointToCGReturnsNilOutsideAllDisplays() {
        XCTAssertNil(
            DisplayCoordinateConverter.coreGraphicsPoint(
                fromAppKitPoint: CGPoint(x: 9000, y: 9000),
                displays: [singleDisplay]
            )
        )
    }

    func testMultiDisplayPicksContainingDisplay() throws {
        let primary = singleDisplay
        // Secondary 1440x900 sitting to the right of the primary in CG space; AppKit places it
        // at the same x but with its own height baseline.
        let secondary = DisplayGeometry(
            appKitFrame: CGRect(x: 1920, y: 180, width: 1440, height: 900),
            visibleFrame: CGRect(x: 1920, y: 204, width: 1440, height: 876),
            coreGraphicsBounds: CGRect(x: 1920, y: 0, width: 1440, height: 900),
            backingScaleFactor: 2
        )
        // Rect clearly inside the secondary display.
        let cgRect = CGRect(x: 2500, y: 50, width: 2, height: 20)
        let appKit = try XCTUnwrap(
            DisplayCoordinateConverter.appKitRect(
                fromCoreGraphicsRect: cgRect,
                displays: [primary, secondary]
            )
        )
        // Local x = 2500 - 1920 = 580; AppKit x = 1920 + 580 = 2500.
        XCTAssertEqual(appKit.minX, 2500, accuracy: 0.001)
        // Local y = 50; AppKit y = appKitFrame.maxY (180 + 900 = 1080) - 50 - 20 = 1010.
        XCTAssertEqual(appKit.minY, 1010, accuracy: 0.001)
    }
}
