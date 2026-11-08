import Foundation

/// Whether the accepted insertion came from tab-completion or autocorrect.
public enum AcceptedInsertionKind: String, Equatable, Sendable {
    case completion
    case correction
}

/// Privacy-preserving classification of what happened to an accepted insertion during a short
/// in-memory observation window. Only the enum reaches persistent telemetry — never the text.
public enum AcceptedInsertionOutcome: String, Equatable, Sendable {
    /// Accepted text was still present when the window closed or the user continued past it.
    case retained
    /// Some, but not all, of the accepted span was deleted.
    case partiallyRemoved
    /// The accepted span was removed and the pre-accept prefix was restored.
    case fullyReverted
    /// The accepted region was overwritten with different content.
    case replaced
    /// The observation window ended without a decisive post-settle field update.
    case expired
    /// Focus/app/secure/sensitive conditions made the field unsafe or impossible to observe.
    case unobservable
}

/// In-memory description of one accepted insertion. Held only for the observation window; never
/// persisted, logged, or exported.
public struct AcceptedInsertionSpec: Equatable, Sendable {
    public var kind: AcceptedInsertionKind
    public var acceptedText: String
    /// `beforeCursor` immediately before the insertion was applied.
    public var prefixBeforeAccepted: String
    /// Expected `beforeCursor` once KeyType's insertion (and any backspace-after-paste workaround)
    /// has settled.
    public var expectedBeforeCursor: String
    public var bundleIdentifier: String
    public var observationWindow: TimeInterval
    /// Grace after first seeing the expected text so app-specific paste/backspace workarounds can
    /// finish before classification.
    public var synthesizedSettleGrace: TimeInterval

    public init(
        kind: AcceptedInsertionKind,
        acceptedText: String,
        prefixBeforeAccepted: String,
        expectedBeforeCursor: String,
        bundleIdentifier: String,
        observationWindow: TimeInterval = 5,
        synthesizedSettleGrace: TimeInterval = 0.15
    ) {
        self.kind = kind
        self.acceptedText = acceptedText
        self.prefixBeforeAccepted = prefixBeforeAccepted
        self.expectedBeforeCursor = expectedBeforeCursor
        self.bundleIdentifier = bundleIdentifier
        self.observationWindow = max(0.05, observationWindow)
        self.synthesizedSettleGrace = max(0, synthesizedSettleGrace)
    }
}

public struct AcceptedInsertionResolution: Equatable, Sendable {
    public var kind: AcceptedInsertionKind
    public var outcome: AcceptedInsertionOutcome

    public init(kind: AcceptedInsertionKind, outcome: AcceptedInsertionOutcome) {
        self.kind = kind
        self.outcome = outcome
    }
}

/// Pure state machine that watches one accepted insertion for immediate reversion/replacement.
///
/// Text for the accepted span is kept only in memory and discarded when the observation resolves.
/// Controllers feed focused-field updates; the machine emits at most one resolution per `begin`.
public struct AcceptedInsertionTracker: Equatable, Sendable {
    private struct Pending: Equatable, Sendable {
        var spec: AcceptedInsertionSpec
        var acceptedAt: Date
        var settledAt: Date?
        var lastBeforeCursor: String?
        /// True once we have observed the field after the synthesized-insertion grace period.
        var sawPostGraceUpdate: Bool = false
    }

    private var pending: Pending?

    public init() {}

    public var hasPendingObservation: Bool { pending != nil }

    /// Start watching a new acceptance. If a prior observation was still open, it is finalized as
    /// retained when it had settled (the user kept going, e.g. another Tab), otherwise unobservable.
    @discardableResult
    public mutating func begin(_ spec: AcceptedInsertionSpec, at now: Date = Date()) -> AcceptedInsertionResolution? {
        let prior = finalizeSuperseded(at: now)
        guard !spec.acceptedText.isEmpty else {
            pending = nil
            return prior
        }
        pending = Pending(spec: spec, acceptedAt: now, settledAt: nil, lastBeforeCursor: nil)
        return prior
    }

    /// Drop any pending observation without recording an outcome (shutdown / clear-all).
    public mutating func cancel() {
        pending = nil
    }

    /// Observe a focused-field update. Returns a resolution when the pending acceptance is closed.
    public mutating func observe(
        context: TextFieldContext?,
        at now: Date = Date()
    ) -> AcceptedInsertionResolution? {
        guard var current = pending else { return nil }

        if let timedOut = timeoutResolution(for: current, at: now) {
            pending = nil
            return timedOut
        }

        guard let context else {
            return resolve(.unobservable)
        }

        if Self.isUnsafeToObserve(context) {
            return resolve(.unobservable)
        }

        if context.target.bundleIdentifier != current.spec.bundleIdentifier {
            return resolve(.unobservable)
        }

        let before = context.beforeCursor
        current.lastBeforeCursor = before

        if current.settledAt == nil {
            if Self.looksSettled(before: before, spec: current.spec) {
                current.settledAt = now
                pending = current
            } else {
                pending = current
            }
            return nil
        }

        let settledAt = current.settledAt ?? now
        if now.timeIntervalSince(settledAt) < current.spec.synthesizedSettleGrace {
            pending = current
            return nil
        }

        current.sawPostGraceUpdate = true
        if Self.looksSettled(before: before, spec: current.spec)
            || before.hasPrefix(current.spec.expectedBeforeCursor)
            || before.hasPrefix(current.spec.prefixBeforeAccepted + current.spec.acceptedText) {
            // Still present (possibly with more typing after). Keep watching until timeout → retained.
            pending = current
            return nil
        }

        let outcome = Self.classify(liveBefore: before, spec: current.spec)
        return resolve(outcome)
    }

    // MARK: - Internals

    private mutating func resolve(_ outcome: AcceptedInsertionOutcome) -> AcceptedInsertionResolution? {
        guard let current = pending else { return nil }
        pending = nil
        return AcceptedInsertionResolution(kind: current.spec.kind, outcome: outcome)
    }

    private mutating func finalizeSuperseded(at now: Date) -> AcceptedInsertionResolution? {
        guard let current = pending else { return nil }
        pending = nil
        if current.settledAt != nil {
            return AcceptedInsertionResolution(kind: current.spec.kind, outcome: .retained)
        }
        if now.timeIntervalSince(current.acceptedAt) >= current.spec.observationWindow {
            return AcceptedInsertionResolution(kind: current.spec.kind, outcome: .expired)
        }
        return AcceptedInsertionResolution(kind: current.spec.kind, outcome: .unobservable)
    }

    private func timeoutResolution(for current: Pending, at now: Date) -> AcceptedInsertionResolution? {
        guard now.timeIntervalSince(current.acceptedAt) >= current.spec.observationWindow else {
            return nil
        }
        if current.settledAt == nil {
            return AcceptedInsertionResolution(kind: current.spec.kind, outcome: .unobservable)
        }
        // Settled, but no post-grace field update arrived before the window closed.
        if !current.sawPostGraceUpdate {
            return AcceptedInsertionResolution(kind: current.spec.kind, outcome: .expired)
        }
        if let before = current.lastBeforeCursor,
           Self.looksSettled(before: before, spec: current.spec)
            || before.hasPrefix(current.spec.prefixBeforeAccepted + current.spec.acceptedText) {
            return AcceptedInsertionResolution(kind: current.spec.kind, outcome: .retained)
        }
        return AcceptedInsertionResolution(kind: current.spec.kind, outcome: .expired)
    }

    static func isUnsafeToObserve(_ context: TextFieldContext) -> Bool {
        context.traits.isSecureTextEntry
            || context.traits.isPasswordField
            || context.traits.isPasswordManagerContext
    }

    static func looksSettled(before: String, spec: AcceptedInsertionSpec) -> Bool {
        before == spec.expectedBeforeCursor
            || before.hasPrefix(spec.expectedBeforeCursor)
            || before.hasPrefix(spec.prefixBeforeAccepted + spec.acceptedText)
    }

    static func classify(liveBefore: String, spec: AcceptedInsertionSpec) -> AcceptedInsertionOutcome {
        let prefix = spec.prefixBeforeAccepted
        let accepted = spec.acceptedText

        if liveBefore == spec.expectedBeforeCursor
            || liveBefore.hasPrefix(spec.expectedBeforeCursor)
            || liveBefore.hasPrefix(prefix + accepted) {
            return .retained
        }

        if liveBefore == prefix || (prefix.hasPrefix(liveBefore) && liveBefore.count <= prefix.count) {
            return .fullyReverted
        }

        guard liveBefore.hasPrefix(prefix) else {
            return .replaced
        }

        let remainder = String(liveBefore.dropFirst(prefix.count))
        if remainder.isEmpty {
            return .fullyReverted
        }

        if remainder.hasPrefix(accepted) {
            return .retained
        }

        let common = remainder.commonPrefix(with: accepted)
        if common.isEmpty {
            return .replaced
        }

        if accepted.hasPrefix(remainder) {
            return .partiallyRemoved
        }

        // e.g. accepted "hello", remainder "helX…" — overwritten after a partial match.
        if remainder.hasPrefix(common), common.count < accepted.count {
            let liveTail = String(remainder.dropFirst(common.count))
            if liveTail.isEmpty {
                return .partiallyRemoved
            }
            return .replaced
        }

        return .replaced
    }

    /// Expected `beforeCursor` after a completion insertion at the caret.
    public static func expectedBeforeCursor(
        accepting acceptedText: String,
        in context: TextFieldContext
    ) -> String {
        context.beforeCursor + acceptedText
    }

    /// Expected `beforeCursor` after a before-cursor correction replacement. Returns `nil` when the
    /// correction range is not observable via `beforeCursor` alone.
    public static func expectedBeforeCursor(
        accepting correction: CorrectionCandidate,
        in context: TextFieldContext
    ) -> String? {
        guard correction.originalRange.container == .beforeCursor,
              let range = correction.originalRange.range(in: context.beforeCursor) else {
            return nil
        }
        let prefix = String(context.beforeCursor[..<range.lowerBound])
        let suffix = String(context.beforeCursor[range.upperBound...])
        return prefix + correction.replacement + suffix
    }

    public static func prefixBeforeAccepted(
        for correction: CorrectionCandidate,
        in context: TextFieldContext
    ) -> String? {
        guard correction.originalRange.container == .beforeCursor,
              let range = correction.originalRange.range(in: context.beforeCursor) else {
            return nil
        }
        return String(context.beforeCursor[..<range.lowerBound])
    }
}
