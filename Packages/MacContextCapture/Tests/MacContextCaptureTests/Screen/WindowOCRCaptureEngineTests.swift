import XCTest
@testable import MacContextCapture

@MainActor
final class WindowOCRCaptureEngineTests: XCTestCase {
    private struct FakeCapturer: ScreenWindowTextCapturing {
        let result: String?
        func captureWindowText(pid: pid_t, fieldText: String, focusPoint: CGPoint?, maxLines: Int, maxChars: Int) async throws -> String? {
            result
        }
    }

    /// Spin the cooperative pool until `condition` holds or we give up — the engine refreshes the
    /// cache from a fire-and-forget task.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    func testRefreshPopulatesCache() async {
        let engine = WindowOCRCaptureEngine(capturer: FakeCapturer(result: "hello\nworld"))
        engine.refresh(pid: 1234, fieldText: "")
        await waitUntil { engine.latestScreenText != nil }
        XCTAssertEqual(engine.latestScreenText, "hello\nworld")
    }

    func testEmptyResultLeavesCacheNil() async {
        let engine = WindowOCRCaptureEngine(capturer: FakeCapturer(result: ""))
        engine.refresh(pid: 1234, fieldText: "")
        await Task.yield()
        await Task.yield()
        XCTAssertNil(engine.latestScreenText)
    }

    func testClearEmptiesCache() async {
        let engine = WindowOCRCaptureEngine(capturer: FakeCapturer(result: "cached text"))
        engine.refresh(pid: 1234, fieldText: "")
        await waitUntil { engine.latestScreenText != nil }
        engine.clear()
        XCTAssertNil(engine.latestScreenText)
    }
}
