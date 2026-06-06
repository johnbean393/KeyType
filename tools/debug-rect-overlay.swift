#!/usr/bin/env swift

import AppKit
import Foundation

struct RectSpec {
    var label: String
    var rect: CGRect
    var color: NSColor
}

final class RectOverlayView: NSView {
    private let screenFrame: CGRect
    private let rects: [RectSpec]
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    init(frame: CGRect, screenFrame: CGRect, rects: [RectSpec]) {
        self.screenFrame = screenFrame
        self.rects = rects
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for spec in rects {
            let rect = spec.rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            spec.color.withAlphaComponent(0.18).setFill()
            spec.color.withAlphaComponent(0.95).setStroke()

            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.fill()
            path.stroke()

            let labelRect = CGRect(x: rect.minX + 4, y: rect.maxY + 4, width: 240, height: 18)
            let label = "\(spec.label) \(Int(spec.rect.minX)),\(Int(spec.rect.minY)) \(Int(spec.rect.width))x\(Int(spec.rect.height))"
            label.draw(
                in: labelRect,
                withAttributes: [
                    .font: font,
                    .foregroundColor: spec.color,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.55)
                ]
            )
        }
    }
}

func color(named name: String) -> NSColor {
    switch name.lowercased() {
    case "red": return .systemRed
    case "green": return .systemGreen
    case "blue": return .systemBlue
    case "yellow": return .systemYellow
    case "orange": return .systemOrange
    case "purple": return .systemPurple
    case "pink": return .systemPink
    default: return .white
    }
}

func parseRect(_ argument: String) -> RectSpec? {
    let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    let label = parts[0]
    let values = parts[1].split(separator: ",").map(String.init)
    guard values.count >= 4,
          let x = Double(values[0]),
          let y = Double(values[1]),
          let width = Double(values[2]),
          let height = Double(values[3]) else {
        return nil
    }

    let name = values.count >= 5 ? values[4] : "white"
    return RectSpec(
        label: label,
        rect: CGRect(x: x, y: y, width: width, height: height),
        color: color(named: name)
    )
}

let args = Array(CommandLine.arguments.dropFirst())
var duration: TimeInterval = 8
var rects: [RectSpec] = []

var index = 0
while index < args.count {
    switch args[index] {
    case "--duration":
        if index + 1 < args.count, let value = Double(args[index + 1]) {
            duration = value
            index += 2
        } else {
            index += 1
        }
    case "--rect":
        if index + 1 < args.count, let spec = parseRect(args[index + 1]) {
            rects.append(spec)
            index += 2
        } else {
            index += 1
        }
    default:
        index += 1
    }
}

if rects.isEmpty {
    fputs("Usage: debug-rect-overlay.swift --rect label:x,y,width,height,color [--rect ...] [--duration seconds]\n", stderr)
    exit(2)
}

let screenFrame = NSScreen.screens
    .map(\.frame)
    .reduce(CGRect.null) { $0.union($1) }

let panel = NSPanel(
    contentRect: screenFrame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.backgroundColor = .clear
panel.contentView = RectOverlayView(
    frame: CGRect(origin: .zero, size: screenFrame.size),
    screenFrame: screenFrame,
    rects: rects
)
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
panel.hasShadow = false
panel.hidesOnDeactivate = false
panel.ignoresMouseEvents = true
panel.isFloatingPanel = true
panel.level = .screenSaver
panel.isOpaque = false
panel.isReleasedWhenClosed = false
panel.animationBehavior = .none

NSApplication.shared.setActivationPolicy(.accessory)
panel.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    NSApplication.shared.terminate(nil)
}
NSApplication.shared.run()
