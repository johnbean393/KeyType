import AutocompleteCore
import LlamaModelRuntime
import ModelRuntime
import XCTest

/// On-device benchmark used by M3 to derive `PromptBuilder.defaultMaxPromptTokens`.
/// Measures cold-prefill latency (`resetKVCache()` → `prepare(promptTokens:)`) across a
/// sweep of prompt sizes and picks the largest size whose p90 fits the 200 ms budget.
/// Also documents the warm KV-reuse speedup so the prompt-size ceiling is understood
/// as a worst-case (cache-miss) bound — steady-state keystrokes only pay for the
/// changed suffix and are far cheaper.
///
/// Skipped (via `XCTSkipUnless`) when the default model isn't present, so the suite
/// stays green on CI / fresh checkouts. See ADR-008 for the recorded measurement.
final class PrefillLatencyBenchmarkTests: XCTestCase {
    private static let tokenCounts: [Int] = [64, 128, 256, 512, 768, 1024, 1536, 2048, 3072, 4096]
    private static let trialsPerSize: Int = 6
    private static let warmupTokenCount: Int = 64
    /// The original cold-prefill budget. The shipped `PromptBuilder.defaultMaxPromptTokens`
    /// intentionally sits above this — see ADR-008 for the prefix-cache trade-off — so
    /// the benchmark records the curve up to the chosen ceiling rather than asserting
    /// the cold-path fits the budget at the ceiling.
    private static let coldP90BudgetMillis: Double = 200.0

    private func makeRuntime() throws -> LlamaModelRuntime {
        try XCTSkipUnless(
            ModelContainer.defaultModelExists(),
            "Model file not present at \(ModelContainer.defaultModelFilename); skipping prefill latency benchmark"
        )
        let url = try ModelContainer.modelURL()
        // Headroom over the largest swept prompt size so the runtime can hold it
        // without re-sliding the KV cache.
        return try LlamaModelRuntime(modelURL: url, contextLength: 5120, reuseThreshold: 8)
    }

    /// Cold prefill p90 across a sweep of prompt sizes. The printed curve is the real
    /// result — it both records the largest size whose cold p90 fits the 200 ms cold
    /// budget *and* the actual cold-prefill cost at the shipped
    /// `PromptBuilder.defaultMaxPromptTokens` (which sits above that budget; see
    /// ADR-008). The test only asserts a sanity floor.
    func testColdPrefillP90CurveMeetsBudget() async throws {
        let runtime = try makeRuntime()
        let source = try buildLongTokenSource(
            runtime: runtime,
            atLeast: Self.tokenCounts.max() ?? 2048
        )

        // Warm up llama: small prepare so any first-call setup (Metal kernel JIT, lazy
        // memory mapping) doesn't get counted into the first measured prompt.
        try await runtime.prepare(promptTokens: Array(source.prefix(Self.warmupTokenCount)))
        await runtime.resetKVCache()

        var lines: [String] = []
        lines.append(" size       n   p50ms   p90ms   maxms")
        var coldBudgetCeiling = 0

        for size in Self.tokenCounts where size <= source.count {
            var measured: [Double] = []
            for _ in 0..<Self.trialsPerSize {
                await runtime.resetKVCache()
                let prompt = Array(source.prefix(size))
                let start = Date()
                try await runtime.prepare(promptTokens: prompt)
                let elapsedMs = Date().timeIntervalSince(start) * 1000.0
                measured.append(elapsedMs)
            }
            let sorted = measured.sorted()
            let p50 = percentile(sorted, 0.5)
            let p90 = percentile(sorted, 0.9)
            let mx = sorted.last ?? 0
            lines.append(String(format: "%5d  %6d  %7.1f  %7.1f  %7.1f", size, sorted.count, p50, p90, mx))
            if p90 <= Self.coldP90BudgetMillis { coldBudgetCeiling = size }
        }

        let report = lines.joined(separator: "\n")
        print("[prefill-latency] cold prefill p90 curve (cold budget \(Self.coldP90BudgetMillis) ms):\n\(report)")
        print("[prefill-latency] largest size with cold p90 <= \(Self.coldP90BudgetMillis) ms: \(coldBudgetCeiling) tokens")
        print("[prefill-latency] shipped PromptBuilder.defaultMaxPromptTokens (steady-state-sized): 4096 tokens")
        XCTAssertGreaterThanOrEqual(
            coldBudgetCeiling, 256,
            "cold prefill ceiling should clear at least 256 tokens for KeyType to feel responsive on a fresh focus; got \(coldBudgetCeiling)"
        )
    }

    /// Documents that warm KV-reuse is cheap — identical re-prepares are a no-op and
    /// extending the prompt by one token only decodes that one token. This is why the
    /// 200 ms ceiling is a cache-miss bound, not a steady-state cost.
    func testWarmKVReuseIsCheap() async throws {
        let runtime = try makeRuntime()
        let source = try buildLongTokenSource(runtime: runtime, atLeast: 512)
        let prompt = Array(source.prefix(512))

        await runtime.resetKVCache()
        let coldStart = Date()
        try await runtime.prepare(promptTokens: prompt)
        let coldMs = Date().timeIntervalSince(coldStart) * 1000.0

        var warmMs: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            try await runtime.prepare(promptTokens: prompt)
            warmMs.append(Date().timeIntervalSince(start) * 1000.0)
        }

        let extended = prompt + [prompt.last!]
        let extendStart = Date()
        try await runtime.prepare(promptTokens: extended)
        let extendMs = Date().timeIntervalSince(extendStart) * 1000.0

        print("[prefill-latency] 512-tok cold prefill: \(String(format: "%.1f", coldMs)) ms")
        print("[prefill-latency] 512-tok warm KV-reuse re-prepare: \(warmMs.map { String(format: "%.2f", $0) })")
        print("[prefill-latency] extend 512 → 513 tokens: \(String(format: "%.2f", extendMs)) ms")
        XCTAssertLessThan(
            warmMs.max() ?? .infinity,
            Self.coldP90BudgetMillis,
            "warm KV-reuse should be well under the cold-prefill budget"
        )
    }

    /// Like-for-like reference for the MLX runtime benchmark: same prompt, suffix set, request
    /// count, and percentile convention. Set `KEYTYPE_LLAMA_MODEL_PATH` to compare another local
    /// GGUF catalog variant. It is opt-in because performance data is meaningful only in a
    /// release build on the machine being reported.
    func testWarmAnchoredLatencyBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["KEYTYPE_LLAMA_RUN_BENCHMARK"] == "1" else {
            throw XCTSkip("set KEYTYPE_LLAMA_RUN_BENCHMARK=1 to run the 200-request benchmark")
        }
        let modelURL: URL
        if let modelPath = ProcessInfo.processInfo.environment["KEYTYPE_LLAMA_MODEL_PATH"], !modelPath.isEmpty {
            modelURL = URL(fileURLWithPath: modelPath)
            try XCTSkipUnless(ModelContainer.modelExists(at: modelURL), "requested GGUF is not installed")
        } else {
            try XCTSkipUnless(ModelContainer.defaultModelExists(), "default Qwen 2B GGUF is not installed")
            modelURL = try ModelContainer.modelURL()
        }

        let loadStart = DispatchTime.now().uptimeNanoseconds
        let runtime = try LlamaModelRuntime(modelURL: modelURL)
        let coldLoadMillis = elapsedMillis(since: loadStart)
        var samples: [Double] = []
        samples.reserveCapacity(200)
        do {
            let anchor = try runtime.tokenizer.tokenize("The quick brown fox")
            let suffixes = try [" jumps", " runs", " walks", " moves", " waits", " speaks", " writes", " works"]
                .map { try runtime.tokenizer.tokenize($0) }
            let firstVisibleStart = DispatchTime.now().uptimeNanoseconds
            _ = try await runtime.anchoredLogits(anchor: anchor, suffix: suffixes[0])
            let firstVisibleMillis = elapsedMillis(since: firstVisibleStart)
            var rng = DeterministicBenchmarkRNG(seed: 0x4D4C585F323030)

            for _ in 0..<200 {
                let suffix = suffixes[rng.nextIndex(upperBound: suffixes.count)]
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)
                samples.append(elapsedMillis(since: start))
            }
            let sorted = samples.sorted()
            let meanPromptTokens = Double(suffixes.map { anchor.count + $0.count }.reduce(0, +)) / Double(suffixes.count)
            print(
                "[llama-benchmark] requests=200 cold_load_ms=\(format(coldLoadMillis)) "
                    + "first_visible_ms=\(format(firstVisibleMillis)) "
                    + "warm_p50_ms=\(format(percentile(sorted, 0.50))) "
                    + "warm_p90_ms=\(format(percentile(sorted, 0.90))) "
                    + "warm_p95_ms=\(format(percentile(sorted, 0.95))) "
                    + "mean_prompt_tokens=\(format(meanPromptTokens)) forward_passes=200"
            )
        } catch {
            await runtime.shutdown()
            throw error
        }
        let sorted = samples.sorted()
        await runtime.shutdown()
        XCTAssertEqual(samples.count, 200)
    }

    // MARK: - Helpers

    /// Builds a tokenized ASCII source long enough to slice off `n` tokens. ASCII pangrams
    /// keep BPE behaviour representative of real typing without hitting rare-glyph paths.
    private func buildLongTokenSource(runtime: LlamaModelRuntime, atLeast n: Int) throws -> [TokenID] {
        let paragraph = """
        The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. \
        Sphinx of black quartz, judge my vow. How vexingly quick daft zebras jump! \
        Bright vixens jump; dozy fowl quack. Crazy Fredrick bought many very exquisite opal jewels. \
        Heavy boxes perform quick waltzes and jigs. A wizard's job is to vex chumps quickly in fog.
        """
        var text = ""
        var tokens: [TokenID] = []
        while tokens.count < n {
            text += paragraph + "\n"
            tokens = try runtime.tokenizer.tokenize(text)
        }
        return tokens
    }

    /// Nearest-rank percentile (matches `numpy.percentile(..., interpolation="lower")`),
    /// which is what we want for latency p90: don't smooth the worst case away.
    private func percentile(_ sortedSamples: [Double], _ p: Double) -> Double {
        guard !sortedSamples.isEmpty else { return 0 }
        let rank = Int((Double(sortedSamples.count) * p).rounded(.up)) - 1
        let idx = min(max(rank, 0), sortedSamples.count - 1)
        return sortedSamples[idx]
    }

    private func elapsedMillis(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000.0
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private struct DeterministicBenchmarkRNG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func nextIndex(upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int(state % UInt64(upperBound))
        }
    }
}
