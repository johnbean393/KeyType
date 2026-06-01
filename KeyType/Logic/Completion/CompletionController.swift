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
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "completion")

    private var engine: ConstrainedGenerationEngine?
    private var generationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var listenerToken: UUID?
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
    /// Reconciled, filter-approved candidate anchors from the most recent generation. Used to keep a
    /// lower-ranked branch alive when the user types into it; cleared on every normal reset/recompute.
    private var promotionCache: CompletionPromotionCache?
    /// The most recent focused-field context seen — the live caret the suggestion is reconciled to.
    private var latestContext: TextFieldContext?
    private var frozenSideContext: FrozenPromptSideContext?
    private var lastGenerationLatencyMs: Double?
    /// Set when the user accepts a word with Tab: keep the *rest* of the same suggestion in place and
    /// do not regenerate, so repeated Tab presses walk through the remaining words of that one
    /// completion. Cleared once the suggestion is exhausted, the user diverges, or the overlay is torn
    /// down — at which point normal per-keystroke generation resumes.
    private var holdAnchor = false

    var completionsEnabled = true {
        didSet {
            if !completionsEnabled { reset() }
        }
    }

    nonisolated static let fastDebounceNanoseconds: UInt64 = 35_000_000
    nonisolated static let moderateDebounceNanoseconds: UInt64 = 50_000_000
    nonisolated static let conservativeDebounceNanoseconds: UInt64 = 90_000_000
    private static let sideContextFreezeInterval: TimeInterval = 2.0

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
        warmupTask?.cancel()
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
        guard let snapshot else { reset(); return }
        guard let caretRect = snapshot.caretRect, !caretRect.isEmpty else {
            if preserveHeldCompletion(for: snapshot.context) { return }
            reset()
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
        let key = context.beforeCursor + "\u{1}" + context.afterCursor + "\u{1}" + context.target.bundleIdentifier
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
            reset()
            return
        }

        // Resolve the field font and foreground color now, on the main actor, before suspending
        // into generation, so the ghost text matches the field's typeface and color.
        let style = FieldFontResolver.currentStyle()

        // Holding an accepted suggestion: while its remainder still applies to the live caret, keep it
        // on screen and skip regeneration so repeated Tab presses accept subsequent words of the SAME
        // completion (rather than producing a fresh one after each word). Once the remainder is
        // exhausted or the user diverges, fall through to a fresh generation below.
        //
        // This must run before promotion-cache reuse: the cache has a "remaining text must be at least
        // 3 characters" guard for speculative type-through, but word-by-word Tab acceptance must keep
        // valid short remainders such as "hi" or ".".
        if holdAnchor {
            if renderSuggestion(for: context, style: style, clearOnFailure: false) {
                return
            }
            holdAnchor = false
        }

        // The context just changed (the dedup above let us through), so the on-screen suggestion is
        // from the *previous* caret. Try to reuse the last generated candidate set: if the user typed
        // into any still-compatible branch (including a lower-ranked one), promote it and skip this
        // decode. Otherwise drop the stale ghost and let a fresh generation run below.
        switch applyPromotionCacheIfUseful(for: context, style: style) {
        case .reused:
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
        if !sideContextReused || lastGenerationLatencyMs == nil {
            startAnchorWarmup(engine: engine, request: request)
        }

        // Debounce: coalesce rapid keystrokes, and DON'T hide the current ghost up front — we
        // transition directly old → new (or → hidden) when generation finishes, so typing updates
        // the suggestion in place instead of blinking it out and back in.
        let debounceNanoseconds = Self.adaptiveDebounceNanoseconds(
            lastGenerationLatencyMs: lastGenerationLatencyMs
        )
        generationTask?.cancel()
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.generationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let start = DispatchTime.now()
                    let candidates = try await engine.completions(for: request)
                    try Task.checkCancellation()
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    self.lastGenerationLatencyMs = elapsedMs
                    self.telemetry.recordLatency(milliseconds: elapsedMs)
                    self.present(candidates, request: request, style: style)
                } catch is CancellationError {
                    // Superseded by a newer keystroke — leave the current ghost as-is.
                } catch {
                    self.log.error("Generation failed: \(error, privacy: .public)")
                }
            }
        }
    }

    private func present(
        _ candidates: [CompletionCandidate],
        request: CompletionRequest,
        style: ResolvedFieldStyle
    ) {
        let ctx = PredictionLog.contextTail(request.context.beforeCursor)
        let ranked = candidates.prefix(5)
            .map { "\"\(PredictionLog.escape($0.text))\"" }
            .joined(separator: " | ")

        guard let best = candidates.first else {
            telemetry.recordSuppressed(reason: "noCandidate")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" → SUPPRESS(noCandidate)")
            clearCompletion()
            return
        }
        if let reason = filter.suppressionReason(for: best, request: request) {
            telemetry.recordSuppressed(reason: String(describing: reason))
            log.debug("Suppressed: \(String(describing: reason), privacy: .public)")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SUPPRESS(\(reason))")
            clearCompletion()
            return
        }

        // When the prompt was healed (ADR-019), the completion re-emits the already-typed stem
        // (" great today."); strip it back off so only the genuinely new text ("at today.") remains.
        guard let anchored = anchorText(for: best, request: request, applyingFilter: false) else {
            telemetry.recordSuppressed(reason: "emptyAfterBoundary")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SUPPRESS(emptyAfterBoundary)")
            clearCompletion()
            return
        }

        promotionCache = makePromotionCache(from: candidates, request: request)
        anchorText = anchored
        anchorContext = request.context
        telemetry.recordShown()
        predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SHOWN \"\(PredictionLog.escape(anchored))\"")
        if !renderSuggestion(for: latestContext ?? request.context, style: style, clearOnFailure: false) {
            _ = renderSuggestion(for: request.context, style: style)
        }
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

    private enum PromotionCacheApplication {
        case reused
        case mustRecompute
        case notApplicable
    }

    @discardableResult
    private func applyPromotionCacheIfUseful(
        for live: TextFieldContext,
        style: ResolvedFieldStyle,
        updateLatestContext: Bool = false
    ) -> PromotionCacheApplication {
        guard let cache = promotionCache else { return .notApplicable }

        switch cache.decision(for: live) {
        case let .promote(promotion):
            anchorText = promotion.anchorText
            anchorContext = cache.anchorContext
            if updateLatestContext { latestContext = live }
            guard renderSuggestion(for: live, style: style, clearOnFailure: false) else {
                clearCompletion()
                return .mustRecompute
            }
            predictionLog.append(
                "PROMOTE rank=\(promotion.sourceRank) remaining=\"\(PredictionLog.escape(promotion.remainingText))\""
            )
            return .reused

        case .recompute(.noTypedDelta):
            return .notApplicable

        case .recompute:
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
        presenter.show(candidate: candidate, placement: placement, font: style.font, textColor: style.color)
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

    private func clearCompletion(clearPromotionCache: Bool = true) {
        presenter.hide()
        visibleCandidate = nil
        anchorText = nil
        anchorContext = nil
        if clearPromotionCache { promotionCache = nil }
        holdAnchor = false
    }

    /// Hide any ghost text and forget the last context, so the next snapshot is treated as new.
    private func reset() {
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        lastContextKey = nil
        lastCaretRect = nil
        frozenSideContext = nil
        clearCompletion()
    }

    /// Whether the completion should render as a capsule below the caret rather than inline ghost
    /// text. True only when there is visible (non-whitespace) suffix text remaining on the *current*
    /// line — that's the case where inline ghost text would overlap the user's existing text. If the
    /// caret is at the end of the line, the document, or the end of a paragraph (the remainder of the
    /// line is empty/whitespace and the next character is a newline), inline ghost text appends
    /// cleanly with nothing to overlap, so we keep it.
    static func shouldUseCapsule(for context: TextFieldContext) -> Bool {
        let currentLineSuffix = context.afterCursor.prefix { !$0.isNewline }
        return currentLineSuffix.contains { !$0.isWhitespace }
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
        guard visibleCandidate != nil, let context = latestContext ?? anchorContext else { return false }
        return compatibilityStore.policy(for: context).allowsTabAcceptance
    }

    /// Synchronously dismiss the on-screen suggestion when a just-pressed key makes it stale, *before*
    /// the AX `value-changed` snapshot for that keystroke arrives. Driven by the global key tap, which
    /// sees every key-down immediately; the AX pipeline that would otherwise clear a diverged
    /// suggestion lags behind by the debounce plus the app's notification latency, so without this the
    /// outdated ghost text visibly lingers for a beat after each key. See ADR-037.
    ///
    /// `typed` is the plain text the key inserts, or `nil` for keys that don't insert plain text
    /// (delete, arrows, return, escape, ⌘/⌃ shortcuts). When the user is typing into any cached
    /// branch, the branch is promoted immediately and normal generation is skipped until the cache no
    /// longer has a substantial matching remainder. Anything else clears now and abandons in-flight
    /// generation, so a result returning for the previous caret can't re-show a stale suggestion.
    func dismissStaleCompletion(typedCharacters typed: String?) {
        guard let shown = visibleCandidate?.text, !shown.isEmpty else { return }
        if let typed, !typed.isEmpty {
            let cacheWasAvailable = promotionCache != nil
            if promoteCachedCompletion(typedCharacters: typed) { return }
            // Compatibility fallback for states created before a candidate-set cache exists.
            if !cacheWasAvailable, shown.hasPrefix(typed), advanceTypeThrough(typedCharacters: typed) {
                return
            }
        }
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        clearCompletion()
    }

    private func promoteCachedCompletion(typedCharacters typed: String) -> Bool {
        guard !typed.isEmpty,
              let live = latestContext ?? anchorContext,
              let cache = promotionCache
        else { return false }
        let optimistic = live.replacingBeforeCursor(live.beforeCursor + typed)

        switch cache.decision(for: optimistic) {
        case let .promote(promotion):
            anchorText = promotion.anchorText
            anchorContext = cache.anchorContext
            latestContext = optimistic
            let remainder = CompletionCandidate(text: promotion.remainingText, mode: .prose)
            visibleCandidate = remainder
            presenter.advanceAfterAccepting(head: typed, remainder: remainder)
            predictionLog.append(
                "PROMOTE rank=\(promotion.sourceRank) remaining=\"\(PredictionLog.escape(promotion.remainingText))\""
            )
            debounceTask?.cancel()
            generationTask?.cancel()
            warmupTask?.cancel()
            return true

        case .recompute(.noTypedDelta):
            return false

        case .recompute:
            clearCompletion()
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
        promotionCache = nil
        // Cancel any in-flight generation so it can't clobber the held suggestion when it returns.
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
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
