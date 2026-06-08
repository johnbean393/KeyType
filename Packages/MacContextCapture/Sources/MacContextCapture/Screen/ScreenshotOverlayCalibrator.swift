//
//  ScreenshotOverlayCalibrator.swift
//  MacContextCapture
//
//  Cotypist-style screenshot calibration for overlay appearance. Given a focused-field snapshot and
//  the AX-derived text style, this captures the caret line, renders candidate text sizes/offsets, and
//  chooses the candidate with the lowest normalized glyph RMSE against the screenshot.
//

import AppKit
import AutocompleteCore
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import Vision

public struct ScreenshotCalibrationResult: Equatable {
    public var detectedFontSize: CGFloat
    public var bestSize: CGFloat
    public var rmse: CGFloat
    public var confidence: CGFloat
    public var fontSizeAdjustmentFactor: CGFloat
    public var verticalAlignmentOffset: CGFloat
    public var actualLineLength: Int
    public var recognizedText: String?
    public var usesInvertedLuminance: Bool
    public var meetsQualityThresholds: Bool

    public init(
        detectedFontSize: CGFloat,
        bestSize: CGFloat,
        rmse: CGFloat,
        confidence: CGFloat,
        fontSizeAdjustmentFactor: CGFloat,
        verticalAlignmentOffset: CGFloat,
        actualLineLength: Int,
        recognizedText: String?,
        usesInvertedLuminance: Bool,
        meetsQualityThresholds: Bool
    ) {
        self.detectedFontSize = detectedFontSize
        self.bestSize = bestSize
        self.rmse = rmse
        self.confidence = confidence
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.actualLineLength = actualLineLength
        self.recognizedText = recognizedText
        self.usesInvertedLuminance = usesInvertedLuminance
        self.meetsQualityThresholds = meetsQualityThresholds
    }
}

public enum ScreenshotCalibrationError: Error, Equatable {
    case missingGeometry
    case emptyLinePrefix
    case noDisplay
    case captureFailed
}

@MainActor
public final class ScreenshotOverlayCalibrator {
    private let minimumConfidence: CGFloat
    private let maxCropWidth: CGFloat
    private let maxCropHeight: CGFloat

    public nonisolated init(
        minimumConfidence: CGFloat = 0.55,
        maxCropWidth: CGFloat = 900,
        maxCropHeight: CGFloat = 220
    ) {
        self.minimumConfidence = minimumConfidence
        self.maxCropWidth = maxCropWidth
        self.maxCropHeight = maxCropHeight
    }

    public func calibrate(
        snapshot: FocusedFieldSnapshot,
        font: NSFont,
        textColor: NSColor?
    ) async throws -> ScreenshotCalibrationResult {
        let context = snapshot.context
        guard let caret = context.geometry.cursorRect, !caret.isEmpty else {
            throw ScreenshotCalibrationError.missingGeometry
        }
        let prefix = context.beforeCursor.currentLinePrefix
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenshotCalibrationError.emptyLinePrefix
        }

        let field = context.geometry.fieldRect
            ?? snapshot.windowFrame
            ?? caret.insetBy(dx: -320, dy: -90)
        let crop = ScreenshotCalibrationGeometry.cropRect(
            caret: caret,
            field: field,
            maxWidth: maxCropWidth,
            maxHeight: maxCropHeight
        )
        let screenshot = try await capture(region: crop, windowID: snapshot.windowID)
        let observations = (try? await recognizeText(in: screenshot)) ?? []
        let recognizedText = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .first
        let actualLineLength = recognizedText?.count ?? prefix.count

        let sizes = ScreenshotCalibrationScorer.candidateSizes(around: font.pointSize)
        let offsets = ScreenshotCalibrationScorer.candidateVerticalOffsets()
        let candidate = ScreenshotCalibrationScorer.bestCandidate(
            text: prefix,
            baseFont: font,
            color: textColor ?? .labelColor,
            observed: screenshot,
            cropRect: crop,
            fieldRect: field,
            caretRect: caret,
            sizes: sizes,
            verticalOffsets: offsets
        )

        let confidence = max(0, 1 - candidate.rmse)
        let sizeFactor = candidate.size / max(1, font.pointSize)
        let lineLengthIsUseful = actualLineLength >= min(2, prefix.count)
        let plausibleAdjustment = (0.72...1.42).contains(sizeFactor)
            && abs(candidate.verticalOffset) <= 14
        let meetsQualityThresholds = confidence >= minimumConfidence
            && lineLengthIsUseful
            && plausibleAdjustment
            && candidate.rmse.isFinite

        return ScreenshotCalibrationResult(
            detectedFontSize: font.pointSize,
            bestSize: candidate.size,
            rmse: candidate.rmse,
            confidence: confidence,
            fontSizeAdjustmentFactor: sizeFactor,
            verticalAlignmentOffset: candidate.verticalOffset,
            actualLineLength: actualLineLength,
            recognizedText: recognizedText,
            usesInvertedLuminance: candidate.usesInvertedLuminance,
            meetsQualityThresholds: meetsQualityThresholds
        )
    }

    public func capture(region appKitRegion: CGRect, windowID: CGWindowID?) async throws -> CGImage {
        let region = appKitRegion.integral
        guard !region.isEmpty else {
            throw ScreenshotCalibrationError.missingGeometry
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(region) || $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) }
            ?? NSScreen.main
        guard let screen else {
            throw ScreenshotCalibrationError.noDisplay
        }
        let cgRegion = Self.coreGraphicsRect(fromAppKitRect: region, on: screen)

        if CGPreflightScreenCaptureAccess() {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let displayID = Self.displayID(for: screen),
               let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first {
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = cgRegion
                configuration.width = max(1, Int((region.width * screen.backingScaleFactor).rounded()))
                configuration.height = max(1, Int((region.height * screen.backingScaleFactor).rounded()))
                configuration.showsCursor = false
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                return try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            }
        }

        let option: CGWindowListOption = windowID == nil ? .optionOnScreenOnly : .optionIncludingWindow
        let id = windowID ?? kCGNullWindowID
        guard let image = legacyCGWindowListCreateImage(
            region: cgRegion,
            option: option,
            windowID: id,
            imageOption: [.bestResolution, .boundsIgnoreFraming]
        ) else {
            throw ScreenshotCalibrationError.captureFailed
        }
        return image
    }

    private func recognizeText(in image: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: request.results as? [VNRecognizedTextObservation] ?? [])
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func coreGraphicsRect(fromAppKitRect rect: CGRect, on screen: NSScreen) -> CGRect {
        let displayID = displayID(for: screen)
        let cgBounds = displayID.map(CGDisplayBounds) ?? screen.frame
        let localX = rect.minX - screen.frame.minX
        let localY = screen.frame.maxY - rect.maxY
        return CGRect(
            x: cgBounds.minX + localX,
            y: cgBounds.minY + localY,
            width: rect.width,
            height: rect.height
        )
    }
}

enum ScreenshotCalibrationGeometry {
    static func cropRect(
        caret: CGRect,
        field: CGRect,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGRect {
        let verticalPadding = max(18, caret.height * 2)
        let horizontalPadding: CGFloat = 28
        let desired = CGRect(
            x: field.minX - horizontalPadding,
            y: caret.midY - max(caret.height * 3, 42),
            width: min(maxWidth, max(field.width + horizontalPadding * 2, 260)),
            height: min(maxHeight, max(verticalPadding * 2 + caret.height, 90))
        )
        let x = min(max(desired.minX, field.minX - horizontalPadding), max(field.maxX - desired.width + horizontalPadding, desired.minX))
        return CGRect(x: x, y: desired.minY, width: desired.width, height: desired.height).integral
    }
}

struct ScreenshotCalibrationCandidate: Equatable {
    var size: CGFloat
    var verticalOffset: CGFloat
    var rmse: CGFloat
    var usesInvertedLuminance: Bool
}

enum ScreenshotCalibrationScorer {
    static func candidateSizes(around detectedSize: CGFloat) -> [CGFloat] {
        stride(
            from: max(7, detectedSize * 0.75),
            through: min(40, detectedSize * 1.35),
            by: 0.25
        ).map { CGFloat($0) }
    }

    static func candidateVerticalOffsets() -> [CGFloat] {
        stride(from: CGFloat(-6), through: CGFloat(6), by: CGFloat(1)).map { $0 }
    }

    static func bestCandidate(
        text: String,
        baseFont: NSFont,
        color: NSColor,
        observed: CGImage,
        cropRect: CGRect,
        fieldRect: CGRect,
        caretRect: CGRect,
        sizes: [CGFloat],
        verticalOffsets: [CGFloat]
    ) -> ScreenshotCalibrationCandidate {
        var best = ScreenshotCalibrationCandidate(
            size: baseFont.pointSize,
            verticalOffset: 0,
            rmse: .greatestFiniteMagnitude,
            usesInvertedLuminance: false
        )

        for size in sizes {
            for offset in verticalOffsets {
                guard let rendered = renderText(
                    text,
                    baseFont: baseFont,
                    size: size,
                    color: color,
                    imageSize: CGSize(width: observed.width, height: observed.height),
                    cropRect: cropRect,
                    fieldRect: fieldRect,
                    caretRect: caretRect,
                    verticalOffset: offset
                ) else {
                    continue
                }
                let direct = normalizedRMSE(rendered: rendered, observed: observed, invertRenderedLuminance: false)
                let inverted = normalizedRMSE(rendered: rendered, observed: observed, invertRenderedLuminance: true)
                let usesInverted = inverted < direct
                let rmse = min(direct, inverted)
                if rmse < best.rmse {
                    best = ScreenshotCalibrationCandidate(
                        size: size,
                        verticalOffset: offset,
                        rmse: rmse,
                        usesInvertedLuminance: usesInverted
                    )
                }
            }
        }
        return best
    }

    static func normalizedRMSE(
        rendered: CGImage,
        observed: CGImage,
        invertRenderedLuminance: Bool = false
    ) -> CGFloat {
        let width = min(rendered.width, observed.width)
        let height = min(rendered.height, observed.height)
        guard width > 0, height > 0 else { return .greatestFiniteMagnitude }

        let renderedRGBA = rgba(rendered, width: width, height: height)
        let observedRGBA = rgba(observed, width: width, height: height)
        let observedHasTransparency = stride(from: 3, to: observedRGBA.count, by: 4)
            .contains { observedRGBA[$0] < 250 }
        var weightedSum = 0.0
        var weightTotal = 0.0

        for index in 0..<(width * height) {
            let renderedAlpha = Double(renderedRGBA[index * 4 + 3]) / 255.0
            let observedAlpha = Double(observedRGBA[index * 4 + 3]) / 255.0
            let alpha = observedHasTransparency ? max(renderedAlpha, observedAlpha) : renderedAlpha
            guard alpha > 0.03 else { continue }

            var expected = luminance(
                r: renderedRGBA[index * 4],
                g: renderedRGBA[index * 4 + 1],
                b: renderedRGBA[index * 4 + 2]
            )
            if invertRenderedLuminance {
                expected = 255 - expected
            }
            let observed = luminance(
                r: observedRGBA[index * 4],
                g: observedRGBA[index * 4 + 1],
                b: observedRGBA[index * 4 + 2]
            )
            let diff = expected - observed
            let alphaDiff = observedHasTransparency
                ? (renderedAlpha - observedAlpha) * 255.0
                : 0
            weightedSum += (diff * diff + alphaDiff * alphaDiff) * alpha
            weightTotal += alpha
        }

        guard weightTotal > 0 else {
            return .greatestFiniteMagnitude
        }
        return CGFloat(sqrt(weightedSum / weightTotal) / 255.0)
    }

    static func renderText(
        _ text: String,
        baseFont: NSFont,
        size: CGFloat,
        color: NSColor,
        imageSize: CGSize,
        cropRect: CGRect,
        fieldRect: CGRect,
        caretRect: CGRect,
        verticalOffset: CGFloat
    ) -> CGImage? {
        let width = max(1, Int(imageSize.width.rounded()))
        let height = max(1, Int(imageSize.height.rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        let font = NSFont(descriptor: baseFont.fontDescriptor, size: size)
            ?? NSFont.systemFont(ofSize: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)

        let scaleX = imageSize.width / max(1, cropRect.width)
        let scaleY = imageSize.height / max(1, cropRect.height)
        let x = max(0, (fieldRect.minX - cropRect.minX) * scaleX)
        let lineHeight = max(1, font.ascender - font.descender + font.leading)
        let caretTop = (cropRect.maxY - caretRect.maxY) * scaleY
        let caretCentering = max(0, (caretRect.height - lineHeight) / 2) * scaleY
        let y = max(0, caretTop + caretCentering + verticalOffset * scaleY)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        graphicsContext.cgContext.translateBy(x: 0, y: CGFloat(height))
        graphicsContext.cgContext.scaleBy(x: 1, y: -1)
        attributed.draw(at: CGPoint(x: x, y: y))
        return bitmap.cgImage
    }

    private static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.interpolationQuality = .none
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return rgba
    }

    private static func luminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
        0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
    }
}

private func legacyCGWindowListCreateImage(
    region: CGRect,
    option: CGWindowListOption,
    windowID: CGWindowID,
    imageOption: CGWindowImageOption
) -> CGImage? {
    guard let handle = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        RTLD_NOW
    ) else {
        return nil
    }
    defer { dlclose(handle) }

    guard let symbol = dlsym(handle, "CGWindowListCreateImage") else {
        return nil
    }

    typealias Fn = @convention(c) (
        CGRect,
        CGWindowListOption.RawValue,
        CGWindowID,
        CGWindowImageOption.RawValue
    ) -> Unmanaged<CGImage>?

    let fn = unsafeBitCast(symbol, to: Fn.self)
    return fn(region, option.rawValue, windowID, imageOption.rawValue)?.takeRetainedValue()
}

private extension String {
    var currentLinePrefix: String {
        split(separator: "\n", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? self
    }
}
