import AppCompatibility
import AutocompleteCore
import ConstrainedGeneration
import ModelRuntime
import TokenProfiles
import XCTest

/// Deterministic tests for the M5 multi-branch decoder. They use `TreeScriptedModelRuntime`
/// (path-dependent logits) + `InMemoryAutocompleteProfile`, so they run on any machine without
/// a model or profile present.
final class ConstrainedGenerationEngineTests: XCTestCase {

    // MARK: - Fixtures

    private static let testVocabSize = 4096
    private static let testTarget = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func record(
        _ id: TokenID,
        _ text: String,
        flags: TokenProfileFlags = [],
        width: Int? = nil,
        bias: Float = 0
    ) -> TokenProfileRecord {
        let bytes = Array(text.utf8)
        return TokenProfileRecord(
            tokenID: id,
            bytes: bytes,
            flags: flags,
            staticBias: bias,
            displayWidth: width ?? bytes.count
        )
    }

    private func record(
        _ id: TokenID,
        rawBytes: [UInt8],
        flags: TokenProfileFlags = [],
        width: Int? = nil
    ) -> TokenProfileRecord {
        TokenProfileRecord(
            tokenID: id,
            bytes: rawBytes,
            flags: flags,
            staticBias: 0,
            displayWidth: width ?? rawBytes.count
        )
    }

    private func profile(_ records: [TokenProfileRecord]) -> InMemoryAutocompleteProfile {
        InMemoryAutocompleteProfile(vocabularySize: Self.testVocabSize, records: records)
    }

    private func mmapProfile(_ records: [TokenProfileRecord]) throws -> MmapAutocompleteProfile {
        var entries = (0..<Self.testVocabSize).map { id in
            ACPFTokenEntry(
                tokenID: TokenID(id),
                bytes: [],
                flags: [.excluded],
                staticBias: 0,
                displayWidth: 0,
                tokenType: 0
            )
        }
        for record in records {
            entries[Int(record.tokenID)] = ACPFTokenEntry(
                tokenID: record.tokenID,
                bytes: record.bytes,
                flags: record.flags,
                staticBias: record.staticBias,
                displayWidth: record.displayWidth,
                tokenType: 0
            )
        }
        let input = ACPFProfileInput(
            modelFamily: "test",
            vocabSize: Self.testVocabSize,
            tokenizerDigest: ACPFTokenizerDigestValue(lo: 1, hi: 2),
            entries: entries,
            buildTimestamp: Date(timeIntervalSince1970: 0)
        )
        return try MmapAutocompleteProfile(data: ACPFWriter.encode(input))
    }

    private func runtime(
        _ logitsByPath: [[TokenID]: [TokenLogit]],
        eos: TokenID? = nil,
        perCallDelayNanoseconds: UInt64? = nil
    ) -> TreeScriptedModelRuntime {
        TreeScriptedModelRuntime(
            logitsByPath: logitsByPath,
            metadata: ModelMetadata(
                identifier: "tree",
                family: "stub",
                vocabularySize: Self.testVocabSize,
                contextLength: 4096,
                eosTokenID: eos
            ),
            perCallDelayNanoseconds: perCallDelayNanoseconds
        )
    }

    private func request(
        requiredPrefix: [UInt8] = [],
        maxTokens: Int = 2,
        maxWidth: Int = 80,
        beforeCursor: String = "",
        afterCursor: String = "",
        target: AppTarget = ConstrainedGenerationEngineTests.testTarget
    ) -> CompletionRequest {
        CompletionRequest(
            context: TextFieldContext(beforeCursor: beforeCursor, afterCursor: afterCursor, target: target),
            prompt: "",
            requiredPrefixBytes: requiredPrefix,
            mode: .prose,
            maxCompletionTokens: maxTokens,
            maxDisplayWidth: maxWidth
        )
    }

    private func logit(_ id: TokenID, _ value: Float) -> TokenLogit {
        TokenLogit(tokenID: id, logit: value)
    }

    private func midLineEnabledStore() -> AppCompatibilityStore {
        AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.testTarget.bundleIdentifier, midLineCompletionsEnabled: true)
        ])
    }

    private final class CountingBatchRuntime: LocalModelRuntime {
        let metadata: ModelMetadata
        let tokenizer: ModelTokenizing = UTF8FallbackTokenizer()
        private let logitsByPath: [[TokenID]: [TokenLogit]]
        private var currentTokens: [TokenID] = []
        private(set) var batchCalls = 0
        private(set) var batchRequests: [(anchor: [TokenID], suffixes: [[TokenID]])] = []

        init(
            logitsByPath: [[TokenID]: [TokenLogit]],
            vocabularySize: Int = ConstrainedGenerationEngineTests.testVocabSize
        ) {
            self.logitsByPath = logitsByPath
            self.metadata = ModelMetadata(
                identifier: "counting-batch",
                family: "stub",
                vocabularySize: vocabularySize,
                contextLength: 4096
            )
        }

        func prepare(promptTokens: [TokenID]) async throws {
            currentTokens = promptTokens
        }

        func logitsForNextToken() async throws -> [TokenLogit] {
            logitsByPath[currentTokens] ?? []
        }

        func decodeNext(tokenID: TokenID) async throws {
            currentTokens.append(tokenID)
        }

        func resetKVCache() async {
            currentTokens = []
        }

        func anchoredLogitsBatch(anchor: [TokenID], suffixes: [[TokenID]]) async throws -> [[TokenLogit]] {
            batchCalls += 1
            batchRequests.append((anchor: anchor, suffixes: suffixes))
            return suffixes.map { logitsByPath[anchor + $0] ?? [] }
        }
    }

    // MARK: - Multi-branch search

    func testMultiBranchReturnsRankedCandidateSet() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["good", "best"])
        XCTAssertGreaterThan(candidates[0].logProbability, candidates[1].logProbability)
        XCTAssertEqual(candidates[0].tokenIDs, [1, 11])
    }

    func testBranchWidthLimitsBeam() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let config = DecodingConfiguration(branchWidth: 1)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["good"])
    }

    func testCapitalizedHealedStemGetsOneExtraBeamSlot() async throws {
        let profile = profile([
            record(1, " RockeA"), record(2, " RockeB"), record(3, " RockeC"),
            record(11, " stop."), record(21, " stop."), record(31, " winner.")
        ])
        let runtime = runtime([
            []: [logit(1, 3), logit(2, 2), logit(3, 1)],
            [1]: [logit(11, 1)],
            [2]: [logit(21, 1)],
            [3]: [logit(31, 1)]
        ])
        let config = DecodingConfiguration(branchWidth: 2)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(
            requiredPrefix: Array(" Rocke".utf8),
            maxTokens: 2,
            beforeCursor: "Rocke"
        ))

        XCTAssertTrue(
            candidates.map(\.text).contains(" RockeC winner."),
            "capitalized healed stems keep a third branch for proper-name continuations"
        )
    }

    func testLowercaseHealedStemUsesConfiguredBeamWidth() async throws {
        let profile = profile([
            record(1, " rockeA"), record(2, " rockeB"), record(3, " rockeC"),
            record(11, " stop."), record(21, " stop."), record(31, " winner.")
        ])
        let runtime = runtime([
            []: [logit(1, 3), logit(2, 2), logit(3, 1)],
            [1]: [logit(11, 1)],
            [2]: [logit(21, 1)],
            [3]: [logit(31, 1)]
        ])
        let config = DecodingConfiguration(branchWidth: 2)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(
            requiredPrefix: Array(" rocke".utf8),
            maxTokens: 2,
            beforeCursor: "rocke"
        ))

        XCTAssertFalse(candidates.map(\.text).contains(" rockeC winner."))
    }

    func testEarlyExitKeepsLockedTopCandidateWithoutDeeperDecode() async throws {
        let profile = profile([
            record(1, " done.", flags: .sentenceEnd),
            record(2, " maybe"),
            record(3, " later.")
        ])
        let runtime = CountingBatchRuntime(logitsByPath: [
            []: [logit(1, 10), logit(2, 0)],
            [2]: [logit(3, 10)]
        ])
        let config = DecodingConfiguration(branchWidth: 2, maxCandidates: 1)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(maxTokens: 3))

        XCTAssertEqual(candidates.map(\.text), [" done."])
        XCTAssertEqual(runtime.batchCalls, 1, "a locked top candidate should skip deeper beam work")
    }

    func testEarlyExitDoesNotStopWhenLiveBranchCanTieFinalizedCandidate() async throws {
        let profile = profile([
            record(1, " zzz.", flags: .sentenceEnd),
            record(2, " a"),
            record(3, "aa.", flags: .sentenceEnd)
        ])
        let runtime = CountingBatchRuntime(logitsByPath: [
            []: [logit(1, 0), logit(2, 0)],
            [2]: [logit(3, 10)]
        ])
        let config = DecodingConfiguration(branchWidth: 2, maxCandidates: 1)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), [" aaa."])
        XCTAssertEqual(runtime.batchCalls, 2, "ties must continue because the final text order can still change")
    }

    func testRelativeCutoffPrunesWeakBranch() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let config = DecodingConfiguration(relativeCutoff: 0.5)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["good"])
    }

    func testMinBranchProbabilityFloorDropsLowProbabilityToken() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let config = DecodingConfiguration(minBranchProbability: 0.5)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["good"])
    }

    // MARK: - Required prefix

    func testRequiredPrefixSingleTokenKeepsOnlyMatchingCandidates() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(
            for: request(requiredPrefix: Array("b".utf8), maxTokens: 2)
        )

        XCTAssertEqual(candidates.map(\.text), ["best"])
        XCTAssertTrue(candidates.allSatisfy { $0.text.hasPrefix("b") })
    }

    func testRequiredPrefixSpanningMultipleTokens() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(21, "st"), record(22, "xy")
        ])
        let runtime = runtime([
            []: [logit(1, 1.0), logit(2, 1.0)],
            [2]: [logit(21, 2.0), logit(22, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(
            for: request(requiredPrefix: Array("best".utf8), maxTokens: 2)
        )

        XCTAssertEqual(candidates.map(\.text), ["best"])
    }

    /// Regression for ADR-025: the admissible required-prefix token must survive even when it ranks
    /// *below* the sampler's raw-logit pre-selection cutoff (256 tokens). This is the mid-word
    /// token-healing case (ADR-019) where the forced continuation is locally improbable — before the
    /// fix the pre-selection masked the only admissible token out and the engine returned nothing
    /// (`noCandidate`), which is the "easy word, no completion" symptom seen in the prediction log.
    func testRequiredPrefixSurvivesBelowPreselectionCutoff() async throws {
        // One admissible token ("zo", satisfies prefix "z") with a *low* logit, plus 272 inadmissible
        // higher-logit filler tokens — more than the 256-token raw-logit pre-selection window, so the
        // target is pushed out of it.
        var records: [TokenProfileRecord] = [record(1, "zo")]
        var rootLogits: [TokenLogit] = [logit(1, 0.1)]
        var fillerID: TokenID = 1000
        for a in 0..<17 {
            for b in 0..<16 {
                let text = String(UnicodeScalar(UInt8(97 + a))) + String(UnicodeScalar(UInt8(97 + b)))
                records.append(record(fillerID, text)) // first byte 'a'..'q' — never 'z'
                rootLogits.append(logit(fillerID, 5.0)) // outranks the target so it dominates top-256
                fillerID += 1
            }
        }
        XCTAssertGreaterThan(rootLogits.count, 256, "fixture must exceed the pre-selection window")

        let engine = ConstrainedGenerationEngine(runtime: runtime([[]: rootLogits]), profile: profile(records))

        let candidates = try await engine.completions(
            for: request(requiredPrefix: Array("z".utf8), maxTokens: 1)
        )

        XCTAssertEqual(candidates.map(\.text), ["zo"], "the only admissible token must be found")
    }

    func testRequiredPrefixSurvivesBelowPreselectionCutoffWithMmapProfile() async throws {
        var records: [TokenProfileRecord] = [record(1, "zo")]
        var rootLogits: [TokenLogit] = [logit(1, 0.1)]
        var fillerID: TokenID = 1000
        for a in 0..<17 {
            for b in 0..<16 {
                let text = String(UnicodeScalar(UInt8(97 + a))) + String(UnicodeScalar(UInt8(97 + b)))
                records.append(record(fillerID, text))
                rootLogits.append(logit(fillerID, 5.0))
                fillerID += 1
            }
        }

        let engine = try ConstrainedGenerationEngine(
            runtime: runtime([[]: rootLogits]),
            profile: mmapProfile(records)
        )
        let candidates = try await engine.completions(
            for: request(requiredPrefix: Array("z".utf8), maxTokens: 1)
        )

        XCTAssertEqual(candidates.map(\.text), ["zo"], "mmap required-prefix checks must match the in-memory path")
    }

    func testUnsatisfiableRequiredPrefixYieldsNothing() async throws {
        let profile = profile([record(1, "go"), record(2, "be")])
        let runtime = runtime([[]: [logit(1, 1.0), logit(2, 1.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(
            for: request(requiredPrefix: Array("z".utf8), maxTokens: 2)
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Validity / width

    func testInvalidUTF8BranchIsDropped() async throws {
        let profile = profile([
            record(1, "ok"),
            record(2, rawBytes: [0xFF]) // illegal lead byte, never completable
        ])
        let runtime = runtime([[]: [logit(1, 1.0), logit(2, 2.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 1))

        XCTAssertEqual(candidates.map(\.text), ["ok"])
    }

    func testOverWidthBranchIsDropped() async throws {
        let profile = profile([
            record(1, "ok", width: 2),
            record(2, "abcdefgh", width: 8)
        ])
        let runtime = runtime([[]: [logit(1, 1.0), logit(2, 2.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 1, maxWidth: 4))

        XCTAssertEqual(candidates.map(\.text), ["ok"])
    }

    // MARK: - Multilingual / byte-fallback width + finalization

    /// A CJK character ("中" = E4 B8 AD) emitted as three single-byte tokens must count as one
    /// grapheme of display width, not three — otherwise byte-fallback scripts blow the width cap.
    func testByteFallbackMultibyteCountsOneGraphemeOfWidth() async throws {
        let profile = profile([
            record(1, rawBytes: [0xE4]),
            record(2, rawBytes: [0xB8]),
            record(3, rawBytes: [0xAD])
        ])
        let runtime = runtime([
            []: [logit(1, 2.0)],
            [1]: [logit(2, 2.0)],
            [1, 2]: [logit(3, 2.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        // maxWidth 1 would reject the branch if width were summed per byte (3 > 1).
        let candidates = try await engine.completions(for: request(maxTokens: 3, maxWidth: 1))

        XCTAssertEqual(candidates.map(\.text), ["中"])
        XCTAssertEqual(candidates.first?.displayWidth, 1)
    }

    /// A combining mark (here U+0301, two bytes CC 81) attaches to the previous grapheme and must
    /// add zero display width — relevant to Arabic/Hebrew/Devanagari/Thai marks.
    func testCombiningMarkAddsZeroWidth() async throws {
        let profile = profile([
            record(1, "e"),
            record(2, rawBytes: [0xCC, 0x81]) // combining acute accent
        ])
        let runtime = runtime([
            []: [logit(1, 2.0)],
            [1]: [logit(2, 2.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        // maxWidth 1: a per-token sum (1 + 2) would exceed it and drop the branch.
        let candidates = try await engine.completions(for: request(maxTokens: 2, maxWidth: 1))

        XCTAssertEqual(candidates.map(\.text), ["e\u{0301}"])
        XCTAssertEqual(candidates.first?.displayWidth, 1)
    }

    /// When the token-depth cap lands mid-character (a trailing *pending* multi-byte sequence),
    /// the branch should still emit its valid-UTF-8 prefix rather than be dropped entirely.
    func testPendingTrailingBytesEmitValidPrefix() async throws {
        let profile = profile([
            record(1, "a"),
            record(2, rawBytes: [0xE4]) // first byte of a 3-byte char; never completed
        ])
        let runtime = runtime([
            []: [logit(1, 2.0)],
            [1]: [logit(2, 2.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["a"])
    }

    // MARK: - Stop conditions

    func testStopsOnEOSAndKeepsPriorText() async throws {
        let profile = profile([record(1, "hello"), record(99, "x")])
        let runtime = runtime(
            [
                []: [logit(1, 2.0)],
                [1]: [logit(900, 5.0), logit(99, 1.0)]
            ],
            eos: 900
        )
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 3))

        XCTAssertEqual(candidates.map(\.text), ["hello"])
        XCTAssertEqual(candidates[0].tokenIDs, [1])
    }

    func testStopAndSuppressFlagTerminatesBranch() async throws {
        let profile = profile([
            record(1, "hello"),
            record(500, "STOP", flags: .stop),
            record(99, "x")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0)],
            [1]: [logit(500, 5.0), logit(99, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 3))

        XCTAssertEqual(candidates.map(\.text), ["hello"])
    }

    func testSentenceBoundaryStopAndDisplayEmitsThenStops() async throws {
        let profile = profile([
            record(1, "Hi"),
            record(3, ".", flags: .sentenceEnd)
        ])
        let runtime = runtime([
            []: [logit(1, 2.0)],
            [1]: [logit(3, 2.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 4))

        XCTAssertEqual(candidates.map(\.text), ["Hi."])
        // Stopped at the sentence end well before maxCompletionTokens.
        XCTAssertEqual(candidates[0].tokenIDs, [1, 3])
    }

    // MARK: - Cancellation

    func testGenerationCancelsPromptlyOnNewRequest() async throws {
        let profile = profile([record(1, "x")])
        // 200 ms per runtime call; we cancel ~30 ms in, so the first `prepare` is interrupted.
        let runtime = runtime([[]: [logit(1, 1.0)]], perCallDelayNanoseconds: 200_000_000)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let task = Task { try await engine.completions(for: request(maxTokens: 8)) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected generation to be cancelled")
        } catch is CancellationError {
            // expected
        }
    }

    // MARK: - Policy gates

    func testCompletionsDisabledSuppresses() async throws {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.testTarget.bundleIdentifier, completionsDisabled: true)
        ])
        let profile = profile([record(1, "x")])
        let runtime = runtime([[]: [logit(1, 1.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, compatibilityStore: store)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertTrue(candidates.isEmpty)
    }

    func testMidLineDisabledSuppressesWhenTextFollowsCursor() async throws {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.testTarget.bundleIdentifier, midLineCompletionsDisabled: true)
        ])
        let profile = profile([record(1, "x")])
        let runtime = runtime([[]: [logit(1, 1.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, compatibilityStore: store)

        let candidates = try await engine.completions(for: request(maxTokens: 2, afterCursor: "tail"))

        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Current-word typo guard

    /// Recognises exactly the words it is told about; everything else is "misspelled".
    private struct StubRecognizer: AutocompleteCore.WordRecognizing {
        let known: Set<String>
        func recognizes(_ word: String, language: String?) async -> Bool {
            known.contains(word.lowercased())
        }
    }

    private func typoRequest(
        beforeCursor: String,
        afterCursor: String = "",
        mode: CompletionMode = .prose,
        maxTokens: Int = 3
    ) -> CompletionRequest {
        CompletionRequest(
            context: TextFieldContext(
                beforeCursor: beforeCursor,
                afterCursor: afterCursor,
                target: Self.testTarget
            ),
            prompt: "",
            mode: mode,
            maxCompletionTokens: maxTokens,
            maxDisplayWidth: 80
        )
    }

    /// Tokens that build both spellings of "tomorrow" from the stem "tom": the typo path
    /// "or"+"ow"+"." outscores the correct single-token "orrow"+".".
    private func tomorrowFixture() -> ([TokenProfileRecord], [[TokenID]: [TokenLogit]]) {
        let records = [
            record(20, "or"), record(21, "ow"), record(10, "orrow"),
            record(30, ".", flags: .sentenceEnd)
        ]
        let logits: [[TokenID]: [TokenLogit]] = [
            []: [logit(20, 2.0), logit(10, 1.0)], // "or" (typo path) scores higher than "orrow"
            [20]: [logit(21, 2.0)],
            [20, 21]: [logit(30, 2.0)],
            [10]: [logit(30, 2.0)]
        ]
        return (records, logits)
    }

    /// Without a recogniser the misspelled tokenisation wins (the bug); with one that knows only
    /// the correct spelling, the typo branch is dropped mid-search and the correct branch surfaces.
    func testTypoBranchDroppedSoCorrectSpellingWins() async throws {
        let (records, logits) = tomorrowFixture()

        let noGuard = ConstrainedGenerationEngine(runtime: runtime(logits), profile: profile(records))
        let bug = try await noGuard.completions(for: typoRequest(beforeCursor: "I will see you tom"))
        XCTAssertEqual(bug.first?.text, "orow.", "without the guard the misspelling out-scores the fix")

        let guarded = ConstrainedGenerationEngine(
            runtime: runtime(logits),
            profile: profile(records),
            wordRecognizer: StubRecognizer(known: ["tomorrow"])
        )
        let fixed = try await guarded.completions(for: typoRequest(beforeCursor: "I will see you tom"))
        XCTAssertEqual(fixed.map(\.text), ["orrow."], "typo dropped, correct spelling kept")
    }

    /// Requirement 3: a non-dictionary word that already appears in the surrounding text is a
    /// special term, not a typo, so it must be kept even with a recogniser that rejects it.
    func testWordPresentInContextIsKept() async throws {
        let (records, logits) = tomorrowFixture()
        let engine = ConstrainedGenerationEngine(
            runtime: runtime(logits),
            profile: profile(records),
            wordRecognizer: StubRecognizer(known: []) // knows nothing
        )

        // "tomorow" appears earlier in the field → treated as a deliberate term.
        let candidates = try await engine.completions(
            for: typoRequest(beforeCursor: "my tomorow tom")
        )
        XCTAssertEqual(candidates.first?.text, "orow.")
    }

    /// A word still being formed (no boundary yet) is a valid prefix and must never be flagged,
    /// even by a recogniser that rejects everything.
    func testOpenWordAtCapIsNotFlagged() async throws {
        let records = [record(20, "or"), record(21, "ow")]
        let logits: [[TokenID]: [TokenLogit]] = [
            []: [logit(20, 2.0)],
            [20]: [logit(21, 2.0)]
        ]
        let engine = ConstrainedGenerationEngine(
            runtime: runtime(logits),
            profile: profile(records),
            wordRecognizer: StubRecognizer(known: [])
        )

        let candidates = try await engine.completions(
            for: typoRequest(beforeCursor: "I will see you tom", maxTokens: 2)
        )
        XCTAssertEqual(candidates.map(\.text), ["orow"], "incomplete word is a prefix, never a typo")
    }

    /// Code mode never spell-checks — identifiers are not typos.
    func testCodeModeSkipsTypoGuard() async throws {
        let (records, logits) = tomorrowFixture()
        let engine = ConstrainedGenerationEngine(
            runtime: runtime(logits),
            profile: profile(records),
            wordRecognizer: StubRecognizer(known: [])
        )

        let candidates = try await engine.completions(
            for: typoRequest(beforeCursor: "let x = tom", mode: .code)
        )
        XCTAssertEqual(candidates.first?.text, "orow.")
    }

    /// Capitalised words (proper nouns, sentence starts) are exempt to avoid false positives.
    func testCapitalizedWordIsNotFlagged() async throws {
        let (records, logits) = tomorrowFixture()
        let engine = ConstrainedGenerationEngine(
            runtime: runtime(logits),
            profile: profile(records),
            wordRecognizer: StubRecognizer(known: [])
        )

        // Stem "Tom" → reconstructed word "Tomorow" has an uppercase letter → never judged.
        let candidates = try await engine.completions(
            for: typoRequest(beforeCursor: "See you Tom")
        )
        XCTAssertEqual(candidates.first?.text, "orow.")
    }

    /// ADR-025 follow-up: with mid-word healing (ADR-019) the branch text re-emits the typed stem
    /// (`" coll…"`), so it begins with the heal's leading space. The guard must strip the heal before
    /// reconstructing the current word; otherwise the leading word is empty and the nonsense word is
    /// never judged. Here the higher-scoring "collvm" is dropped through the heal so the real word
    /// "collaboration" surfaces instead.
    func testHealedMidWordTypoBranchDroppedThroughHeal() async throws {
        let records = [
            record(1, " coll"), record(20, "vm"), record(21, "aboration"), record(30, " ")
        ]
        let logits: [[TokenID]: [TokenLogit]] = [
            []: [logit(1, 2.0)],
            [1]: [logit(20, 2.0), logit(21, 1.0)], // nonsense "vm" out-scores "aboration"
            [1, 20]: [logit(30, 2.0)],
            [1, 21]: [logit(30, 2.0)]
        ]
        // `prompt` is empty so the scripted runtime keys logits on the branch tokens alone (it has no
        // KV-fork override and decodes `anchor + suffix`); the guard's stem comes from `beforeCursor`.
        let healedRequest = CompletionRequest(
            context: TextFieldContext(beforeCursor: "This is a coll", afterCursor: "", target: Self.testTarget),
            prompt: "",
            requiredPrefixBytes: Array(" coll".utf8),
            mode: .prose,
            maxCompletionTokens: 3,
            maxDisplayWidth: 80
        )

        // Without a guard, the higher-scoring nonsense word wins.
        let noGuard = ConstrainedGenerationEngine(runtime: runtime(logits), profile: profile(records))
        let bug = try await noGuard.completions(for: healedRequest)
        XCTAssertEqual(bug.first?.text, " collvm ", "without the guard the nonsense word out-scores the real one")

        // With a recogniser that knows only "collaboration", the typo branch is dropped mid-search
        // even though the completion re-emits the healed stem.
        let guarded = ConstrainedGenerationEngine(
            runtime: runtime(logits),
            profile: profile(records),
            wordRecognizer: StubRecognizer(known: ["collaboration"])
        )
        let fixed = try await guarded.completions(for: healedRequest)
        XCTAssertEqual(fixed.map(\.text), [" collaboration "], "healed nonsense dropped, real word kept")
    }

    func testHealedMidWordBoundaryBranchDroppedInBeam() async throws {
        let records = [
            record(1, " Aga"), record(20, " Khan"), record(21, "inst"), record(30, " a field")
        ]
        let logits: [[TokenID]: [TokenLogit]] = [
            []: [logit(1, 2.0)],
            [1]: [logit(20, 2.0), logit(21, 1.0)],
            [1, 21]: [logit(30, 2.0)]
        ]
        let healedRequest = CompletionRequest(
            context: TextFieldContext(
                beforeCursor: "Count Fleet next entered the Withers Stakes. Aga",
                afterCursor: "",
                target: Self.testTarget
            ),
            prompt: "",
            requiredPrefixBytes: Array(" Aga".utf8),
            mode: .prose,
            maxCompletionTokens: 3,
            maxDisplayWidth: 80
        )

        let engine = ConstrainedGenerationEngine(runtime: runtime(logits), profile: profile(records))
        let candidates = try await engine.completions(for: healedRequest)
        XCTAssertEqual(candidates.map(\.text), [" Against a field"])
    }

    func testHealedMidWordLongOpenFragmentDemotedBehindClosedWord() async throws {
        let records = [
            record(1, " dera"), record(20, "licious"), record(21, "nged"), record(30, " and")
        ]
        let logits: [[TokenID]: [TokenLogit]] = [
            []: [logit(1, 2.0)],
            [1]: [logit(20, 3.0), logit(21, 1.0)],
            [1, 21]: [logit(30, 1.0)]
        ]
        let healedRequest = CompletionRequest(
            context: TextFieldContext(beforeCursor: "The character was dera", afterCursor: "", target: Self.testTarget),
            prompt: "",
            requiredPrefixBytes: Array(" dera".utf8),
            mode: .prose,
            maxCompletionTokens: 3,
            maxDisplayWidth: 80
        )

        let engine = ConstrainedGenerationEngine(runtime: runtime(logits), profile: profile(records))
        let candidates = try await engine.completions(for: healedRequest)
        XCTAssertEqual(Array(candidates.map(\.text).prefix(2)), [" deranged and", " deralicious"])
    }

    func testHealedMidWordPossessiveContinuationKeepsRank() async throws {
        let records = [
            record(1, " Rocke"), record(20, "feller's"), record(21, "y"), record(30, " and William")
        ]
        let logits: [[TokenID]: [TokenLogit]] = [
            []: [logit(1, 2.0)],
            [1]: [logit(20, 3.0), logit(21, 1.0)],
            [1, 21]: [logit(30, 1.0)]
        ]
        let healedRequest = CompletionRequest(
            context: TextFieldContext(beforeCursor: "The family name was Rocke", afterCursor: "", target: Self.testTarget),
            prompt: "",
            requiredPrefixBytes: Array(" Rocke".utf8),
            mode: .prose,
            maxCompletionTokens: 3,
            maxDisplayWidth: 80
        )

        let engine = ConstrainedGenerationEngine(runtime: runtime(logits), profile: profile(records))
        let candidates = try await engine.completions(for: healedRequest)
        XCTAssertEqual(Array(candidates.map(\.text).prefix(2)), [" Rockefeller's", " Rockey and William"])
    }

    // MARK: - Suffix-overlap truncation (ADR-057)

    /// A branch that emits a genuine middle and then runs into the suffix is salvaged: the engine
    /// truncates it at the overlap point and returns the real fill instead of discarding it.
    func testSuffixOverlapBranchIsTruncatedToTheMiddle() async throws {
        let profileRecords = profile([
            record(1, "Paris "), record(11, "the largest "), record(12, "city")
        ])
        let runtime = runtime([
            []: [logit(1, 1.0)],
            [1]: [logit(11, 1.0)],
            [1, 11]: [logit(12, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profileRecords,
            compatibilityStore: midLineEnabledStore()
        )

        // Field: "The capital of |the largest city". The model regurgitates the suffix after "Paris ".
        let candidates = try await engine.completions(for: CompletionRequest(
            context: TextFieldContext(beforeCursor: "The capital of ", afterCursor: "the largest city", target: Self.testTarget),
            prompt: "",
            mode: .prose,
            maxCompletionTokens: 3,
            maxDisplayWidth: 80
        ))

        XCTAssertEqual(candidates.map(\.text), ["Paris "], "the duplicating tail is cut, the middle survives")
    }

    /// A branch that is a suffix copy from the very first token has no salvageable middle and is
    /// dropped entirely — the engine shows nothing (the pre-ADR-057 outcome for this shape).
    func testWholeSuffixCopyIsDropped() async throws {
        let profileRecords = profile([
            record(1, "the "), record(2, "largest "), record(3, "city")
        ])
        let runtime = runtime([
            []: [logit(1, 1.0)],
            [1]: [logit(2, 1.0)],
            [1, 2]: [logit(3, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profileRecords,
            compatibilityStore: midLineEnabledStore()
        )

        let candidates = try await engine.completions(for: CompletionRequest(
            context: TextFieldContext(beforeCursor: "The capital of ", afterCursor: "the largest city", target: Self.testTarget),
            prompt: "",
            mode: .prose,
            maxCompletionTokens: 3,
            maxDisplayWidth: 80
        ))

        XCTAssertTrue(candidates.isEmpty, "a pure suffix copy is suppressed")
    }

    // MARK: - Suffix-likelihood rerank (ADR-057)

    /// Two non-duplicating mid-line candidates: the base-score order is [A, B], but B's middle makes
    /// the real suffix far more likely, so the round-trip rerank flips the order to [B, A].
    func testSuffixLikelihoodRerankReordersByJoinQuality() async throws {
        let profileRecords = profile([record(65, "A"), record(66, "B")])
        let runtime = runtime([
            []: [logit(65, 1.0), logit(66, 0.9)],     // base order: A above B
            [65]: [logit(90, -5.0), logit(91, 0.0)],  // after "A": the suffix token 'Z' is unlikely
            [66]: [logit(90, 0.0)]                     // after "B": the suffix token 'Z' is likely
        ])
        let config = DecodingConfiguration(maxCandidates: 5, suffixRerankTokenCount: 1, suffixRerankWeight: 1.0)
        let engine = ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profileRecords,
            compatibilityStore: midLineEnabledStore(),
            configuration: config
        )

        let candidates = try await engine.completions(for: CompletionRequest(
            context: TextFieldContext(beforeCursor: "", afterCursor: "Z", target: Self.testTarget),
            prompt: "",
            mode: .prose,
            maxCompletionTokens: 1,
            maxDisplayWidth: 80
        ))

        XCTAssertEqual(candidates.map(\.text), ["B", "A"], "the better join wins despite the lower base score")
    }

    /// The rerank is a strict no-op when the runtime returns no join logits (the property that keeps
    /// every stub-backed test stable): the base-score order [A, B] is preserved unchanged.
    func testSuffixLikelihoodRerankIsNoOpWithoutJoinLogits() async throws {
        let profileRecords = profile([record(65, "A"), record(66, "B")])
        // No paths scripted for [65] / [66], so the join probe returns empty logits.
        let runtime = runtime([
            []: [logit(65, 1.0), logit(66, 0.9)]
        ])
        let config = DecodingConfiguration(maxCandidates: 5, suffixRerankTokenCount: 1, suffixRerankWeight: 1.0)
        let engine = ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profileRecords,
            compatibilityStore: midLineEnabledStore(),
            configuration: config
        )

        let candidates = try await engine.completions(for: CompletionRequest(
            context: TextFieldContext(beforeCursor: "", afterCursor: "Z", target: Self.testTarget),
            prompt: "",
            mode: .prose,
            maxCompletionTokens: 1,
            maxDisplayWidth: 80
        ))

        XCTAssertEqual(candidates.map(\.text), ["A", "B"], "no join logits → order unchanged")
    }

    func testSuffixLikelihoodRerankBatchesJoinProbesUnderSharedPrefix() async throws {
        let profileRecords = profile([record(11, "x"), record(12, "y")])
        let runtime = CountingBatchRuntime(logitsByPath: [
            []: [logit(11, 1.0), logit(12, 0.9)],      // base order: x above y
            [97, 120]: [logit(90, -5.0), logit(91, 0.0)], // after "ax": suffix "Z" is unlikely
            [97, 121]: [logit(90, 0.0)]                // after "ay": suffix "Z" is likely
        ])
        let config = DecodingConfiguration(maxCandidates: 5, suffixRerankTokenCount: 1, suffixRerankWeight: 1.0)
        let engine = ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profileRecords,
            compatibilityStore: midLineEnabledStore(),
            configuration: config
        )

        let candidates = try await engine.completions(for: CompletionRequest(
            context: TextFieldContext(beforeCursor: "a", afterCursor: "Z", target: Self.testTarget),
            prompt: "",
            mode: .prose,
            maxCompletionTokens: 1,
            maxDisplayWidth: 80
        ))

        XCTAssertEqual(candidates.map(\.text), ["y", "x"], "batched join scoring preserves rerank quality")
        XCTAssertEqual(runtime.batchCalls, 2, "search and rerank should each use one batched call")
        XCTAssertEqual(runtime.batchRequests[1].anchor, [97], "rerank should prefill the shared prefix once")
        XCTAssertEqual(runtime.batchRequests[1].suffixes, [[120], [121]], "candidate-specific join tails stay exact")
    }
}
