//
//  AccessibilityContextTracker.swift
//  MacContextCapture
//
//  Push-style replacement for Red Dot's 30 fps Timer poll. Subscribes to AX notifications
//  for focus/window/selection/value/destroy/miniaturize, debounces bursts, and falls back
//  to a low-frequency safety poll for apps that under-report. Re-targets the AX observer
//  whenever the frontmost app or focused-element pid changes.
//
//  All work runs on the main actor; AX reads are bounded by the resolver's depth/node caps
//  so this never holds the main thread for long.
//

import AppKit
import ApplicationServices
import AutocompleteCore
import CoreGraphics
import Foundation

@MainActor
public final class AccessibilityContextTracker: NSObject {
    public typealias Listener = (FocusedFieldSnapshot?) -> Void

    private nonisolated let reader: FocusedFieldReader
    private nonisolated let permissionChecker: AccessibilityPermissionChecker
    private nonisolated let webAppClassifier: AppBundleWebAppClassifier
    private let systemElement = AXUIElementCreateSystemWide()

    private var listeners: [UUID: Listener] = [:]
    private var running = false

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedApp: AXUIElement?
    private var observedFocusedElement: AXUIElement?

    private var safetyPollTimer: Timer?
    private let safetyPollInterval: TimeInterval = 0.5

    private var fallbackEventTap: CFMachPort?
    private var fallbackRunLoopSource: CFRunLoopSource?
    private var fallbackBuffer = KeystrokeFallbackTextBuffer()

    private var pendingRefresh: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.02

    private var lastSnapshot: FocusedFieldSnapshot?

    public nonisolated init(
        reader: FocusedFieldReader = FocusedFieldReader(),
        permissionChecker: AccessibilityPermissionChecker = AccessibilityPermissionChecker(),
        webAppClassifier: AppBundleWebAppClassifier = .shared
    ) {
        self.reader = reader
        self.permissionChecker = permissionChecker
        self.webAppClassifier = webAppClassifier
        super.init()
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidLaunchApp(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        webAppClassifier.primeRunningApplications()
        retargetObserver()
        installFallbackKeyTap()
        scheduleSafetyPoll()
        refreshSoon()
    }

    public func stop() {
        guard running else { return }
        running = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        tearDownObserver()
        tearDownFallbackKeyTap()
        safetyPollTimer?.invalidate()
        safetyPollTimer = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        emit(nil)
    }

    deinit {
        // Tear-down must happen on the main actor; callers should call stop() explicitly.
        // We avoid touching state here on purpose; `NSWorkspace.notificationCenter` is safe to
        // remove from any thread.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Listeners

    @discardableResult
    public func addListener(_ listener: @escaping Listener) -> UUID {
        let token = UUID()
        listeners[token] = listener
        if let lastSnapshot { listener(lastSnapshot) }
        return token
    }

    public func removeListener(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    public var currentSnapshot: FocusedFieldSnapshot? { lastSnapshot }

    // MARK: - Workspace notifications

    @objc
    private func workspaceDidActivateApp(_ note: Notification) {
        Task { @MainActor [weak self] in
            self?.retargetObserver()
            self?.refreshSoon()
        }
    }

    @objc
    private func workspaceDidLaunchApp(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        webAppClassifier.noteLaunchedApplication(app)
    }

    // MARK: - AX observer

    private func retargetObserver() {
        guard permissionChecker.status() == .trusted else {
            tearDownObserver()
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let pid = frontApp?.processIdentifier else {
            tearDownObserver()
            return
        }

        if observedPID == pid, observer != nil {
            // Same app; re-resolve focused element only.
            refreshFocusedElementObservation()
            return
        }

        tearDownObserver()

        var newObserver: AXObserver?
        let status = AXObserverCreate(pid, AccessibilityContextTracker.observerCallback, &newObserver)
        guard status == .success, let createdObserver = newObserver else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // App-level notifications (focus/window changes always come through the app element).
        addNotification(kAXFocusedUIElementChangedNotification, on: appElement, observer: createdObserver)
        addNotification(kAXFocusedWindowChangedNotification, on: appElement, observer: createdObserver)
        addNotification(kAXWindowMiniaturizedNotification, on: appElement, observer: createdObserver)
        addNotification(kAXUIElementDestroyedNotification, on: appElement, observer: createdObserver)

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )

        observer = createdObserver
        observedPID = pid
        observedApp = appElement

        refreshFocusedElementObservation()
    }

    /// Subscribe to per-element notifications (selection/value) on whatever element currently
    /// has focus, so we get updates as the user types in the focused field.
    private func refreshFocusedElementObservation() {
        guard let observer else { return }

        let focused = systemFocusedElement()
        // Unhook any previous focused element first.
        if let previous = observedFocusedElement {
            removeNotification(kAXSelectedTextChangedNotification, on: previous, observer: observer)
            removeNotification(kAXValueChangedNotification, on: previous, observer: observer)
            removeNotification(kAXUIElementDestroyedNotification, on: previous, observer: observer)
        }
        observedFocusedElement = focused

        if let focused {
            addNotification(kAXSelectedTextChangedNotification, on: focused, observer: observer)
            addNotification(kAXValueChangedNotification, on: focused, observer: observer)
            addNotification(kAXUIElementDestroyedNotification, on: focused, observer: observer)
        }
    }

    private func tearDownObserver() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        observedPID = nil
        observedApp = nil
        observedFocusedElement = nil
    }

    private func addNotification(
        _ name: String,
        on element: AXUIElement,
        observer: AXObserver
    ) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, element, name as CFString, context)
    }

    private func removeNotification(
        _ name: String,
        on element: AXUIElement,
        observer: AXObserver
    ) {
        _ = AXObserverRemoveNotification(observer, element, name as CFString)
    }

    private static let observerCallback: AXObserverCallback = { _, _, name, refcon in
        guard let refcon else { return }
        let tracker = Unmanaged<AccessibilityContextTracker>.fromOpaque(refcon).takeUnretainedValue()
        let notification = name as String
        Task { @MainActor in
            tracker.handleNotification(notification)
        }
    }

    private func handleNotification(_ name: String) {
        if name == kAXFocusedUIElementChangedNotification
            || name == kAXFocusedWindowChangedNotification
            || name == kAXUIElementDestroyedNotification {
            refreshFocusedElementObservation()
        }
        refreshSoon()
    }

    // MARK: - Refresh pipeline

    private func refreshSoon() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func refreshNow() {
        guard running else { return }

        guard permissionChecker.status() == .trusted else {
            emit(nil)
            return
        }

        let snapshot: FocusedFieldSnapshot? = systemFocusedElement().flatMap(reader.snapshot(of:))
        if let fallback = fallbackSnapshot(replacing: snapshot) {
            emit(fallback)
            return
        }
        if snapshot.map({ !WeChatFallbackTextContext.isSparseSnapshot($0) }) ?? true {
            fallbackBuffer.reset()
        }
        emit(snapshot)
    }

    private func emit(_ snapshot: FocusedFieldSnapshot?) {
        lastSnapshot = snapshot
        for listener in listeners.values {
            listener(snapshot)
        }
    }

    // MARK: - Safety poll

    private func scheduleSafetyPoll() {
        safetyPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: safetyPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSoon()
            }
        }
        timer.tolerance = safetyPollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        safetyPollTimer = timer
    }

    // MARK: - WeChat keystroke fallback

    private func installFallbackKeyTap() {
        guard fallbackEventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tracker = Unmanaged<AccessibilityContextTracker>.fromOpaque(refcon).takeUnretainedValue()
                Task { @MainActor in
                    tracker.handleFallbackKeyEvent(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        fallbackEventTap = tap
        fallbackRunLoopSource = source
    }

    private func tearDownFallbackKeyTap() {
        if let fallbackEventTap {
            CGEvent.tapEnable(tap: fallbackEventTap, enable: false)
        }
        if let fallbackRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), fallbackRunLoopSource, .commonModes)
        }
        fallbackEventTap = nil
        fallbackRunLoopSource = nil
        fallbackBuffer.reset()
    }

    private func handleFallbackKeyEvent(type: CGEventType, event: CGEvent) {
        guard type == .keyDown else { return }
        // Don't fold KeyType's own synthesized insertion keystrokes into the fallback buffer; the real
        // field text already reflects them, so counting them too would double up. See ADR-039.
        guard event.getIntegerValueField(.eventSourceUserData) != SynthesizedEventMarker.userData else {
            return
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        guard !Self.isScreenCaptureShortcut(keyCode: keyCode, flags: flags) else {
            return
        }
        guard frontmostAppTarget().bundleIdentifier == WeChatFallbackTextContext.bundleIdentifier else {
            fallbackBuffer.reset()
            return
        }
        guard shouldUseWeChatFallbackNow() else {
            fallbackBuffer.reset()
            return
        }

        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            fallbackBuffer.reset()
            refreshSoon()
            return
        }

        switch keyCode {
        case 36, 53, 76, 123, 124, 125, 126:
            fallbackBuffer.reset()
            refreshSoon()
            return
        case 48:
            return
        case 51:
            fallbackBuffer.deleteBackward()
        default:
            if let text = unicodeString(from: event) {
                fallbackBuffer.append(text)
            }
        }

        if let fallback = fallbackSnapshot(replacing: nil) {
            emit(fallback)
        } else {
            refreshSoon()
        }
    }

    private func shouldUseWeChatFallbackNow() -> Bool {
        guard let snapshot = systemFocusedElement().flatMap(reader.snapshot(of:)) else {
            return true
        }
        if WeChatFallbackTextContext.isSparseSnapshot(snapshot) {
            return true
        }
        return false
    }

    private func fallbackSnapshot(replacing snapshot: FocusedFieldSnapshot?) -> FocusedFieldSnapshot? {
        let target = snapshot?.context.target ?? frontmostAppTarget()
        guard target.bundleIdentifier == WeChatFallbackTextContext.bundleIdentifier,
              WeChatFallbackTextContext.isSparseSnapshot(snapshot) || snapshot == nil,
              !fallbackBuffer.isEmpty else {
            return nil
        }
        return WeChatFallbackTextContext.snapshot(
            beforeCursor: fallbackBuffer.beforeCursor,
            target: target,
            windowFrame: focusedWindowFrame(for: target.bundleIdentifier)
        )
    }

    private func unicodeString(from event: CGEvent) -> String? {
        var chars = [UniChar](repeating: 0, count: 16)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: chars.count,
            actualStringLength: &length,
            unicodeString: &chars
        )
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private static func isScreenCaptureShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        ReservedSystemShortcut.isScreenCapture(
            keyCode: keyCode,
            shift: flags.contains(.maskShift),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            command: flags.contains(.maskCommand)
        )
    }

    // MARK: - Helpers

    private func systemFocusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focused as! AXUIElement)
    }

    private func frontmostAppTarget() -> AppTarget {
        let app = NSWorkspace.shared.frontmostApplication
        return AppTarget(
            bundleIdentifier: app?.bundleIdentifier ?? "unknown",
            appName: app?.localizedName ?? "Unknown"
        )
    }

    private func focusedWindowFrame(for bundleIdentifier: String) -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = AXCaretHelper.copyAttributeValue(kAXFocusedWindowAttribute as CFString, on: appElement),
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }
        let windowElement = unsafeBitCast(window, to: AXUIElement.self)
        guard let frame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: windowElement),
              !frame.isEmpty else {
            return nil
        }
        return AXCaretHelper.cocoaRect(fromAccessibilityRect: frame)
    }
}
