import AppCompatibility
import AppKit
import AutocompleteCore
import CompletionUI
import Foundation
import MacContextCapture
import Personalization
import TextInsertion
import os

@MainActor
final class CorrectionController {
    private let tracker: AccessibilityContextTracker
    private let settings: SettingsStore
    private let telemetry: CompletionTelemetryStore
    private let compatibilityStore: AppCompatibilityStore
    private let presenter: InlineGhostTextPresenter
    private let placementResolver: OverlayPlacementResolver
    private let rangeGeometryResolver: TextRangeGeometryResolver
    private let inserter: PasteboardCompletionInserter
    private let predictionLog = PredictionLog()
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "correction")

    private var listenerToken: UUID?
    private let detectionTasks = CompletionTaskRegistry()
    private var detectionTask: CompletionTaskRegistry.Handle?
    private var isShuttingDown = false
    private var lastContextKey: String?
    private var dismissedWordKey: String?
    private(set) var visibleCorrection: CorrectionCandidate?
    private var visibleContext: TextFieldContext?
    private var visibleWordRect: CGRect?
    /// In-memory post-acceptance reversion observer (issue #52). Aggregate outcomes only.
    private var acceptedInsertionTracker = AcceptedInsertionTracker()

    var validateWithModel: (([CorrectionCandidate], CorrectionTarget, TextFieldContext) async throws -> [CorrectionCandidate])?
    var onWillShowCorrection: ((TextFieldContext) -> Void)?
    var onCorrectionAccepted: (() -> Void)?

    init(
        tracker: AccessibilityContextTracker,
        settings: SettingsStore,
        telemetry: CompletionTelemetryStore,
        compatibilityStore: AppCompatibilityStore,
        presenter: InlineGhostTextPresenter = InlineGhostTextPresenter(),
        placementResolver: OverlayPlacementResolver? = nil,
        rangeGeometryResolver: TextRangeGeometryResolver? = nil,
        inserter: PasteboardCompletionInserter? = nil
    ) {
        self.tracker = tracker
        self.settings = settings
        self.telemetry = telemetry
        self.compatibilityStore = compatibilityStore
        self.presenter = presenter
        self.placementResolver = placementResolver ?? OverlayPlacementResolver(compatibilityStore: compatibilityStore)
        self.rangeGeometryResolver = rangeGeometryResolver ?? TextRangeGeometryResolver()
        self.inserter = inserter ?? PasteboardCompletionInserter(
            planner: InsertionPlanner(compatibilityStore: compatibilityStore)
        )
    }

    var hasVisibleCorrection: Bool {
        visibleCorrection != nil
    }

    func start() {
        guard !isShuttingDown, listenerToken == nil else { return }
        listenerToken = tracker.addListener { [weak self] snapshot in
            self?.handle(snapshot)
        }
    }

    func stop() {
        if let listenerToken {
            tracker.removeListener(listenerToken)
        }
        listenerToken = nil
        detectionTask?.cancel()
        detectionTask = nil
        acceptedInsertionTracker.cancel()
        clear()
    }

    /// Stop accepting snapshots and join every superseded detection task. A detection may be inside
    /// model validation even after cancellation, so completion's llama runtime must not be freed
    /// until this drain returns.
    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        stop()
        await detectionTasks.closeAndWait()
    }

    func shouldSuppressCompletion(for context: TextFieldContext) -> Bool {
        guard let visibleCorrection, let visibleContext else { return false }
        return visibleContext.target == context.target
            && visibleCorrection.originalRange.container == .beforeCursor
            && context.beforeCursor.hasPrefix(visibleContext.beforeCursor)
    }

    func canAcceptCorrection() -> Bool {
        visibleCorrection != nil && visibleContext != nil
    }

    func acceptCorrection() {
        guard let correction = visibleCorrection,
              let context = visibleContext,
              let plan = inserter.planCorrection(candidate: correction, context: context) else {
            telemetry.recordCorrectionReplacementFailure()
            clear()
            return
        }

        telemetry.recordCorrectionAccepted()
        beginAcceptedInsertionTracking(correction: correction, context: context)
        predictionLog.append(
            "CORRECT_ACCEPT \"\(PredictionLog.escape(correction.original))\" -> \"\(PredictionLog.escape(correction.replacement))\""
        )
        lastContextKey = nil
        onCorrectionAccepted?()
        clear()
        Task { [weak self] in
            do {
                try await self?.inserter.insert(plan: plan)
                try? await Task.sleep(nanoseconds: 80_000_000)
                await MainActor.run {
                    self?.tracker.requestRefresh()
                }
            } catch {
                await MainActor.run {
                    self?.telemetry.recordCorrectionReplacementFailure()
                    self?.log.error("Correction replacement failed: \(error, privacy: .public)")
                }
            }
        }
    }

    func dismissCorrection() {
        guard let correction = visibleCorrection, let context = visibleContext else { return }
        dismissedWordKey = Self.wordKey(correction: correction, context: context)
        telemetry.recordCorrectionDismissed()
        clear()
    }

    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        guard !isShuttingDown else { return }
        observeAcceptedInsertion(context: snapshot?.context)
        guard let snapshot else {
            clear()
            return
        }
        let context = snapshot.context
        let policy = compatibilityStore.policy(for: context)
        guard settings.autocorrectSuggestionsEnabled,
              settings.showSuggestedFixes,
              !settings.perAppCorrectionDisabled.contains(context.target.bundleIdentifier),
              !policy.autocorrectDisabled,
              !Self.isKeyTypeTarget(context.target),
              placementResolver.placement(for: context) != nil else {
            clear()
            return
        }

        let key = Self.contextKey(for: context)
        if key == lastContextKey { return }
        lastContextKey = key

        detectionTask?.cancel()
        detectionTask = detectionTasks.start { [weak self] in
            guard let self else { return }
            let started = DispatchTime.now()
            do {
                let detector = SystemSpellcheckCorrectionDetector()
                let grammarDetector = SystemGrammarCorrectionDetector()
                let detection = try await detector.detectCorrection(for: context)
                let rawCandidates: [CorrectionCandidate]
                let fallbackTarget: CorrectionTarget?
                if let detection {
                    let spellcheckCandidates = detection.candidates
                    let grammarAfterSpelling = spellcheckCandidates.flatMap {
                        grammarDetector.candidates(afterApplying: $0, in: context)
                    }
                    rawCandidates = grammarAfterSpelling + spellcheckCandidates
                    fallbackTarget = detection.target
                } else {
                    rawCandidates = grammarDetector.correctionCandidates(for: context)
                    fallbackTarget = nil
                }
                guard !rawCandidates.isEmpty else {
                    try Task.checkCancellation()
                    telemetry.recordCorrectionSuppressed(reason: "noCandidate")
                    clear()
                    return
                }
                telemetry.recordCorrectionDetected()
                let candidates: [CorrectionCandidate]
                if let validateWithModel {
                    candidates = try await validateCandidatesByRange(
                        rawCandidates,
                        fallbackTarget: fallbackTarget,
                        context: context,
                        validator: validateWithModel
                    )
                } else {
                    candidates = rawCandidates.filter { $0.source == .spellcheckOnly }
                }
                try Task.checkCancellation()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                telemetry.recordCorrectionValidationLatency(milliseconds: elapsed)
                present(candidates: candidates, target: fallbackTarget ?? Self.target(for: rawCandidates[0], context: context), context: context)
            } catch is CancellationError {
            } catch {
                log.error("Correction detection failed: \(error, privacy: .public)")
            }
        }
    }

    private func validateCandidatesByRange(
        _ candidates: [CorrectionCandidate],
        fallbackTarget: CorrectionTarget?,
        context: TextFieldContext,
        validator: ([CorrectionCandidate], CorrectionTarget, TextFieldContext) async throws -> [CorrectionCandidate]
    ) async throws -> [CorrectionCandidate] {
        let groups = Dictionary(grouping: candidates) { candidate in
            [
                candidate.originalRange.container.rawValue,
                String(candidate.originalRange.startOffset),
                String(candidate.originalRange.endOffset)
            ].joined(separator: ":")
        }
        var validated: [CorrectionCandidate] = []
        for group in groups.values {
            try Task.checkCancellation()
            guard let first = group.first else { continue }
            let target = fallbackTarget.flatMap { $0.range == first.originalRange ? $0 : nil }
                ?? Self.target(for: first, context: context)
            validated.append(contentsOf: try await validator(group, target, context))
        }
        return validated.sorted {
            if Self.correctionPriority($0) != Self.correctionPriority($1) {
                return Self.correctionPriority($0) > Self.correctionPriority($1)
            }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.replacement < $1.replacement
        }
    }

    private func present(candidates: [CorrectionCandidate], target: CorrectionTarget, context: TextFieldContext) {
        guard let best = candidates.first else {
            telemetry.recordCorrectionSuppressed(reason: "lowModelMargin")
            predictionLog.append("CORRECT word=\"\(PredictionLog.escape(target.original))\" -> SUPPRESS(lowModelMargin)")
            clear()
            return
        }
        guard best.confidence >= 0.76 else {
            telemetry.recordCorrectionSuppressed(reason: "lowSpellcheckConfidence")
            predictionLog.append("CORRECT word=\"\(PredictionLog.escape(best.original))\" -> SUPPRESS(lowSpellcheckConfidence)")
            clear()
            return
        }
        guard dismissedWordKey != Self.wordKey(correction: best, context: context) else {
            telemetry.recordCorrectionSuppressed(reason: "dismissedForWord")
            clear()
            return
        }
        let wordRect = rangeGeometryResolver.resolve(range: best.originalRange, context: context)?.rect
        if wordRect == nil, !Self.isNearCaret(best.originalRange, context: context) {
            telemetry.recordCorrectionSuppressed(reason: "noWordRect")
            clear()
            return
        }
        guard let placement = placementResolver.placement(for: context) else {
            telemetry.recordCorrectionSuppressed(reason: "noPlacement")
            clear()
            return
        }

        onWillShowCorrection?(context)
        visibleCorrection = best
        visibleContext = context
        visibleWordRect = wordRect
        telemetry.recordCorrectionShown()
        predictionLog.append(
            "CORRECT word=\"\(PredictionLog.escape(best.original))\" guess=\"\(PredictionLog.escape(best.replacement))\" -> SHOWN confidence=\(String(format: "%.2f", best.confidence)) source=\(best.source.rawValue)"
        )
        presenter.show(
            correction: best,
            placement: placement,
            style: FieldFontResolver.currentStyle().overlayTextStyle,
            wordRect: wordRect
        )
    }

    private func clear() {
        presenter.hide()
        visibleCorrection = nil
        visibleContext = nil
        visibleWordRect = nil
    }

    private func beginAcceptedInsertionTracking(correction: CorrectionCandidate, context: TextFieldContext) {
        if AcceptedInsertionTracker.isUnsafeToObserve(context) {
            observeAcceptedInsertion(context: context)
            acceptedInsertionTracker.cancel()
            return
        }
        guard let prefix = AcceptedInsertionTracker.prefixBeforeAccepted(for: correction, in: context),
              let expected = AcceptedInsertionTracker.expectedBeforeCursor(accepting: correction, in: context) else {
            // After-cursor / unobservable ranges: count as unobservable rather than guessing.
            telemetry.recordAcceptedInsertionOutcome(kind: .correction, outcome: .unobservable)
            return
        }
        let spec = AcceptedInsertionSpec(
            kind: .correction,
            acceptedText: correction.replacement,
            prefixBeforeAccepted: prefix,
            expectedBeforeCursor: expected,
            bundleIdentifier: context.target.bundleIdentifier
        )
        if let prior = acceptedInsertionTracker.begin(spec) {
            telemetry.recordAcceptedInsertionOutcome(kind: prior.kind, outcome: prior.outcome)
        }
    }

    private func observeAcceptedInsertion(context: TextFieldContext?) {
        if let resolution = acceptedInsertionTracker.observe(context: context) {
            telemetry.recordAcceptedInsertionOutcome(kind: resolution.kind, outcome: resolution.outcome)
        }
    }

    private static func contextKey(for context: TextFieldContext) -> String {
        [
            context.target.bundleIdentifier,
            context.target.domain ?? "",
            context.beforeCursor,
            context.afterCursor
        ].joined(separator: "\u{1E}")
    }

    private static func wordKey(correction: CorrectionCandidate, context: TextFieldContext) -> String {
        [
            context.target.bundleIdentifier,
            context.beforeCursor,
            correction.original,
            correction.replacement
        ].joined(separator: "\u{1E}")
    }

    private static func isKeyTypeTarget(_ target: AppTarget) -> Bool {
        target.bundleIdentifier == "com.pattonium.KeyType"
    }

    private static func target(for candidate: CorrectionCandidate, context: TextFieldContext) -> CorrectionTarget {
        switch candidate.originalRange.container {
        case .beforeCursor:
            let range = candidate.originalRange.range(in: context.beforeCursor)
            let prefix = range.map { String(context.beforeCursor[..<$0.lowerBound]) } ?? context.beforeCursor
            let suffix = range.map { String(context.beforeCursor[$0.upperBound...]) + context.afterCursor } ?? context.afterCursor
            return CorrectionTarget(
                original: candidate.original,
                range: candidate.originalRange,
                prefixBeforeWord: prefix,
                suffixAfterWord: suffix
            )
        case .afterCursor:
            let range = candidate.originalRange.range(in: context.afterCursor)
            let prefix = context.beforeCursor + (range.map { String(context.afterCursor[..<$0.lowerBound]) } ?? "")
            let suffix = range.map { String(context.afterCursor[$0.upperBound...]) } ?? context.afterCursor
            return CorrectionTarget(
                original: candidate.original,
                range: candidate.originalRange,
                prefixBeforeWord: prefix,
                suffixAfterWord: suffix
            )
        }
    }

    private static func correctionPriority(_ candidate: CorrectionCandidate) -> Int {
        switch candidate.source {
        case .spellcheckThenSystemGrammar: return 3
        case .spellcheckValidatedByModel, .priorPrediction: return 2
        case .systemGrammarValidatedByModel: return 1
        case .spellcheckOnly, .systemGrammarOnly: return 0
        }
    }

    private static func isNearCaret(_ range: TextRangeDescriptor, context: TextFieldContext) -> Bool {
        guard range.container == .beforeCursor else { return false }
        return max(0, context.beforeCursor.count - range.endOffset) <= 3
    }
}
