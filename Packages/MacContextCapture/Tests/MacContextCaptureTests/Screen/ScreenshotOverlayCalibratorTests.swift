import AppKit
import CoreGraphics
import XCTest
@testable import MacContextCapture

final class ScreenshotOverlayCalibratorTests: XCTestCase {
    func testCropRectCentersAroundCaretLineAndCapsSize() {
        let crop = ScreenshotCalibrationGeometry.cropRect(
            caret: CGRect(x: 460, y: 300, width: 2, height: 18),
            field: CGRect(x: 100, y: 250, width: 1200, height: 180),
            maxWidth: 640,
            maxHeight: 120
        )

        XCTAssertLessThanOrEqual(crop.width, 640)
        XCTAssertLessThanOrEqual(crop.height, 120)
        XCTAssertTrue(crop.contains(CGPoint(x: 461, y: 309)))
    }

    func testNormalizedRMSEIsZeroForIdenticalRenderedImages() throws {
        let font = NSFont.systemFont(ofSize: 15)
        let crop = CGRect(x: 0, y: 0, width: 320, height: 100)
        let field = CGRect(x: 12, y: 0, width: 280, height: 100)
        let caret = CGRect(x: 110, y: 40, width: 2, height: 18)
        let image = try XCTUnwrap(
            ScreenshotCalibrationScorer.renderText(
                "hello",
                baseFont: font,
                size: 15,
                color: .black,
                imageSize: CGSize(width: 320, height: 100),
                cropRect: crop,
                fieldRect: field,
                caretRect: caret,
                verticalOffset: 0
            )
        )

        XCTAssertEqual(
            ScreenshotCalibrationScorer.normalizedRMSE(rendered: image, observed: image),
            0,
            accuracy: 0.0001
        )
    }

    func testBestCandidateRecoversRenderedFontSizeAndVerticalOffset() throws {
        let font = NSFont.systemFont(ofSize: 14)
        let crop = CGRect(x: 0, y: 0, width: 420, height: 120)
        let field = CGRect(x: 16, y: 0, width: 380, height: 120)
        let caret = CGRect(x: 180, y: 48, width: 2, height: 18)
        let observed = try XCTUnwrap(
            ScreenshotCalibrationScorer.renderText(
                "calibration",
                baseFont: font,
                size: 16,
                color: .black,
                imageSize: CGSize(width: 420, height: 120),
                cropRect: crop,
                fieldRect: field,
                caretRect: caret,
                verticalOffset: 2
            )
        )

        let best = ScreenshotCalibrationScorer.bestCandidate(
            text: "calibration",
            baseFont: font,
            color: .black,
            observed: observed,
            cropRect: crop,
            fieldRect: field,
            caretRect: caret,
            sizes: [14, 15, 16, 17],
            verticalOffsets: [-1, 0, 1, 2, 3]
        )

        XCTAssertEqual(best.size, 16, accuracy: 0.001)
        XCTAssertEqual(best.verticalOffset, 2, accuracy: 0.001)
        XCTAssertEqual(best.rmse, 0, accuracy: 0.0001)
    }
}
