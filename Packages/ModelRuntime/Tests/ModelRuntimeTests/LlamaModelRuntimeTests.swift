import AutocompleteCore
import LlamaModelRuntime
import ModelRuntime
import XCTest

/// On-device tests that require the GGUF placed at
/// `~/Library/Application Support/KeyType/Models/<defaultModelFilename>` (see ADR-007).
/// They `XCTSkipUnless(modelExists)` so the package's test suite stays green on machines
/// that haven't dropped a model into the container yet.
final class LlamaModelRuntimeTests: XCTestCase {
    private func makeRuntime(contextLength: Int = 1024, reuseThreshold: Int = 4) throws -> LlamaModelRuntime {
        try XCTSkipUnless(
            ModelContainer.defaultModelExists(),
            "Model file not present at \(ModelContainer.defaultModelFilename); skipping"
        )
        let url = try ModelContainer.modelURL()
        return try LlamaModelRuntime(
            modelURL: url,
            contextLength: contextLength,
            reuseThreshold: reuseThreshold
        )
    }

    func testMetadataIsPopulated() async throws {
        let runtime = try makeRuntime()
        XCTAssertEqual(runtime.metadata.family, "llama")
        XCTAssertGreaterThan(runtime.metadata.vocabularySize, 1000)
        XCTAssertGreaterThan(runtime.metadata.contextLength, 0)
    }

    func testTokenizerRoundTripsASCII() async throws {
        let runtime = try makeRuntime()
        let tokenizer = runtime.tokenizer
        let samples = [
            "hello",
            "Hello, world!",
            "The quick brown fox jumps over the lazy dog.",
            "x = 1 + 2"
        ]
        for sample in samples {
            let tokens = try tokenizer.tokenize(sample)
            XCTAssertFalse(tokens.isEmpty, "tokenize produced empty array for '\(sample)'")
            let back = try tokenizer.detokenize(tokens)
            XCTAssertEqual(back, sample, "round trip differed for '\(sample)'")
        }
    }

    func testTokenizerRawBytesConcatToDetokenizedText() async throws {
        let runtime = try makeRuntime()
        let tokenizer = runtime.tokenizer
        let sample = "Hello world"
        let tokens = try tokenizer.tokenize(sample)
        var concatenated: [UInt8] = []
        for t in tokens {
            concatenated.append(contentsOf: try tokenizer.rawBytes(for: t))
        }
        let joined = String(decoding: concatenated, as: UTF8.self)
        let detokenized = try tokenizer.detokenize(tokens)
        XCTAssertEqual(joined, detokenized)
    }

    func testProducesPlausibleNextTokenLogitsAndCanDecodeN() async throws {
        let runtime = try makeRuntime()
        let tokens = try runtime.tokenizer.tokenize("The quick brown fox")
        try await runtime.prepare(promptTokens: tokens)
        let logits = try await runtime.logitsForNextToken()
        XCTAssertEqual(logits.count, runtime.metadata.vocabularySize)
        XCTAssertTrue(logits.allSatisfy { $0.logit.isFinite })
        let maxLogit = logits.map { $0.logit }.max() ?? -.infinity
        let minLogit = logits.map { $0.logit }.min() ?? .infinity
        XCTAssertGreaterThan(maxLogit, minLogit, "logits should not be all equal")

        for _ in 0..<4 {
            let ranked = logits.max(by: { $0.logit < $1.logit })!
            try await runtime.decodeNext(tokenID: ranked.tokenID)
        }
        // Smoke: after decoding more tokens we can still read fresh logits.
        let later = try await runtime.logitsForNextToken()
        XCTAssertEqual(later.count, runtime.metadata.vocabularySize)
        XCTAssertTrue(later.allSatisfy { $0.logit.isFinite })
    }

    /// Identical-prompt KV reuse is implemented as a true no-op (no `llama_decode` call,
    /// the previous logits buffer stays intact), so the result must be bit-for-bit equal
    /// to the original full-decode logits.
    func testKVReuseProducesIdenticalLogitsForUnchangedPrefix() async throws {
        let runtime = try makeRuntime(reuseThreshold: 4)
        let prompt = try runtime.tokenizer.tokenize("The quick brown fox jumps over")
        XCTAssertGreaterThanOrEqual(prompt.count, 5, "prompt should produce >= 5 tokens for the reuse check")

        try await runtime.prepare(promptTokens: prompt)
        let lFull = try await runtime.logitsForNextToken()
        let firstDecoded = await runtime.lastPrepareDecodedCount
        XCTAssertEqual(firstDecoded, prompt.count, "fresh prepare should decode the whole prompt")

        try await runtime.prepare(promptTokens: prompt)
        let lReuse = try await runtime.logitsForNextToken()
        let secondDecoded = await runtime.lastPrepareDecodedCount
        XCTAssertEqual(
            secondDecoded, 0,
            "identical prompt should be a complete no-op via KV reuse"
        )

        XCTAssertEqual(lFull.count, lReuse.count)
        for i in 0..<lFull.count {
            XCTAssertEqual(
                lFull[i].logit, lReuse[i].logit,
                "logit at index \(i) drifted between full decode and KV-reuse decode"
            )
        }
    }

    /// Extending a known prefix re-decodes exactly the new suffix. For hybrid attention
    /// models (e.g. the Qwen3.5 test GGUF here, which mixes standard attention with linear/
    /// Gated Delta Net layers) the fused Metal kernels are not bit-identical across the
    /// "full-decode-of-N" vs "suffix-decode-after-seq_rm" code paths, so we assert numerical
    /// closeness + top-k argmax agreement rather than literal `==`. For a fully-attention
    /// model these would degenerate to bit-exact equality anyway.
    func testKVReuseExtendsPrefixWithoutRedoingPrefix() async throws {
        let runtime = try makeRuntime(reuseThreshold: 4)
        let prefix = try runtime.tokenizer.tokenize("The quick brown fox jumps over")
        let suffix = try runtime.tokenizer.tokenize(" the lazy dog.")
        let extended = prefix + suffix
        XCTAssertGreaterThan(suffix.count, 0)

        try await runtime.prepare(promptTokens: prefix)
        try await runtime.prepare(promptTokens: extended)
        let reuseDecoded = await runtime.lastPrepareDecodedCount
        XCTAssertEqual(
            reuseDecoded, suffix.count,
            "extending the prompt should re-decode exactly the new suffix"
        )
        let lReuse = try await runtime.logitsForNextToken()

        let fresh = try makeRuntime(reuseThreshold: 4)
        try await fresh.prepare(promptTokens: extended)
        let freshDecoded = await fresh.lastPrepareDecodedCount
        XCTAssertEqual(freshDecoded, extended.count)
        let lFresh = try await fresh.logitsForNextToken()

        XCTAssertEqual(lFresh.count, lReuse.count)
        Self.assertLogitsNumericallyEqual(lFresh, lReuse, label: "extend-vs-fresh")
        Self.assertTopKArgmaxAgrees(lFresh, lReuse, k: 5, label: "extend-vs-fresh")
    }

    // MARK: - Helpers

    /// Asserts that two logit vectors agree within absolute tolerance on every dimension.
    /// The tolerance is intentionally loose (1e-1) to absorb fused-kernel nondeterminism;
    /// downstream sampling uses softmax + top-k/top-p, where these drifts are immaterial.
    private static func assertLogitsNumericallyEqual(
        _ a: [TokenLogit],
        _ b: [TokenLogit],
        atol: Float = 1e-1,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(a.count, b.count, "\(label): logit array lengths differ", file: file, line: line)
        var worstIdx: Int = -1
        var worstDiff: Float = 0
        for i in 0..<min(a.count, b.count) {
            let diff = abs(a[i].logit - b[i].logit)
            if diff > worstDiff {
                worstDiff = diff
                worstIdx = i
            }
        }
        XCTAssertLessThanOrEqual(
            worstDiff, atol,
            "\(label): worst logit drift \(worstDiff) at index \(worstIdx) exceeds tolerance \(atol)",
            file: file, line: line
        )
    }

    /// Asserts that the top-K tokens (by logit) are the same set in both vectors.
    /// This is the meaningful semantic check: if the two decoders pick the same next-token
    /// candidates, the autocomplete output will be identical.
    private static func assertTopKArgmaxAgrees(
        _ a: [TokenLogit],
        _ b: [TokenLogit],
        k: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let topA = Set(a.sorted { $0.logit > $1.logit }.prefix(k).map { $0.tokenID })
        let topB = Set(b.sorted { $0.logit > $1.logit }.prefix(k).map { $0.tokenID })
        XCTAssertEqual(topA, topB, "\(label): top-\(k) argmax sets disagree", file: file, line: line)
    }

    func testResetKVCacheClearsResidentTokens() async throws {
        let runtime = try makeRuntime()
        let prompt = try runtime.tokenizer.tokenize("Hello world")
        try await runtime.prepare(promptTokens: prompt)
        await runtime.resetKVCache()
        let beforeReprepare = await runtime.lastPrepareDecodedCount
        XCTAssertEqual(beforeReprepare, 0)
        try await runtime.prepare(promptTokens: prompt)
        let afterReset = await runtime.lastPrepareDecodedCount
        XCTAssertEqual(afterReset, prompt.count, "reset should force a full decode next prepare")
    }
}
