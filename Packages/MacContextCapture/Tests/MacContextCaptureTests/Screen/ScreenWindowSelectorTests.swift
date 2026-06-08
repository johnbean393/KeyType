import CoreGraphics
import XCTest
@testable import MacContextCapture

final class ScreenWindowSelectorTests: XCTestCase {
    private func candidate(
        id: CGWindowID,
        pid: pid_t,
        frame: CGRect,
        onScreen: Bool = true,
        layer: Int = 0,
        zOrder: Int = .max
    ) -> ScreenWindowCandidate {
        ScreenWindowCandidate(windowID: id, processID: pid, frame: frame, isOnScreen: onScreen, layer: layer, zOrder: zOrder)
    }

    func testReturnsNilWhenNoWindowMatchesPID() {
        let candidates = [candidate(id: 1, pid: 99, frame: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertNil(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates))
    }

    func testSkipsTinyWindows() {
        let candidates = [candidate(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 50, height: 40))]
        XCTAssertNil(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates))
    }

    func testPicksLargestNormalLayerWindow() {
        let candidates = [
            candidate(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            candidate(id: 2, pid: 42, frame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
            candidate(id: 3, pid: 99, frame: CGRect(x: 0, y: 0, width: 2000, height: 1500))
        ]
        XCTAssertEqual(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates), 2)
    }

    func testPrefersOnScreenOverLarger() {
        let candidates = [
            candidate(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 2000, height: 1500), onScreen: false),
            candidate(id: 2, pid: 42, frame: CGRect(x: 0, y: 0, width: 800, height: 600), onScreen: true)
        ]
        XCTAssertEqual(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates), 2)
    }

    func testPrefersNormalLayerOverOverlay() {
        let candidates = [
            candidate(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 1200, height: 900), layer: 25),
            candidate(id: 2, pid: 42, frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0)
        ]
        XCTAssertEqual(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates), 2)
    }

    func testFocusPointPicksWindowContainingCaretOverLarger() {
        // Two windows of the same app: the caret is in the smaller one, which must win over the
        // larger window the area-based ranking would otherwise pick.
        let candidates = [
            candidate(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
            candidate(id: 2, pid: 42, frame: CGRect(x: 1700, y: 0, width: 600, height: 400))
        ]
        let caret = CGPoint(x: 1750, y: 50)
        XCTAssertEqual(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates, focusPoint: caret), 2)
    }

    func testOverlappingWindowsAtCaretPickFrontmost() {
        // A small compose window (frontmost, z=0) floats over a large background window (z=1); the
        // caret falls inside both. The frontmost must win even though the background is larger.
        let candidates = [
            candidate(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), zOrder: 1),
            candidate(id: 2, pid: 42, frame: CGRect(x: 100, y: 100, width: 500, height: 400), zOrder: 0)
        ]
        let caret = CGPoint(x: 200, y: 200) // inside both
        XCTAssertEqual(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates, focusPoint: caret), 2)
    }

    func testFallbackPrefersFrontmostWhenNoCaret() {
        // With no caret info, the frontmost window is a better guess than the largest.
        let candidates = [
            candidate(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), zOrder: 1),
            candidate(id: 2, pid: 42, frame: CGRect(x: 0, y: 0, width: 800, height: 600), zOrder: 0)
        ]
        XCTAssertEqual(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates), 2)
    }

    func testFocusPointFallsBackToRankingWhenOutsideAllWindows() {
        let candidates = [
            candidate(id: 1, pid: 42, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            candidate(id: 2, pid: 42, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        ]
        let caret = CGPoint(x: 9000, y: 9000)
        XCTAssertEqual(ScreenWindowSelector.selectWindowID(forPID: 42, from: candidates, focusPoint: caret), 2)
    }

    func testCaptureScaleDownscalesLargeWindows() {
        let scale = ScreenWindowSelector.captureScale(for: CGSize(width: 3200, height: 1800), maxDimension: 1600)
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
    }

    func testCaptureScaleNeverUpscales() {
        let scale = ScreenWindowSelector.captureScale(for: CGSize(width: 800, height: 600), maxDimension: 1600)
        XCTAssertEqual(scale, 1, accuracy: 0.0001)
    }
}
