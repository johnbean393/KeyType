//
//  CompletionController.swift
//  KeyType
//
//  Orchestrates the live completion pipeline (M6): focused-field snapshots → prompt → constrained
//  generation → candidate filtering → inline ghost-text overlay, plus Tab/Shift+Tab acceptance via
//  TextInsertion. Generation runs off the main actor (the runtime is an actor) and is cancelled by
//  the next keystroke. See ADR-016.
//

import AppCompatibility
import AppKit
import AutocompleteCore
import CompletionUI
import ConstrainedGeneration
import Foundation
import LlamaModelRuntime
import MacContextCapture
import ModelManagement
import ModelRuntime
import Observation
import Personalization
import Prompting
import TextInsertion
import TokenProfiles
import os

enum CompletionTextMutation: Equatable {
    case inserted(String)
    case deleteBackward
    case deleteForward
    case nonText
}

private final class CompletionLatencyTrace: @unchecked Sendable {
    private static let signpostLog = OSLog(
        subsystem: "com.pattonium.KeyType",
        category: "completion-latency"
    )

    /// Outcome string passed to `finish(outcome:)` when a completion was actually painted on screen.
    /// Kept in one place so `present(...)` and the telemetry-write decision in `finish` can't drift.
    static let shownOutcome = "shown"

    private let id: OSSignpostID
    private let startedAt: DispatchTime
    private let telemetry: CompletionTelemetryStore
    private let lock = NSLock()
    private var didFinish = false
    private var promptBuiltAt: DispatchTime?
    private var debounceScheduledAt: DispatchTime?
    private var debounceElapsedAt: DispatchTime?
    private var generationBeganAt: DispatchTime?
    private var generationEndedAt: DispatchTime?
    private var presentBeganAt: DispatchTime?

    init(context: TextFieldContext, telemetry: CompletionTelemetryStore) {
        id = OSSignpostID(log: Self.signpostLog)
        startedAt = DispatchTime.now()
        self.telemetry = telemetry
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "CompletionE2E",
            signpostID: id,
            "bundle=%{public}@ before_chars=%d after_chars=%d",
            context.target.bundleIdentifier as NSString,
            context.beforeCursor.count,
            context.afterCursor.count
        )
        eventAXSnapshot()
    }

    func eventAXSnapshot() {
        event("AXSnapshot")
    }

    func eventPromptBuilt(
        estimatedTokens: Int,
        sideContextReused: Bool,
        requiredPrefixBytes: Int,
        maxCompletionTokens: Int
    ) {
        guard canEmit else { return }
        promptBuiltAt = DispatchTime.now()
        os_signpost(
            .event,
            log: Self.signpostLog,
            name: "PromptBuilt",
            signpostID: id,
            "estimated_tokens=%d side_reused=%d required_prefix_bytes=%d max_completion_tokens=%d",
            estimatedTokens,
            sideContextReused ? 1 : 0,
            requiredPrefixBytes,
            maxCompletionTokens
        )
    }

    func eventWarmupScheduled() {
        event("AnchorWarmupScheduled")
    }

    func eventDebounceScheduled(nanoseconds: UInt64) {
        guard canEmit else { return }
        debounceScheduledAt = DispatchTime.now()
        os_signpost(
            .event,
            log: Self.signpostLog,
            name: "DebounceScheduled",
            signpostID: id,
            "delay_ms=%.2f",
            Double(nanoseconds) / 1_000_000.0
        )
    }

    func eventDebounceElapsed() {
        guard canEmit else { return }
        debounceElapsedAt = DispatchTime.now()
        event("DebounceElapsed")
    }

    func eventGenerationBegin() {
        guard canEmit else { return }
        generationBeganAt = DispatchTime.now()
        event("GenerationBegin")
    }

    func eventGenerationEnd(elapsedMs: Double, candidateCount: Int) {
        guard canEmit else { return }
        generationEndedAt = DispatchTime.now()
        os_signpost(
            .event,
            log: Self.signpostLog,
            name: "GenerationEnd",
            signpostID: id,
            "elapsed_ms=%.2f candidate_count=%d",
            elapsedMs,
            candidateCount
        )
    }

    func eventPresentBegin() {
        guard canEmit else { return }
        presentBeganAt = DispatchTime.now()
        event("PresentBegin")
    }

    func finish(outcome: String) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let promptBuiltAt = self.promptBuiltAt
        let debounceScheduledAt = self.debounceScheduledAt
        let debounceElapsedAt = self.debounceElapsedAt
        let generationBeganAt = self.generationBeganAt
        let generationEndedAt = self.generationEndedAt
        let presentBeganAt = self.presentBeganAt
        lock.unlock()

        let finishedAt = DispatchTime.now()
        let totalMillis = Self.millis(from: startedAt, to: finishedAt)
        os_signpost(
            .end,
            log: Self.signpostLog,
            name: "CompletionE2E",
            signpostID: id,
            "outcome=%{public}@ elapsed_ms=%.2f",
            outcome as NSString,
            totalMillis
        )

        // Only completions that were actually painted contribute to the visible-latency rollup. The
        // suppressed / cancelled / superseded paths are tracked separately by `suppressionReasons`
        // and aren't part of the user-perceived latency the Statistics pane reports.
        guard outcome == Self.shownOutcome,
              let promptBuiltAt,
              let debounceScheduledAt,
              let debounceElapsedAt,
              let generationBeganAt,
              let generationEndedAt,
              let presentBeganAt
        else { return }

        let sample = CompletionLatencySample(
            totalMillis: totalMillis,
            promptBuildMillis: Self.millis(from: startedAt, to: promptBuiltAt),
            debounceMillis: Self.millis(from: debounceScheduledAt, to: debounceElapsedAt),
            generationMillis: Self.millis(from: generationBeganAt, to: generationEndedAt),
            presentMillis: Self.millis(from: presentBeganAt, to: finishedAt)
        )
        telemetry.recordEndToEndSample(sample)
    }

    private var canEmit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !didFinish
    }

    private func event(_ name: StaticString) {
        guard canEmit else { return }
        os_signpost(.event, log: Self.signpostLog, name: name, signpostID: id)
    }

    private static func millis(from start: DispatchTime, to end: DispatchTime) -> Double {
        let delta = end.uptimeNanoseconds &- start.uptimeNanoseconds
        return Double(delta) / 1_000_000.0
    }
}

@MainActor
@Observable
final class CompletionController {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case unavailable(String)
    }

    private let tracker: AccessibilityContextTracker
    private let compatibilityStore: AppCompatibilityStore
    private let settings: SettingsStore
    private let history: WritingHistoryStoring
    private let screenTextProvider: ScreenTextProviding
    private let telemetry: CompletionTelemetryStore
    private let presenter: InlineGhostTextPresenter
    private let placementResolver: OverlayPlacementResolver
    private let inserter: PasteboardCompletionInserter
    private let filter: DefaultCandidateFilter
    private let predictionLog = PredictionLog()
    private let fullPromptLog = FullPromptLog()
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "completion")

    private var engine: ConstrainedGenerationEngine?
    private var generationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var listenerToken: UUID?
    private var activeLatencyTrace: CompletionLatencyTrace?
    private var fullPromptDebugByKey: [String: FullPromptDebugInfo] = [:]
    private var fullPromptDebugOrder: [String] = []
    /// Content signature of the last snapshot we acted on, so re-emitted snapshots whose text is
    /// unchanged (caret-geometry repolls) don't tear down and rebuild the overlay — that churn is
    /// what makes the ghost text flash.
    private var lastContextKey: String?
    /// Caret rect of the last snapshot we rendered the overlay against. Scrolling moves the caret on
    /// screen without changing the field text, so a same-text re-emit must re-pin the ghost text to
    /// the new caret position (auto-realign) instead of leaving it stranded where it was.
    private var lastCaretRect: CGRect?

    private(set) var loadState: LoadState = .idle
    private(set) var isRunning = false

    /// The model filename the current engine was (or is being) built from. Used to coalesce
    /// redundant `reloadModel()` calls — e.g. when a freshly downloaded model is auto-selected,
    /// `onModelReady` reloads explicitly *and* the Settings picker's `onChange` fires for the same
    /// programmatic selection. Set synchronously on the main actor before each load suspends, so the
    /// second call sees the target already active and no-ops.
    private var activeModelFilename: String?

    /// The completion currently shown as ghost text (the portion still ahead of the live caret).
    /// Nil when nothing is displayed. Exposed for the Tab acceptance controller / UI binding.
    private(set) var visibleCandidate: CompletionCandidate?

    /// The *anchor* of the live suggestion: the caret-reconciled completion text exactly as the
    /// model produced it for `anchorContext`. The text actually shown/inserted is re-derived from
    /// this against the *live* caret every keystroke (`liveCompletion(for:)`) — as the user types
    /// the suggested characters it shrinks, and when they diverge it is dropped. This is what keeps
    /// the overlay from going stale (and prevents the doubled-character bug where a suggestion
    /// generated for "…more " was inserted verbatim after the user had already typed "…more e").
    private var anchorText: String?
    private var anchorContext: TextFieldContext?
    /// Reconciled, filter-approved candidate anchors from recent generations. Used to keep a
    /// lower-ranked branch alive when the user types into it, and to recover prior winning anchors
    /// after a small rollback such as deleting a typo. Bounded and string-only: no logits, KV state,
    /// or model branch memory are retained.
    private var reuseHistory = CompletionReuseHistory()
    /// The most recent focused-field context seen — the live caret the suggestion is reconciled to.
    private var latestContext: TextFieldContext?
    private var frozenSideContext: FrozenPromptSideContext?
    private var lastGenerationLatencyMs: Double?
    /// Set when the user accepts a word with Tab: keep the *rest* of the same suggestion in place and
    /// do not regenerate, so repeated Tab presses walk through the remaining words of that one
    /// completion. Cleared once the suggestion is exhausted, the user diverges, or the overlay is torn
    /// down — at which point normal per-keystroke generation resumes.
    private var holdAnchor = false
    /// Set after a macOS screenshot/screen-recording shortcut. While active, the already-visible
    /// overlay is preserved through transient capture focus changes, but acceptance is disabled until
    /// a real non-Screenshot focused-field snapshot revalidates the text/caret context.
    private var screenCaptureHold: ScreenCaptureHold?

    private struct ScreenCaptureHold {
        var originalBundleIdentifier: String?
    }

    var completionsEnabled = true {
        didSet {
            if !completionsEnabled { reset() }
        }
    }

    nonisolated static let fastDebounceNanoseconds: UInt64 = 35_000_000
    nonisolated static let moderateDebounceNanoseconds: UInt64 = 50_000_000
    nonisolated static let conservativeDebounceNanoseconds: UInt64 = 90_000_000
    private static let sideContextFreezeInterval: TimeInterval = 2.0
    private static let screenCaptureBundleIdentifiers: Set<String> = [
        "com.apple.screenshot.launcher"
    ]

    private struct FrozenPromptSideContext {
        var fieldKey: String
        var historyEnabled: Bool
        var clipboardEnabled: Bool
        var ocrEnabled: Bool
        var previousUserInputs: [String]
        var pasteboardText: String?
        var screenText: String?
        var lastUsedAt: Date

        func canReuse(
            fieldKey: String,
            historyEnabled: Bool,
            clipboardEnabled: Bool,
            ocrEnabled: Bool,
            now: Date
        ) -> Bool {
            self.fieldKey == fieldKey
                && self.historyEnabled == historyEnabled
                && self.clipboardEnabled == clipboardEnabled
                && self.ocrEnabled == ocrEnabled
                && now.timeIntervalSince(lastUsedAt) <= CompletionController.sideContextFreezeInterval
        }
    }

    init(
        tracker: AccessibilityContextTracker,
        settings: SettingsStore,
        history: WritingHistoryStoring = NullWritingHistoryStore(),
        screenTextProvider: ScreenTextProviding = NullScreenTextProvider(),
        telemetry: CompletionTelemetryStore = CompletionTelemetryStore(url: nil),
        compatibilityStore: AppCompatibilityStore = KeyTypeModuleGraph.makeCompatibilityStore()
    ) {
        self.tracker = tracker
        self.settings = settings
        self.history = history
        self.screenTextProvider = screenTextProvider
        self.telemetry = telemetry
        self.compatibilityStore = compatibilityStore
        self.presenter = InlineGhostTextPresenter()
        self.placementResolver = OverlayPlacementResolver(compatibilityStore: compatibilityStore)
        self.inserter = PasteboardCompletionInserter(
            planner: InsertionPlanner(compatibilityStore: compatibilityStore)
        )
        // The in-beam guard (ADR-015) remains the primary typo defence, but it judges *healed,
        // pre-reconciliation* token paths — not the finalised string that is actually shown. Wiring
        // the synchronous recogniser into the output filter adds a cheap deterministic re-check of
        // the candidate as displayed (defense-in-depth on the real output). The check only runs on a
        // *closed* current word and is conservative, so it can't false-positive. See ADR-024.
        self.filter = DefaultCandidateFilter(
            compatibilityStore: compatibilityStore,
            wordRecognizer: SystemWordRecognizer()
        )
    }

    // MARK: - Lifecycle

    /// Load the model + profile + engine once, off the main actor. Safe to call repeatedly.
    func loadIfNeeded() {
        guard loadState == .idle else { return }
        loadState = .loading
        // Tune the decoder from accumulated local telemetry (bounded nudges) and honor the chosen
        // model. Both are read now, on the main actor, before suspending into the off-main load.
        let adjustments = ThresholdTuner.adjustments(for: telemetry.snapshot())
        let modelFilename = settings.selectedModelFilename ?? ModelContainer.defaultModelFilename
        activeModelFilename = modelFilename
        Task {
            do {
                let engine = try await Self.buildEngine(
                    compatibilityStore: compatibilityStore,
                    modelFilename: modelFilename,
                    adjustments: adjustments
                )
                self.engine = engine
                self.loadState = .ready
                self.startStartupWarmup(engine: engine)
                self.log.info("Completion engine ready")
            } catch {
                self.loadState = .unavailable("\(error)")
                self.log.error("Completion engine unavailable: \(error, privacy: .public)")
            }
        }
    }

    /// Tear down the current engine and reload from the currently selected model. Used after the
    /// user downloads/selects a different model so the change takes effect without relaunching.
    /// No-ops when the selected model is already the one loaded (or mid-load), so duplicate triggers
    /// (the post-download auto-select reloads *and* fires the picker's `onChange`) don't kick off two
    /// concurrent engine builds.
    func reloadModel() {
        let target = settings.selectedModelFilename ?? ModelContainer.defaultModelFilename
        guard target != activeModelFilename || loadState == .idle else { return }
        activeModelFilename = target
        reset()
        lastGenerationLatencyMs = nil
        Task {
            if let engine { await engine.shutdown() }
            engine = nil
            loadState = .idle
            loadIfNeeded()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        loadIfNeeded()
        listenerToken = tracker.addListener { [weak self] snapshot in
            self?.handle(snapshot)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let listenerToken {
            tracker.removeListener(listenerToken)
        }
        listenerToken = nil
        reset()
    }

    /// Release the model/GPU resources before the app exits. Must complete before the process
    /// terminates: llama.cpp's ggml-metal backend asserts (and aborts) during its process-teardown
    /// destructors if the context/model — and thus the GPU residency sets — were never freed. We
    /// stop the pipeline, cancel any in-flight generation, then free the engine's native resources
    /// and drop our reference so its `deinit` can't race the same teardown. See ADR-021.
    func shutdown() async {
        stop()
        warmupTask?.cancel()
        lastGenerationLatencyMs = nil
        loadState = .idle
        activeModelFilename = nil
        if let engine {
            await engine.shutdown()
        }
        engine = nil
    }

    // MARK: - Pipeline

    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        // Conditions under which there can be no suggestion: tear everything down and reset.
        guard completionsEnabled, loadState == .ready, let engine else { reset(); return }
        guard let snapshot else {
            if preserveScreenCaptureHoldForMissingSnapshot() { return }
            reset()
            return
        }
        if preserveScreenCaptureHold(for: snapshot.context) { return }
        guard let caretRect = snapshot.caretRect, !caretRect.isEmpty else {
            if preserveHeldCompletion(for: snapshot.context) { return }
            reset(keepingReuseHistory: true)
            return
        }

        let context = snapshot.context
        latestContext = context
        let policy = compatibilityStore.policy(for: context)
        guard policy.isCompletionEnabled,
              // Live per-app disable from Settings (reflects runtime toggles without rebuilding the
              // compatibility store). See ADR-023.
              !settings.perAppDisabled.contains(context.target.bundleIdentifier),
              policy.allowsMidLineCompletion || context.afterCursor.isEmpty,
              policy.allowsTabAcceptance
        else { reset(); return }

        // No usable prefix → don't generate (Cotypist's `emptyPrompt` gate). A base model given an
        // empty before-cursor just continues the prompt scaffolding (e.g. echoes section headers),
        // so there is nothing worth showing until the user has typed something at the caret.
        guard !context.beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { reset(); return }

        // Skip identical re-emits — keep whatever is on screen, no flicker. The one exception is a
        // moved caret with unchanged text (e.g. the user scrolled the field): re-pin the visible
        // suggestion to the new caret rather than leaving it stranded at the old screen position.
        let key = Self.contextKey(for: context)
        if key == lastContextKey {
            if visibleCandidate != nil, Self.caretMoved(from: lastCaretRect, to: caretRect) {
                lastCaretRect = caretRect
                renderSuggestion(for: context, style: FieldFontResolver.currentStyle())
            }
            return
        }
        lastContextKey = key
        lastCaretRect = caretRect

        guard placementResolver.placement(for: context) != nil else {
            if preserveHeldCompletion(for: context, contextKey: key) { return }
            reset(keepingReuseHistory: true)
            return
        }

        activeLatencyTrace?.finish(outcome: "superseded")
        let latencyTrace = CompletionLatencyTrace(context: context, telemetry: telemetry)
        activeLatencyTrace = latencyTrace

        // Resolve the field font and foreground color now, on the main actor, before suspending
        // into generation, so the ghost text matches the field's typeface and color.
        let style = FieldFontResolver.currentStyle()

        // Holding an accepted suggestion: while its remainder still applies to the live caret, keep it
        // on screen and skip regeneration so repeated Tab presses accept subsequent words of the SAME
        // completion (rather than producing a fresh one after each word). Once the remainder is
        // exhausted or the user diverges, fall through to a fresh generation below.
        //
        // This must run before reuse-history lookup: that path has a "remaining text must be at least
        // 3 characters" guard for speculative type-through, but word-by-word Tab acceptance must keep
        // valid short remainders such as "hi" or ".".
        if holdAnchor {
            if renderSuggestion(for: context, style: style, clearOnFailure: false) {
                finishLatencyTrace(latencyTrace, outcome: "held-anchor")
                return
            }
            holdAnchor = false
        }

        // The context just changed (the dedup above let us through), so the on-screen suggestion is
        // from the *previous* caret. Try to reuse a recently generated candidate set: if the user
        // typed into any still-compatible branch (including a lower-ranked one), or rolled back to a
        // prior anchor after deleting a typo, re-anchor it and skip this decode. Otherwise drop the
        // stale ghost and let a fresh generation run below.
        switch applyReuseHistoryIfUseful(for: context, style: style) {
        case .reused:
            finishLatencyTrace(latencyTrace, outcome: "reuse-history")
            return
        case .mustRecompute:
            break
        case .notApplicable:
            renderSuggestion(for: context, style: style)
        }

        // Token healing (ADR-019): when the caret sits mid-word, prompt from the last clean token
        // boundary and constrain regeneration to the already-typed bytes, so the model can reach
        // the natural whole-word token (" great") instead of being stuck in a subword state where a
        // worse word (" greasy") outranks it. The re-emitted stem is stripped before display in
        // `present`. When there is no heal the request is the plain whole-prefix continuation.
        let heal = MidWordHealing.plan(for: context)
        let promptContext = heal.map { context.replacingBeforeCursor($0.head) } ?? context
        // Personalization, clipboard, and screen/OCR are all opt-in. Once a typing burst starts, the
        // optional side sections are frozen briefly so unrelated history/clipboard/OCR updates do
        // not rewrite the prompt prefix and destroy KV append reuse mid-burst.
        let (sideContext, sideContextReused) = promptSideContext(for: promptContext)
        let promptResult = KeyTypeModuleGraph.makePromptBuilder().buildPrompt(
            context: promptContext,
            customInstructions: policy.customInstructions,
            previousUserInputs: sideContext.previousUserInputs,
            pasteboardText: sideContext.pasteboardText,
            screenText: sideContext.screenText,
            includeEnvironmentContext: policy.includesEnvironmentContext
        )
        let requiredPrefixBytes = heal.map { Array($0.heal.utf8) } ?? []
        // The re-emitted stem consumes part of the token/width budget, so widen both by the heal's
        // length to preserve the continuation's allowance.
        let healSlack = heal?.heal.count ?? 0
        // Completion length is user-configurable (Settings) and maps to the decoder's token/width
        // budget; token healing widens it at runtime as before.
        let length = settings.completionLength
        let request = CompletionRequest(
            context: context,
            prompt: promptResult.prompt,
            requiredPrefixBytes: requiredPrefixBytes,
            mode: policy.completionMode,
            maxCompletionTokens: length.maxCompletionTokens + (healSlack > 0 ? 2 : 0),
            maxDisplayWidth: length.maxDisplayWidth + healSlack
        )
        rememberFullPromptDebug(
            for: request,
            promptResult: promptResult,
            promptContext: promptContext,
            tokenHealing: heal.map { FullPromptTokenHealing(head: $0.head, heal: $0.heal) },
            sideContext: sideContext,
            sideContextReused: sideContextReused,
            policy: policy,
            completionLength: length,
            healSlack: healSlack
        )
        latencyTrace.eventPromptBuilt(
            estimatedTokens: promptResult.estimatedTokenCount,
            sideContextReused: sideContextReused,
            requiredPrefixBytes: requiredPrefixBytes.count,
            maxCompletionTokens: request.maxCompletionTokens
        )
        if !sideContextReused || lastGenerationLatencyMs == nil {
            latencyTrace.eventWarmupScheduled()
            startAnchorWarmup(engine: engine, request: request)
        }

        // Debounce: coalesce rapid keystrokes, and DON'T hide the current ghost up front — we
        // transition directly old → new (or → hidden) when generation finishes, so typing updates
        // the suggestion in place instead of blinking it out and back in.
        let debounceNanoseconds = Self.adaptiveDebounceNanoseconds(
            lastGenerationLatencyMs: lastGenerationLatencyMs
        )
        latencyTrace.eventDebounceScheduled(nanoseconds: debounceNanoseconds)
        generationTask?.cancel()
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            latencyTrace.eventDebounceElapsed()
            self.generationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    latencyTrace.eventGenerationBegin()
                    let start = DispatchTime.now()
                    let candidates = try await engine.completions(for: request)
                    try Task.checkCancellation()
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    latencyTrace.eventGenerationEnd(elapsedMs: elapsedMs, candidateCount: candidates.count)
                    self.lastGenerationLatencyMs = elapsedMs
                    self.telemetry.recordLatency(milliseconds: elapsedMs)
                    self.present(candidates, request: request, style: style, latencyTrace: latencyTrace)
                } catch is CancellationError {
                    // Superseded by a newer keystroke — leave the current ghost as-is.
                    self.finishLatencyTrace(latencyTrace, outcome: "cancelled")
                } catch {
                    self.log.error("Generation failed: \(error, privacy: .public)")
                    self.finishLatencyTrace(latencyTrace, outcome: "generation-error")
                }
            }
        }
    }

    private func present(
        _ candidates: [CompletionCandidate],
        request: CompletionRequest,
        style: ResolvedFieldStyle,
        latencyTrace: CompletionLatencyTrace?
    ) {
        latencyTrace?.eventPresentBegin()
        let ctx = PredictionLog.contextTail(request.context.beforeCursor)
        let ranked = candidates.prefix(5)
            .map { "\"\(PredictionLog.escape($0.text))\"" }
            .joined(separator: " | ")

        guard let best = candidates.first else {
            telemetry.recordSuppressed(reason: "noCandidate")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" → SUPPRESS(noCandidate)")
            appendFullPromptLog(
                request: request,
                candidates: candidates,
                outcome: "suppressed",
                shownText: nil,
                suppressionReason: "noCandidate"
            )
            clearCompletion()
            finishLatencyTrace(latencyTrace, outcome: "suppressed-no-candidate")
            return
        }
        if let reason = filter.suppressionReason(for: best, request: request) {
            telemetry.recordSuppressed(reason: String(describing: reason))
            log.debug("Suppressed: \(String(describing: reason), privacy: .public)")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SUPPRESS(\(reason))")
            appendFullPromptLog(
                request: request,
                candidates: candidates,
                outcome: "suppressed",
                shownText: nil,
                suppressionReason: String(describing: reason)
            )
            clearCompletion()
            finishLatencyTrace(latencyTrace, outcome: "suppressed-\(reason)")
            return
        }

        // When the prompt was healed (ADR-019), the completion re-emits the already-typed stem
        // (" great today."); strip it back off so only the genuinely new text ("at today.") remains.
        guard let anchored = anchorText(for: best, request: request, applyingFilter: false) else {
            telemetry.recordSuppressed(reason: "emptyAfterBoundary")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SUPPRESS(emptyAfterBoundary)")
            appendFullPromptLog(
                request: request,
                candidates: candidates,
                outcome: "suppressed",
                shownText: nil,
                suppressionReason: "emptyAfterBoundary"
            )
            clearCompletion()
            finishLatencyTrace(latencyTrace, outcome: "suppressed-empty-after-boundary")
            return
        }

        if let reuseSnapshot = makePromotionCache(from: candidates, request: request),
           let eviction = reuseHistory.record(reuseSnapshot) {
            predictionLog.append(
                "REUSE evict removed=\(eviction.removedEntries) remaining=\(eviction.remainingEntries)"
            )
        }
        anchorText = anchored
        anchorContext = request.context
        telemetry.recordShown()
        predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SHOWN \"\(PredictionLog.escape(anchored))\"")
        appendFullPromptLog(
            request: request,
            candidates: candidates,
            outcome: "shown",
            shownText: anchored,
            suppressionReason: nil
        )
        if !renderSuggestion(for: latestContext ?? request.context, style: style, clearOnFailure: false) {
            _ = renderSuggestion(for: request.context, style: style)
        }
        finishLatencyTrace(latencyTrace, outcome: CompletionLatencyTrace.shownOutcome)
    }

    private func appendFullPromptLog(
        request: CompletionRequest,
        candidates: [CompletionCandidate],
        outcome: String,
        shownText: String?,
        suppressionReason: String?
    ) {
        guard settings.fullPromptLoggingEnabled else { return }
        let candidateDiagnostics = candidates.enumerated().map { index, candidate in
            let reason = filter.suppressionReason(for: candidate, request: request)
            return FullPromptCandidateDiagnostic(
                rank: index,
                text: candidate.text,
                passesFilter: reason == nil,
                suppressionReason: reason.map { String(describing: $0) }
            )
        }
        fullPromptLog.append(
            request: request,
            candidates: candidates,
            outcome: outcome,
            shownText: shownText,
            suppressionReason: suppressionReason,
            generationLatencyMs: lastGenerationLatencyMs,
            candidateDiagnostics: candidateDiagnostics,
            debugInfo: takeFullPromptDebug(for: request)
        )
    }

    private func rememberFullPromptDebug(
        for request: CompletionRequest,
        promptResult: PromptBuildResult,
        promptContext: TextFieldContext,
        tokenHealing: FullPromptTokenHealing?,
        sideContext: FrozenPromptSideContext,
        sideContextReused: Bool,
        policy: CompletionPolicy,
        completionLength: CompletionLength,
        healSlack: Int
    ) {
        guard settings.fullPromptLoggingEnabled else { return }
        let key = Self.fullPromptDebugKey(for: request)
        let debug = FullPromptDebugInfo(
            promptEstimatedTokenCount: promptResult.estimatedTokenCount,
            promptSections: promptResult.sections.map(FullPromptSectionSnapshot.init),
            promptContext: FullPromptContext(promptContext),
            tokenHealing: tokenHealing,
            sideContext: FullPromptSideContextSnapshot(
                reused: sideContextReused,
                historyEnabled: sideContext.historyEnabled,
                clipboardEnabled: sideContext.clipboardEnabled,
                ocrEnabled: sideContext.ocrEnabled,
                previousUserInputs: sideContext.previousUserInputs,
                pasteboardText: sideContext.pasteboardText,
                screenText: sideContext.screenText
            ),
            settings: FullPromptSettingsSnapshot(
                completionLength: completionLength.rawValue,
                fullPromptLoggingEnabled: settings.fullPromptLoggingEnabled,
                perAppDisabledBundleIdentifiers: Array(settings.perAppDisabled).sorted()
            ),
            policy: FullPromptPolicySnapshot(policy),
            requestBudget: FullPromptRequestBudgetSnapshot(
                baseMaxCompletionTokens: completionLength.maxCompletionTokens,
                actualMaxCompletionTokens: request.maxCompletionTokens,
                baseMaxDisplayWidth: completionLength.maxDisplayWidth,
                actualMaxDisplayWidth: request.maxDisplayWidth,
                healSlackCharacters: healSlack,
                requiredPrefixByteCount: request.requiredPrefixBytes.count
            )
        )
        fullPromptDebugByKey[key] = debug
        fullPromptDebugOrder.append(key)
        if fullPromptDebugOrder.count > 16 {
            let removed = fullPromptDebugOrder.removeFirst()
            fullPromptDebugByKey.removeValue(forKey: removed)
        }
    }

    private func takeFullPromptDebug(for request: CompletionRequest) -> FullPromptDebugInfo? {
        let key = Self.fullPromptDebugKey(for: request)
        fullPromptDebugOrder.removeAll { $0 == key }
        return fullPromptDebugByKey.removeValue(forKey: key)
    }

    private func anchorText(
        for candidate: CompletionCandidate,
        request: CompletionRequest,
        applyingFilter: Bool
    ) -> String? {
        if applyingFilter, filter.suppressionReason(for: candidate, request: request) != nil {
            return nil
        }

        let completion = request.requiredPrefixBytes.isEmpty
            ? candidate.text
            : MidWordHealing.strip(candidate.text, heal: String(decoding: request.requiredPrefixBytes, as: UTF8.self))

        // Re-align the leading whitespace against the prefix this was generated for (ADR-017 /
        // CaretBoundary). This reconciled text is the suggestion *anchor*; what is actually shown and
        // inserted is re-derived from it against the live caret.
        var anchored = CaretBoundary.reconcile(completion, beforeCursor: request.context.beforeCursor)
        // Drop trailing whitespace for an end-of-line append: a dangling space renders as a phantom
        // gap in the ghost text and inserts a stray separator on accept. Mid-line keeps it — there the
        // trailing space may be the genuine separator before the existing after-cursor text. See ADR-024.
        if request.context.afterCursor.isEmpty {
            while let last = anchored.last, last.isWhitespace { anchored.removeLast() }
        }
        return anchored.isEmpty ? nil : anchored
    }

    private func makePromotionCache(
        from candidates: [CompletionCandidate],
        request: CompletionRequest
    ) -> CompletionPromotionCache? {
        var seen = Set<String>()
        var entries: [CompletionPromotionCache.Entry] = []
        entries.reserveCapacity(candidates.count)

        for (rank, candidate) in candidates.enumerated() {
            guard let anchored = anchorText(for: candidate, request: request, applyingFilter: true),
                  seen.insert(anchored).inserted
            else { continue }
            entries.append(
                CompletionPromotionCache.Entry(
                    anchorText: anchored,
                    sourceRank: rank,
                    logProbability: candidate.logProbability
                )
            )
        }

        guard !entries.isEmpty else { return nil }
        return CompletionPromotionCache(anchorContext: request.context, entries: entries)
    }

    nonisolated static func adaptiveDebounceNanoseconds(lastGenerationLatencyMs: Double?) -> UInt64 {
        guard let latency = lastGenerationLatencyMs else { return moderateDebounceNanoseconds }
        if latency <= 70 { return fastDebounceNanoseconds }
        if latency <= 140 { return moderateDebounceNanoseconds }
        return conservativeDebounceNanoseconds
    }

    private func promptSideContext(
        for context: TextFieldContext,
        now: Date = Date()
    ) -> (FrozenPromptSideContext, reused: Bool) {
        let fieldKey = Self.sideContextFieldKey(for: context)
        if var cached = frozenSideContext,
           cached.canReuse(
               fieldKey: fieldKey,
               historyEnabled: settings.historyEnabled,
               clipboardEnabled: settings.clipboardEnabled,
               ocrEnabled: settings.ocrEnabled,
               now: now
           ) {
            cached.lastUsedAt = now
            frozenSideContext = cached
            return (cached, true)
        }

        let query = WritingHistoryQuery(
            bundleIdentifier: context.target.bundleIdentifier,
            domain: context.target.domain,
            typingContext: context.typingContext,
            language: context.detectedLanguage
        )
        let previousUserInputs = settings.historyEnabled
            ? history.samples(for: query)
            : []
        let pasteboardText = settings.clipboardEnabled
            ? NSPasteboard.general.string(forType: .string)
            : nil
        let screenText = settings.ocrEnabled
            ? screenTextProvider.latestScreenText
            : nil

        let frozen = FrozenPromptSideContext(
            fieldKey: fieldKey,
            historyEnabled: settings.historyEnabled,
            clipboardEnabled: settings.clipboardEnabled,
            ocrEnabled: settings.ocrEnabled,
            previousUserInputs: previousUserInputs,
            pasteboardText: pasteboardText,
            screenText: screenText,
            lastUsedAt: now
        )
        frozenSideContext = frozen
        return (frozen, false)
    }

    private nonisolated static func sideContextFieldKey(for context: TextFieldContext) -> String {
        [
            context.target.bundleIdentifier,
            context.target.domain ?? "",
            context.target.windowTitle ?? "",
            context.placeholder ?? "",
            context.labels.joined(separator: "\u{1F}"),
            context.detectedLanguage ?? "",
            context.typingContext ?? ""
        ].joined(separator: "\u{1E}")
    }

    private func startStartupWarmup(engine: ConstrainedGenerationEngine) {
        warmupTask?.cancel()
        let context = TextFieldContext(
            beforeCursor: "The",
            target: AppTarget(bundleIdentifier: "com.pattonium.KeyType", appName: "KeyType"),
            detectedLanguage: "en"
        )
        let prompt = KeyTypeModuleGraph.makePromptBuilder().buildPrompt(context: context).prompt
        let request = CompletionRequest(
            context: context,
            prompt: prompt,
            mode: .prose,
            maxCompletionTokens: 1,
            maxDisplayWidth: 8
        )
        startWarmup(engine: engine, request: request)
    }

    private func startAnchorWarmup(engine: ConstrainedGenerationEngine, request: CompletionRequest) {
        startWarmup(engine: engine, request: request)
    }

    private func startWarmup(engine: ConstrainedGenerationEngine, request: CompletionRequest) {
        warmupTask?.cancel()
        warmupTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await engine.warmUp(for: request)
            } catch is CancellationError {
                // Superseded by a newer focus/typing context.
            } catch {
                self?.log.debug("Warmup failed: \(error, privacy: .public)")
            }
        }
    }

    private enum ReuseHistoryApplication {
        case reused
        case mustRecompute
        case notApplicable
    }

    @discardableResult
    private func applyReuseHistoryIfUseful(
        for live: TextFieldContext,
        style: ResolvedFieldStyle,
        updateLatestContext: Bool = false
    ) -> ReuseHistoryApplication {
        guard !reuseHistory.isEmpty else { return .notApplicable }

        switch reuseHistory.decision(for: live) {
        case let .reuse(reuse):
            anchorText = reuse.anchorText
            anchorContext = reuse.anchorContext
            if updateLatestContext { latestContext = live }
            guard renderSuggestion(for: live, style: style, clearOnFailure: false) else {
                clearCompletion()
                return .mustRecompute
            }
            predictionLog.append(
                "REUSE \(reuse.kind.rawValue) snapshot=\(reuse.snapshotID) rank=\(reuse.sourceRank) remaining=\"\(PredictionLog.escape(reuse.remainingText))\""
            )
            return .reused

        case .miss(_, .noTypedDelta):
            return .notApplicable

        case let .miss(kind, reason):
            predictionLog.append("REUSE miss kind=\(kind.rawValue) reason=\(reason.rawValue)")
            clearCompletion()
            return .mustRecompute
        }
    }

    /// Renders the anchored suggestion (if any) against `live`: shows the portion still ahead of the
    /// caret at the live placement, or clears everything when the user has typed past / diverged from
    /// it. The single place the overlay is shown, so display always matches the live caret.
    @discardableResult
    private func renderSuggestion(
        for live: TextFieldContext,
        style: ResolvedFieldStyle,
        clearOnFailure: Bool = true
    ) -> Bool {
        guard let shown = liveCompletion(for: live), !shown.isEmpty,
              var placement = placementResolver.placement(for: live) else {
            if clearOnFailure {
                clearCompletion()
            }
            return false
        }
        // Mid-line fill-in-the-middle completions overlap the existing suffix when drawn as inline
        // ghost text, so present them in a capsule below the caret instead. End-of-line and
        // end-of-paragraph (suffix begins on the next line) completions append cleanly, so they keep
        // the inline ghost-text form.
        if placement.mode == .inline, Self.shouldUseCapsule(for: live) {
            placement.presentation = .capsule
        }
        let candidate = CompletionCandidate(text: shown, mode: .prose)
        visibleCandidate = candidate
        predictionLog.append(
            "PLACE mode=\(placement.mode) cursor=\(PredictionLog.rect(placement.cursorRect)) field=\(placement.fieldRect.map(PredictionLog.rect) ?? "nil")"
        )
        let effectiveStyle = Self.effectiveOverlayStyle(style, for: live)
        presenter.show(candidate: candidate, placement: placement, font: effectiveStyle.font, textColor: effectiveStyle.color)
        return true
    }

    /// The portion of the anchored completion still ahead of the live caret, or `nil` when the
    /// suggestion no longer applies. Valid only while the user *extends* the anchor's prefix by
    /// typing the suggested characters: any deletion, caret jump, change to the text after the
    /// cursor, or a divergent keystroke invalidates it (returns `nil`).
    private func liveCompletion(for live: TextFieldContext) -> String? {
        guard let anchorText, let anchorContext else { return nil }
        return SuggestionAnchor.remaining(anchorText: anchorText, anchor: anchorContext, live: live)
    }

    private func preserveHeldCompletion(for context: TextFieldContext, contextKey: String? = nil) -> Bool {
        guard holdAnchor,
              let remaining = liveCompletion(for: context),
              !remaining.isEmpty
        else {
            return false
        }

        latestContext = context
        visibleCandidate = CompletionCandidate(text: remaining, mode: .prose)
        if let contextKey {
            lastContextKey = contextKey
            lastCaretRect = nil
        }
        return true
    }

    private func clearCompletion() {
        presenter.hide()
        visibleCandidate = nil
        anchorText = nil
        anchorContext = nil
        holdAnchor = false
        screenCaptureHold = nil
    }

    private func finishLatencyTrace(_ trace: CompletionLatencyTrace?, outcome: String) {
        trace?.finish(outcome: outcome)
        if let trace, activeLatencyTrace === trace {
            activeLatencyTrace = nil
        }
    }

    private func finishActiveLatencyTrace(outcome: String) {
        activeLatencyTrace?.finish(outcome: outcome)
        activeLatencyTrace = nil
    }

    /// Hide any ghost text and forget the last context, so the next snapshot is treated as new.
    private func reset(keepingReuseHistory: Bool = false) {
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "reset")
        lastContextKey = nil
        lastCaretRect = nil
        frozenSideContext = nil
        if !keepingReuseHistory {
            reuseHistory.removeAll()
        }
        clearCompletion()
    }

    private func preserveScreenCaptureHold(for context: TextFieldContext) -> Bool {
        guard screenCaptureHold != nil else { return false }
        guard visibleCandidate != nil else {
            screenCaptureHold = nil
            return false
        }
        if Self.isScreenCaptureBundleIdentifier(context.target.bundleIdentifier) {
            return true
        }
        // Any non-Screenshot text-field snapshot revalidates (or invalidates) the original context.
        // Let the normal pipeline handle it, with acceptance enabled again after this point.
        screenCaptureHold = nil
        return false
    }

    private func preserveScreenCaptureHoldForMissingSnapshot() -> Bool {
        guard let hold = screenCaptureHold else { return false }
        guard visibleCandidate != nil else {
            screenCaptureHold = nil
            return false
        }
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontmostBundleIdentifier,
           Self.isScreenCaptureBundleIdentifier(frontmostBundleIdentifier)
            || frontmostBundleIdentifier == hold.originalBundleIdentifier {
            return true
        }
        screenCaptureHold = nil
        return false
    }

    private static func isScreenCaptureBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        screenCaptureBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func contextKey(for context: TextFieldContext) -> String {
        context.beforeCursor + "\u{1}" + context.afterCursor + "\u{1}" + context.target.bundleIdentifier
    }

    private static func fullPromptDebugKey(for request: CompletionRequest) -> String {
        [
            request.prompt,
            contextKey(for: request.context),
            request.requiredPrefixBytes.map { String($0) }.joined(separator: ","),
            String(request.maxCompletionTokens),
            String(request.maxDisplayWidth)
        ].joined(separator: "\u{2}")
    }

    /// Whether the completion should render as a capsule below the caret rather than inline ghost
    /// text. True only when there is visible (non-whitespace) suffix text remaining on the *current*
    /// line — that's the case where inline ghost text would overlap the user's existing text. If the
    /// caret is at the end of the line, the document, or the end of a paragraph (the remainder of the
    /// line is empty/whitespace and the next character is a newline), inline ghost text appends
    /// cleanly with nothing to overlap, so we keep it.
    nonisolated static func shouldUseCapsule(for context: TextFieldContext) -> Bool {
        guard !context.geometry.isAtEndOfLine else { return false }
        let currentLineSuffix = context.afterCursor.prefix { !$0.isNewline }
        return currentLineSuffix.contains { !$0.isWhitespace }
    }

    nonisolated static func effectiveOverlayStyle(
        _ style: ResolvedFieldStyle,
        for context: TextFieldContext
    ) -> ResolvedFieldStyle {
        guard context.target.bundleIdentifier == "md.obsidian" else { return style }
        return ResolvedFieldStyle(font: nil, color: style.color)
    }

    /// Whether the caret has shifted enough to warrant re-pinning the overlay. A small epsilon
    /// absorbs sub-pixel AX jitter so steady-state repolls don't churn the window.
    private static func caretMoved(from old: CGRect?, to new: CGRect) -> Bool {
        guard let old else { return true }
        let epsilon: CGFloat = 0.5
        return abs(old.minX - new.minX) > epsilon
            || abs(old.minY - new.minY) > epsilon
            || abs(old.height - new.height) > epsilon
    }

    // MARK: - Acceptance (driven by the Tab hotkey)

    /// True when there is a visible completion the user is allowed to accept with Tab.
    var canAcceptCompletion: Bool {
        guard screenCaptureHold == nil else { return false }
        guard visibleCandidate != nil, let context = latestContext ?? anchorContext else { return false }
        return compatibilityStore.policy(for: context).allowsTabAcceptance
    }

    /// Called by the global key tap before passing macOS screenshot / screen-recording shortcuts
    /// through. The shortcut itself does not mutate the text field, so keep the current overlay in
    /// place for the capture. Acceptance stays disabled until a later focused-field snapshot proves
    /// the original context is active again.
    func prepareForScreenCaptureShortcut() {
        guard visibleCandidate != nil else { return }
        screenCaptureHold = ScreenCaptureHold(
            originalBundleIdentifier: (latestContext ?? anchorContext)?.target.bundleIdentifier
        )
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "screen-capture-hold")
    }

    /// Synchronously dismiss the on-screen suggestion when a just-pressed key makes it stale, *before*
    /// the AX `value-changed` snapshot for that keystroke arrives. Driven by the global key tap, which
    /// sees every key-down immediately; the AX pipeline that would otherwise clear a diverged
    /// suggestion lags behind by the debounce plus the app's notification latency, so without this the
    /// outdated ghost text visibly lingers for a beat after each key. See ADR-037.
    ///
    /// `mutation` describes the key's expected text effect. When the user is typing into any cached
    /// branch, the branch is promoted immediately and normal generation is skipped until the cache no
    /// longer has a substantial matching remainder. A plain backward delete can also recover an older
    /// cached anchor after a typo rollback. Anything else clears now and abandons in-flight generation,
    /// so a result returning for the previous caret can't re-show a stale suggestion.
    func dismissStaleCompletion(mutation: CompletionTextMutation) {
        guard let shown = visibleCandidate?.text, !shown.isEmpty else { return }
        switch mutation {
        case let .inserted(typed) where !typed.isEmpty:
            let historyWasAvailable = !reuseHistory.isEmpty
            if reuseCachedCompletion(typedCharacters: typed) { return }
            // Compatibility fallback for states created before a candidate-set cache exists.
            if !historyWasAvailable, shown.hasPrefix(typed), advanceTypeThrough(typedCharacters: typed) {
                return
            }

        case .deleteBackward:
            if recoverCachedCompletionAfterDeleteBackward() { return }

        case .deleteForward, .nonText, .inserted:
            break
        }

        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "stale-completion-dismissed")
        clearCompletion()
    }

    /// Backwards-compatible wrapper for older tests/call sites that only classify inserted text.
    func dismissStaleCompletion(typedCharacters typed: String?) {
        dismissStaleCompletion(mutation: typed.map(CompletionTextMutation.inserted) ?? .nonText)
    }

    private func reuseCachedCompletion(typedCharacters typed: String) -> Bool {
        guard !typed.isEmpty,
              let live = latestContext ?? anchorContext
        else { return false }
        let optimistic = live.replacingBeforeCursor(live.beforeCursor + typed)
        return reuseCachedCompletion(for: optimistic, kind: .append, immediateAcceptedHead: typed)
    }

    private func recoverCachedCompletionAfterDeleteBackward() -> Bool {
        guard let live = latestContext ?? anchorContext,
              !live.beforeCursor.isEmpty,
              (live.selection.selectedText ?? "").isEmpty
        else { return false }
        let optimistic = live.replacingBeforeCursor(String(live.beforeCursor.dropLast()))
        guard !reuseHistory.isEmpty else { return false }
        return applyCachedReuse(
            reuseHistory.decisionAfterDeleteBackward(for: optimistic),
            optimistic: optimistic,
            immediateAcceptedHead: nil
        )
    }

    private func reuseCachedCompletion(
        for optimistic: TextFieldContext,
        kind: CompletionReuseHistory.ReuseKind,
        immediateAcceptedHead: String?
    ) -> Bool {
        guard !reuseHistory.isEmpty else { return false }
        return applyCachedReuse(
            reuseHistory.decision(for: optimistic, preferredKind: kind),
            optimistic: optimistic,
            immediateAcceptedHead: immediateAcceptedHead
        )
    }

    private func applyCachedReuse(
        _ decision: CompletionReuseHistory.Decision,
        optimistic: TextFieldContext,
        immediateAcceptedHead: String?
    ) -> Bool {
        switch decision {
        case let .reuse(reuse):
            anchorText = reuse.anchorText
            anchorContext = reuse.anchorContext
            latestContext = optimistic
            let remainder = CompletionCandidate(text: reuse.remainingText, mode: .prose)
            visibleCandidate = remainder
            if let immediateAcceptedHead {
                presenter.advanceAfterAccepting(head: immediateAcceptedHead, remainder: remainder)
            }
            predictionLog.append(
                "REUSE \(reuse.kind.rawValue) snapshot=\(reuse.snapshotID) rank=\(reuse.sourceRank) remaining=\"\(PredictionLog.escape(reuse.remainingText))\""
            )
            debounceTask?.cancel()
            generationTask?.cancel()
            warmupTask?.cancel()
            finishActiveLatencyTrace(outcome: "cached-reuse")
            holdAnchor = false
            return true

        case .miss(_, .noTypedDelta):
            return false

        case let .miss(kind, reason):
            predictionLog.append("REUSE miss kind=\(kind.rawValue) reason=\(reason.rawValue)")
            return false
        }
    }

    /// The user typed the next visible ghost characters. AX will eventually report the real field
    /// state, but until then acceptance must see the optimistic caret so a rapid Tab does not insert
    /// characters the user already typed. Used only as a compatibility fallback when no candidate-set
    /// cache is available.
    private func advanceTypeThrough(typedCharacters typed: String) -> Bool {
        guard let live = latestContext ?? anchorContext,
              let anchorText,
              let anchorContext,
              let advanced = Self.typeThroughAdvance(
                  anchorText: anchorText,
                  anchorContext: anchorContext,
                  liveContext: live,
                  typedCharacters: typed
              ) else {
            return false
        }

        latestContext = advanced.context
        if advanced.remainingText.isEmpty {
            clearCompletion()
        } else {
            let remainder = CompletionCandidate(text: advanced.remainingText, mode: .prose)
            visibleCandidate = remainder
            presenter.advanceAfterAccepting(head: typed, remainder: remainder)
        }
        return true
    }

    nonisolated static func typeThroughAdvance(
        anchorText: String,
        anchorContext: TextFieldContext,
        liveContext: TextFieldContext,
        typedCharacters typed: String
    ) -> (context: TextFieldContext, remainingText: String)? {
        guard !typed.isEmpty,
              let current = SuggestionAnchor.remaining(
                  anchorText: anchorText,
                  anchor: anchorContext,
                  live: liveContext
              ),
              current.hasPrefix(typed) else {
            return nil
        }

        let optimistic = liveContext.replacingBeforeCursor(liveContext.beforeCursor + typed)
        guard let remaining = SuggestionAnchor.remaining(
            anchorText: anchorText,
            anchor: anchorContext,
            live: optimistic
        ) else {
            return nil
        }
        return (optimistic, remaining)
    }

    /// Tab: insert the next word of the suggestion and keep the *rest* of the same completion in place
    /// so the user can keep pressing Tab to accept subsequent words. We do **not** regenerate: the
    /// anchor stays put, the insertion-induced snapshot re-derives the shrinking remainder, and
    /// `holdAnchor` suppresses a fresh generation until the suggestion is exhausted or the user
    /// diverges. The live caret is advanced optimistically by the inserted word so a rapid second Tab
    /// accepts the *next* word instead of re-inserting this one before the AX snapshot lands.
    func acceptNextWord() {
        guard canAcceptCompletion, let (text, context) = insertionText() else { return }
        let (head, rest) = NextWordSplitter.split(text)
        guard !head.isEmpty else { return }
        telemetry.recordAccepted()
        predictionLog.append(
            "ACCEPT(word) \"\(PredictionLog.escape(head))\" of \"\(PredictionLog.escape(text))\""
        )

        holdAnchor = true
        if rest.isEmpty {
            reuseHistory.removeAll()
        }
        // Cancel any in-flight generation so it can't clobber the held suggestion when it returns.
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "accepted-word")
        latestContext = context.replacingBeforeCursor(context.beforeCursor + head)
        let remainder = rest.isEmpty ? nil : CompletionCandidate(text: rest, mode: .prose)
        visibleCandidate = remainder
        // Redraw the shrunk remainder immediately rather than waiting for the post-insertion AX
        // snapshot to re-pin it. That snapshot is near-instant in web fields but lags by tens-to-
        // hundreds of ms in many native apps, so without this the ghost text visibly stalls after a
        // Tab until the next notification (or generation) lands. The AX path still re-pins precisely
        // once it arrives. See ADR-054.
        presenter.advanceAfterAccepting(head: head, remainder: remainder)
        insert(text: head, context: context, keepingAnchor: true)
    }

    /// Shift+Tab: insert the whole suggestion.
    func acceptFullCompletion() {
        guard canAcceptCompletion, let (text, context) = insertionText() else { return }
        telemetry.recordAccepted()
        predictionLog.append("ACCEPT(full) \"\(PredictionLog.escape(text))\"")
        insert(text: text, context: context)
    }

    /// The text to insert and the context to insert it into, derived from the anchored suggestion
    /// against the **live** caret (`liveCompletion(for:)`). Because the anchor already consumed any
    /// characters the user typed after the suggestion appeared, this never re-inserts already-typed
    /// text (no doubled characters) and never re-inserts a suggestion the user has diverged from.
    private func insertionText() -> (text: String, context: TextFieldContext)? {
        guard let live = latestContext ?? anchorContext,
              let text = liveCompletion(for: live), !text.isEmpty else { return nil }
        return (text, live)
    }

    /// Inserts `text` at the caret. By default (full-completion accept, or the final word) it drops
    /// the dedupe key and tears down the suggestion so the post-insertion snapshot regenerates fresh.
    /// When `keepingAnchor` is true (Tab word-acceptance with more words remaining) the anchor and
    /// overlay are left intact so the induced snapshot re-renders the shrinking remainder instead.
    private func insert(text: String, context: TextFieldContext, keepingAnchor: Bool = false) {
        guard !text.isEmpty else { return }
        let plan = inserter.planInsertion(candidate: CompletionCandidate(text: text), context: context)
        if !keepingAnchor {
            // Drop the dedupe key so the post-insertion snapshot always regenerates a fresh suggestion.
            lastContextKey = nil
            reuseHistory.removeAll()
            clearCompletion()
        }
        Task {
            do {
                try await inserter.insert(plan: plan)
            } catch {
                log.error("Insertion failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Engine construction

    /// Builds the runtime + profile + engine. Marked `nonisolated` so the heavy ~0.3 s model load
    /// runs off the main actor (the call site `await`s it from a `Task`) rather than hitching the
    /// UI. Inlined here — rather than via `KeyTypeModuleGraph`, whose helpers are main-actor
    /// isolated by default — so every step stays off main.
    nonisolated private static func buildEngine(
        compatibilityStore: AppCompatibilityStore,
        modelFilename: String,
        adjustments: ThresholdAdjustments
    ) async throws -> ConstrainedGenerationEngine {
        let modelURL = try ModelContainer.modelURL(filename: modelFilename)
        guard ModelContainer.modelExists(at: modelURL) else {
            throw CompletionLoadError.modelMissing(modelFilename)
        }
        // Batched beam-frontier decoding (ADR-043): the runtime holds the whole beam frontier in
        // parallel sequences and expands it in one `llama_decode` per depth level instead of one per
        // branch. This is the default and only decode path; `maxSequences` defaults to cover the
        // decoder's branch width plus the resident anchor.
        let runtime = try LlamaModelRuntime(modelURL: modelURL)
        // Resolve the tokenizer family from the model (catalog declaration, or derived from the
        // GGUF's vocab size for an imported model) so the profile filename + family validation match
        // what `ProfileGenerator` stamped. Catalog Qwen models keep the legacy "qwen3-v151936" family,
        // so an existing on-disk profile for the default model still loads without a rebuild.
        let family = ModelFamilyResolver.family(
            forFilename: modelFilename,
            vocabSize: runtime.metadata.vocabularySize
        )
        let profile = try MmapAutocompleteProfile.open(
            at: try ModelContainer.profileURL(family: family),
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
            expectedModelFamily: family
        )
        // Apply the telemetry-derived nudges to the decoder defaults: a larger relative cutoff keeps
        // more branches alive (fewer suppressions), a lower probability floor admits weaker-but-valid
        // continuations. Bounds are clamped inside `ThresholdTuner`. See ADR-023.
        let base = DecodingConfiguration(enableFillInMiddle: true)
        let configuration = DecodingConfiguration(
            relativeCutoff: base.relativeCutoff + adjustments.relativeCutoffDelta,
            minBranchProbability: base.minBranchProbability * adjustments.minBranchProbabilityScale,
            // Native fill-in-the-middle for mid-line completion (the on-device probe confirmed it
            // beats base continuation, which collides with the after-cursor text). Falls back to
            // base continuation when there is no suffix or the model lacks FIM tokens. See ADR-017.
            // The FIM-quality behaviors (caret-ward context windowing, suffix-overlap truncation, and
            // suffix-likelihood rerank) are always on and use the DecodingConfiguration defaults for
            // their window sizes / rerank depth+weight. See ADR-057.
            enableFillInMiddle: true
        )
        return ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profile,
            compatibilityStore: compatibilityStore,
            configuration: configuration,
            wordRecognizer: SystemWordRecognizer()
        )
    }

    enum CompletionLoadError: Error, CustomStringConvertible {
        case modelMissing(String)

        var description: String {
            switch self {
            case let .modelMissing(name):
                return "Model file '\(name)' not found in Application Support/KeyType/Models"
            }
        }
    }
}
