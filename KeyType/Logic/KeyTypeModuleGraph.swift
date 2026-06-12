//
//  KeyTypeModuleGraph.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import AppCompatibility
import AutocompleteCore
import CompletionUI
import ConstrainedGeneration
import MacContextCapture
import ModelRuntime
import Personalization
import Prompting
import TextInsertion
import TokenProfiles

enum KeyTypeModuleGraph {
    static func makeMVPProbeContext() -> TextFieldContext {
        TextFieldContext(
            beforeCursor: "",
            target: AppTarget(
                bundleIdentifier: "com.pattonium.KeyType",
                appName: "KeyType"
            )
        )
    }

    /// Builds a `PromptBuilder`. Pass a real `ModelTokenizing` (e.g. the loaded
    /// `LlamaModelRuntime.tokenizer`) once the runtime is available so budgeting and
    /// truncation match what the model will actually see (M3 acceptance). Without a
    /// tokenizer we fall back to the approximate counter — useful before the model is
    /// loaded and for unit tests.
    static func makePromptBuilder(
        tokenizer: ModelTokenizing? = nil,
        maxPromptTokens: Int = PromptBuilder.defaultMaxPromptTokens
    ) -> PromptBuilder {
        let counter: PromptTokenCounting = tokenizer.map { TokenizerPromptTokenCounter(tokenizer: $0) }
            ?? ApproximatePromptTokenCounter()
        return PromptBuilder(tokenCounter: counter, maxPromptTokens: maxPromptTokens)
    }

    nonisolated static func makeCompatibilityStore(
        userDisabledBundleIdentifiers: Set<String> = [],
        runtimeOverrideStore: RuntimeTargetOverrideStore? = nil
    ) -> AppCompatibilityStore {
        AppCompatibilityStore(
            userDisabledBundleIdentifiers: userDisabledBundleIdentifiers,
            runtimeOverrideStore: runtimeOverrideStore
        )
    }

    /// System-dictionary word recogniser for the decoder's current-word typo guard (ADR-015).
    static func makeWordRecognizer() -> WordRecognizing {
        SystemWordRecognizer()
    }

    /// Builds the constrained-generation engine with the system typo guard wired in. Pass
    /// `wordRecognizer: nil` to disable the guard (e.g. in a context where spell-checking is
    /// unwanted).
    static func makeCompletionEngine(
        runtime: LocalModelRuntime,
        profile: AutocompleteProfile,
        compatibilityStore: AppCompatibilityStore = makeCompatibilityStore(),
        configuration: DecodingConfiguration = DecodingConfiguration(),
        wordRecognizer: WordRecognizing? = makeWordRecognizer()
    ) -> ConstrainedGenerationEngine {
        ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profile,
            compatibilityStore: compatibilityStore,
            configuration: configuration,
            wordRecognizer: wordRecognizer
        )
    }

    /// Local writing-history store (M8): an encrypted-at-rest SQLCipher database fed by the user's
    /// recent typing, used to personalize `previousUserInputs`. Falls back to a no-op store if the
    /// database can't be opened, so a storage failure never breaks completions. The recorder and the
    /// prompt path must share one instance, so the app builds it once and injects it. See ADR-023.
    static func makeWritingHistory() -> WritingHistoryStoring {
        do {
            return try PersistentWritingHistoryStore()
        } catch {
            return NullWritingHistoryStore()
        }
    }

    /// Default tokenizer family the app expects a profile for. Qwen3.5 and Qwen3.6
    /// share this vocab, so one profile covers both models.
    static let defaultProfileFamily: String = "qwen3-v151936"

    /// Memory-maps the ACPF profile sitting in Application Support (built by
    /// `Scripts/build-acpf-profile.sh`) and validates it against the live tokenizer.
    /// The validation step rehashes the live vocab once at open time and rejects a
    /// stale profile up front. M5's sampler will consume this as its
    /// `AutocompleteProfile` rather than the in-memory placeholder.
    static func makeProfile(
        runtime: LocalModelRuntime,
        family: String = defaultProfileFamily
    ) throws -> AutocompleteProfile {
        let url = try ModelContainer.profileURL(family: family)
        return try MmapAutocompleteProfile.open(
            at: url,
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
            expectedModelFamily: family
        )
    }

    /// Assembles a prompt for the given focused-field context. Pulls
    /// `customInstructions` from `AppCompatibility`'s `CompletionPolicy` and
    /// `previousUserInputs` from the local writing-history store — both required by
    /// M3. The app owns the wiring so `Prompting` doesn't depend on
    /// `AppCompatibility`.
    static func makePrompt(
        for context: TextFieldContext,
        builder: PromptBuilder = makePromptBuilder(),
        compatibilityStore: AppCompatibilityStore = makeCompatibilityStore(),
        // Cheap default so an accidental omission never opens the encrypted DB; the app always
        // passes the shared store explicitly (see CompletionController / AppDelegate).
        history: WritingHistoryProviding = InMemoryWritingHistoryStore(),
        pasteboardText: String? = nil,
        screenText: String? = nil,
        mode: PromptTemplateMode = .baseContinuation
    ) -> PromptBuildResult {
        let policy = compatibilityStore.policy(for: context)
        let query = WritingHistoryQuery(
            bundleIdentifier: context.target.bundleIdentifier,
            domain: context.target.domain,
            typingContext: context.typingContext,
            language: context.detectedLanguage
        )
        let samples = history.samples(for: query)
        return builder.buildPrompt(
            context: context,
            customInstructions: policy.customInstructions,
            previousUserInputs: samples,
            pasteboardText: pasteboardText,
            screenText: screenText,
            mode: mode,
            includeEnvironmentContext: policy.includesEnvironmentContext
        )
    }
}
