//
//  WindowOCRCaptureEngine.swift
//  MacContextCapture
//
//  Captures the focused app window via ScreenCaptureKit, OCRs it with Vision, and caches the
//  result so the (per-keystroke, latency-sensitive) completion path can read the last screen text
//  synchronously. The cache is refreshed out of band — on focus/window change plus a periodic
//  timer — by the app-target `ScreenContextController`, never on the typing path. See ADR-040.
//

import AutocompleteCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Seam over the screenshot+OCR work so the engine's caching/cancellation behaviour can be tested
/// with a fake (the real implementation needs a live display + Screen Recording permission).
public protocol ScreenWindowTextCapturing: Sendable {
    /// Capture the focused window for `pid` and return its OCR'd text, or `nil` if there's no
    /// suitable window / no recognised text. `fieldText` is the focused field's own text (already
    /// captured via Accessibility); lines matching it are stripped so screen context doesn't
    /// duplicate the field. `focusPoint` (caret location, global top-left screen coordinates)
    /// disambiguates multiple windows of the same app so the correct one is read.
    func captureWindowText(pid: pid_t, fieldText: String, focusPoint: CGPoint?, maxLines: Int, maxChars: Int) async throws -> String?
}

/// `ScreenTextProviding` cache fed by an out-of-band capturer. Main-actor isolated: the completion
/// controller reads `latestScreenText` on the main actor, and refreshes are kicked off from the
/// main-actor `ScreenContextController`. The heavy capture+OCR runs off the main actor inside the
/// capturer's `async` call.
@MainActor
public final class WindowOCRCaptureEngine: ScreenTextProviding {
    public private(set) var latestScreenText: String?

    private let capturer: ScreenWindowTextCapturing
    private let maxLines: Int
    private let maxChars: Int
    private var inFlight: Task<Void, Never>?

    /// `nonisolated` so it can be used as a default argument / constructed outside the main actor; it
    /// only stores immutable config (the cache is populated later, on the main actor, by `refresh`).
    public nonisolated init(
        capturer: ScreenWindowTextCapturing = ScreenCaptureKitWindowTextCapturer(),
        maxLines: Int = 40,
        maxChars: Int = 2000
    ) {
        self.capturer = capturer
        self.maxLines = maxLines
        self.maxChars = maxChars
    }

    /// Kick off a fresh capture for `pid`, superseding any in-flight one. `fieldText` is the focused
    /// field's own text, stripped from the OCR so screen context doesn't echo it. `focusPoint` is the
    /// caret location (global top-left screen coordinates) used to pick the right window when the app
    /// has several. Fire-and-forget: the cache updates when the capture completes. A failed/empty
    /// capture clears the cache so a stale reading can't outlive the window it came from.
    public func refresh(pid: pid_t, fieldText: String, focusPoint: CGPoint? = nil) {
        inFlight?.cancel()
        let capturer = self.capturer
        let maxLines = self.maxLines
        let maxChars = self.maxChars
        inFlight = Task { [weak self] in
            let text = try? await capturer.captureWindowText(
                pid: pid,
                fieldText: fieldText,
                focusPoint: focusPoint,
                maxLines: maxLines,
                maxChars: maxChars
            )
            guard let self, !Task.isCancelled else { return }
            self.latestScreenText = (text?.isEmpty == false) ? text : nil
        }
    }

    /// Drop the cached text and abandon any in-flight capture. Called when OCR is disabled, the
    /// field becomes ineligible (secure/excluded), or the pipeline stops.
    public func clear() {
        inFlight?.cancel()
        inFlight = nil
        latestScreenText = nil
    }
}

/// Real capturer: ScreenCaptureKit screenshot of the focused window → Vision OCR. Available on
/// macOS 14+ (`SCScreenshotManager.captureImage`); requires Screen Recording permission, which the
/// caller gates on before invoking.
public struct ScreenCaptureKitWindowTextCapturer: ScreenWindowTextCapturing {
    /// Longest side (in pixels) of the captured image before OCR. Caps Retina blow-up for speed.
    private let maxCaptureDimension: CGFloat

    public init(maxCaptureDimension: CGFloat = 1600) {
        self.maxCaptureDimension = maxCaptureDimension
    }

    public func captureWindowText(pid: pid_t, fieldText: String, focusPoint: CGPoint?, maxLines: Int, maxChars: Int) async throws -> String? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // `content.windows` is front-to-back; the index is the z-order the selector uses to break ties
        // between windows that overlap the caret.
        let candidates = content.windows.enumerated().map { index, window in
            ScreenWindowCandidate(window: window, zOrder: index)
        }
        guard let windowID = ScreenWindowSelector.selectWindowID(forPID: pid, from: candidates, focusPoint: focusPoint),
              let window = content.windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }

        let scale = ScreenWindowSelector.captureScale(for: window.frame.size, maxDimension: maxCaptureDimension)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        let lines = try await ScreenTextOCR.recognizeLines(in: image)
        // Drop corrupted/garbled recognitions before they can reach the prompt (the model otherwise
        // parrots OCR noise like "Ilne wilh real 5ulfix"). See ADR-049.
        let plausible = ScreenTextOCR.droppingCorruptedLines(lines)
        let withoutField = ScreenTextOCR.linesExcludingFieldText(plausible, fieldText: fieldText)
        let text = ScreenTextOCR.cleanedText(fromLines: withoutField, maxLines: maxLines, maxChars: maxChars)
        return text.isEmpty ? nil : text
    }
}

private extension ScreenWindowCandidate {
    init(window: SCWindow, zOrder: Int) {
        self.init(
            windowID: window.windowID,
            processID: window.owningApplication?.processID ?? -1,
            frame: window.frame,
            isOnScreen: window.isOnScreen,
            layer: window.windowLayer,
            zOrder: zOrder
        )
    }
}
