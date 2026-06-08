//
//  AXWindowIDResolver.swift
//  MacContextCapture
//
//  Best-effort bridge from a focused AX text element to the CoreGraphics window id that owns it.
//  Cotypist-style screenshot calibration needs a concrete target window; Accessibility exposes that
//  only through a private SPI, so this resolver dynamically loads it and falls back to CGWindowList.
//

import AppKit
import ApplicationServices
import AutocompleteCore
import CoreGraphics
import Darwin
import Foundation

@MainActor
enum AXWindowIDResolver {
    private typealias AXElementGetWindowFn = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    static func windowID(
        for element: AXUIElement,
        target: AppTarget,
        fieldRect: CGRect?
    ) -> CGWindowID? {
        if let id = privateWindowID(of: element) {
            return id
        }
        if let window = ancestorWindow(of: element),
           let id = privateWindowID(of: window) {
            return id
        }
        guard let pid = AXCaretHelper.pid(of: element) else {
            return nil
        }
        return fallbackWindowID(forPID: pid, fieldRect: fieldRect, target: target)
    }

    static func windowFrame(for element: AXUIElement) -> CGRect? {
        if let window = ancestorWindow(of: element),
           let frame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: window),
           !frame.isEmpty {
            return AXCaretHelper.cocoaRect(fromAccessibilityRect: frame)
        }
        guard let pid = AXCaretHelper.pid(of: element) else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let focused = AXCaretHelper.copyAttributeValue(kAXFocusedWindowAttribute as CFString, on: appElement),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = unsafeBitCast(focused, to: AXUIElement.self)
        guard let frame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: window),
              !frame.isEmpty else {
            return nil
        }
        return AXCaretHelper.cocoaRect(fromAccessibilityRect: frame)
    }

    private static func privateWindowID(of element: AXUIElement) -> CGWindowID? {
        guard let symbol = privateWindowSymbol() else {
            return nil
        }
        let fn = unsafeBitCast(symbol, to: AXElementGetWindowFn.self)
        var id = CGWindowID(0)
        guard fn(element, &id) == .success, id != 0 else {
            return nil
        }
        return id
    }

    private static func privateWindowSymbol() -> UnsafeMutableRawPointer? {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") {
            return symbol
        }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__AXUIElementGetWindow")
    }

    private static func ancestorWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 12 {
            let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: node)
            if role == kAXWindowRole as String {
                return node
            }
            current = AXCaretHelper.parentElement(of: node)
            depth += 1
        }
        return nil
    }

    private static func fallbackWindowID(
        forPID pid: pid_t,
        fieldRect: CGRect?,
        target: AppTarget
    ) -> CGWindowID? {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let candidates = rawList.compactMap { info -> WindowCandidate? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }
            let cgFrame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            guard cgFrame.width >= ScreenWindowSelector.minimumWidth,
                  cgFrame.height >= ScreenWindowSelector.minimumHeight else {
                return nil
            }
            return WindowCandidate(
                windowID: CGWindowID(truncating: number),
                frame: AXCaretHelper.cocoaRect(fromAccessibilityRect: cgFrame),
                layer: layer,
                title: info[kCGWindowName as String] as? String
            )
        }
        guard !candidates.isEmpty else {
            return nil
        }

        let fieldPoint = fieldRect.map { CGPoint(x: $0.midX, y: $0.midY) }
        let ranked = candidates.sorted { lhs, rhs in
            if let fieldPoint {
                let lhsContains = lhs.frame.contains(fieldPoint)
                let rhsContains = rhs.frame.contains(fieldPoint)
                if lhsContains != rhsContains { return lhsContains }
            }
            let lhsTitleMatch = target.windowTitle.map { lhs.title == $0 } ?? false
            let rhsTitleMatch = target.windowTitle.map { rhs.title == $0 } ?? false
            if lhsTitleMatch != rhsTitleMatch { return lhsTitleMatch }
            let lhsNormal = lhs.layer == 0
            let rhsNormal = rhs.layer == 0
            if lhsNormal != rhsNormal { return lhsNormal }
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            return lhs.windowID < rhs.windowID
        }
        return ranked.first?.windowID
    }

    private struct WindowCandidate {
        var windowID: CGWindowID
        var frame: CGRect
        var layer: Int
        var title: String?
    }
}
