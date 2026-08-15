import XCTest
import Foundation
import AutocompleteCore
import ModelRuntime
@testable import MLXModelRuntime

final class MLXModelRuntimeTests: XCTestCase {
    func testLoaderRejectsMissingDirectory() async {
        do {
            _ = try await MLXModelLoader.load(
                modelDirectory: URL(fileURLWithPath: "/tmp/keytype-missing-mlx-model")
            )
            XCTFail("expected missing-directory error")
        } catch let error as MLXRuntimeError {
            XCTAssertEqual(
                error,
                .modelDirectoryMissing("/tmp/keytype-missing-mlx-model")
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLocalModelMetadataAndTokenizer() async throws {
        let runtime = try await loadLocalRuntime()
        addTeardownBlock { await runtime.shutdown() }

        XCTAssertEqual(runtime.metadata.family, "qwen3-v151936")
        XCTAssertGreaterThan(runtime.metadata.vocabularySize, 100_000)
        XCTAssertGreaterThan(runtime.metadata.contextLength, 0)

        let imStart = try runtime.mlxTokenizer.tokenizeAllowingSpecial("<|im_start|>")
        XCTAssertEqual(imStart, [248045])
        XCTAssertTrue(runtime.mlxTokenizer.isSpecialToken(248045))
        XCTAssertEqual(try runtime.mlxTokenizer.rawBytes(for: 248045), [])

        let introspector = MLXVocabIntrospector(runtime: runtime)
        XCTAssertEqual(introspector.attr(for: 248045), .control)
        XCTAssertEqual(introspector.role(of: runtime.metadata.eosTokenID ?? -1), .eos)
        let digest = try runtime.mlxTokenizer.tokenizerDigest()
        XCTAssertEqual(digest.lo, 2_452_974_444_257_079_205)
        XCTAssertEqual(digest.hi, 9_295_119_246_367_943_770)

        let samples = ["hello", "Hello, world!", " leading whitespace", "naïve café"]
        for sample in samples {
            let tokens = try runtime.tokenizer.tokenize(sample)
            XCTAssertFalse(tokens.isEmpty)
            XCTAssertEqual(try runtime.tokenizer.detokenize(tokens), sample)

            var bytes: [UInt8] = []
            for token in tokens {
                bytes.append(contentsOf: try runtime.tokenizer.rawBytes(for: token))
            }
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), sample)
        }
    }

    func testPrepareDecodeAndAnchoredBatchParity() async throws {
        let runtime = try await loadLocalRuntime()
        addTeardownBlock { await runtime.shutdown() }

        let anchor = try runtime.tokenizer.tokenize("The quick brown fox")
        let suffix = try runtime.tokenizer.tokenize(" jumps")
        try await runtime.prepare(promptTokens: anchor)
        let logits = try await runtime.logitsForNextToken()
        XCTAssertEqual(logits.count, runtime.metadata.vocabularySize)
        XCTAssertTrue(logits.allSatisfy { $0.logit.isFinite })

        let branch = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)
        let batch = try await runtime.anchoredLogitsBatch(
            anchor: anchor,
            suffixes: [[], suffix, suffix + (try runtime.tokenizer.tokenize("."))]
        )
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch[1], branch)
        let rootLogits = try await runtime.anchoredLogits(anchor: anchor, suffix: [])
        XCTAssertEqual(batch[0], rootLogits)

        let ranked = try await runtime.rankNextTokensBatch(
            anchor: anchor,
            suffixes: [suffix],
            constraints: [RuntimeTokenConstraint()],
            topK: 5
        )
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].count, 5)
        XCTAssertEqual(ranked[0].first?.tokenID, branch.max(by: { $0.logit < $1.logit })?.tokenID)

        let fresh = try await loadLocalRuntime()
        addTeardownBlock { await fresh.shutdown() }
        try await fresh.prepare(promptTokens: anchor + suffix)
        let freshLogits = try await fresh.logitsForNextToken()
        XCTAssertEqual(freshLogits.count, branch.count)
        XCTAssertEqual(
            freshLogits.max(by: { $0.logit < $1.logit })?.tokenID,
            branch.max(by: { $0.logit < $1.logit })?.tokenID
        )
    }

    func testEmptyAnchorScoresSingleAndBatchSuffixes() async throws {
        let runtime = try await loadLocalRuntime()
        addTeardownBlock { await runtime.shutdown() }

        let staleAnchor = try runtime.tokenizer.tokenize("stale prompt")
        let suffix = try runtime.tokenizer.tokenize("fresh suffix")
        try await runtime.prepare(promptTokens: staleAnchor)

        let single = try await runtime.anchoredLogits(anchor: [], suffix: suffix)
        let batch = try await runtime.anchoredLogitsBatch(anchor: [], suffixes: [[], suffix])

        let fresh = try await loadLocalRuntime()
        addTeardownBlock { await fresh.shutdown() }
        try await fresh.prepare(promptTokens: suffix)
        let expected = try await fresh.logitsForNextToken()

        XCTAssertEqual(batch.count, 2)
        XCTAssertTrue(batch[0].isEmpty)
        XCTAssertEqual(topTokenIDs(single), topTokenIDs(expected))
        XCTAssertEqual(topTokenIDs(batch[1]), topTokenIDs(expected))
    }

    func testShutdownMakesRuntimeInert() async throws {
        let runtime = try await loadLocalRuntime()
        await runtime.shutdown()

        do {
            _ = try await runtime.logitsForNextToken()
            XCTFail("expected shutdown error")
        } catch let error as MLXRuntimeError {
            XCTAssertEqual(error, .runtimeShutdown)
        }
    }

    func testWarmAnchoredLatencyBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["KEYTYPE_MLX_RUN_BENCHMARK"] == "1" else {
            throw XCTSkip("set KEYTYPE_MLX_RUN_BENCHMARK=1 to run the 200-request benchmark")
        }

        let path = try modelDirectoryPath()
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let runtime = try await MLXModelLoader.load(
            modelDirectory: URL(fileURLWithPath: path),
            family: "qwen3-v151936"
        )
        let coldLoadMillis = elapsedMillis(since: loadStart)
        addTeardownBlock { await runtime.shutdown() }

        let anchor = try runtime.tokenizer.tokenize("The quick brown fox")
        let suffix = try runtime.tokenizer.tokenize(" jumps")
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)

        var samples: [Double] = []
        samples.reserveCapacity(200)
        for _ in 0..<200 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)
            samples.append(elapsedMillis(since: start))
        }

        let sorted = samples.sorted()
        print(
            "[mlx-benchmark] requests=200 cold_load_ms=\(format(coldLoadMillis)) "
                + "warm_p50_ms=\(format(percentile(sorted, 0.50))) "
                + "warm_p90_ms=\(format(percentile(sorted, 0.90))) "
                + "warm_p95_ms=\(format(percentile(sorted, 0.95)))"
        )
        XCTAssertEqual(samples.count, 200)
    }

    private func loadLocalRuntime(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> MLXLocalModelRuntime {
        let path = try modelDirectoryPath(file: file, line: line)
        return try await MLXModelLoader.load(
            modelDirectory: URL(fileURLWithPath: path),
            family: "qwen3-v151936"
        )
    }

    private func modelDirectoryPath(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        guard let path = ProcessInfo.processInfo.environment["KEYTYPE_MLX_MODEL_DIR"],
              !path.isEmpty
        else {
            throw XCTSkip("KEYTYPE_MLX_MODEL_DIR is not set")
        }
        return path
    }

    private func elapsedMillis(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000.0
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return sorted[index]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func topTokenIDs(_ logits: [TokenLogit], count: Int = 5) -> [TokenID] {
        logits
            .sorted {
                if $0.logit == $1.logit { return $0.tokenID < $1.tokenID }
                return $0.logit > $1.logit
            }
            .prefix(count)
            .map(\.tokenID)
    }
}
