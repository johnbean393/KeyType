import XCTest
@testable import TokenProfiles

/// Cache-busting via the VALIDATION section's `generator_version` string. The tokenizer digest
/// covers only vocab bytes, so a `TokenClassifier` logic change (which alters the baked
/// `.excluded`/`.special` flags and trie) leaves the digest unchanged. `generator_version` captures
/// that logic version; `MmapAutocompleteProfile.init` rejects a profile stamped with anything other
/// than the build's expected value so `ProfileGenerator` rebuilds. See `ACPF.generatorVersion`.
final class GeneratorVersionTests: XCTestCase {

    /// The binary format version stays at 1 — the P0 classifier change is a *content* change, busted
    /// via `generatorVersion`, not the on-disk layout. Guards against re-introducing the schema bump.
    func testSchemaVersionRemainsOne() {
        XCTAssertEqual(ACPF.currentSchemaVersion, 1)
    }

    private func encode(generatorVersion: String) throws -> Data {
        let built = SyntheticVocabFixture.build()
        let input = ACPFProfileInput(
            modelFamily: built.modelFamily,
            vocabSize: built.vocabSize,
            tokenizerDigest: built.digest,
            entries: built.entries,
            ggufMetadataDigest: "synthetic-gguf-digest",
            generatorVersion: generatorVersion,
            builderHost: "synthetic-host",
            buildTimestamp: Date(timeIntervalSince1970: 1_716_000_000),
            headerFlags: 0
        )
        return try ACPFWriter.encode(input)
    }

    func testMatchingGeneratorVersionOpens() throws {
        let data = try encode(generatorVersion: "keytype-acpf-1.1")
        XCTAssertNoThrow(try MmapAutocompleteProfile(data: data, expectedGeneratorVersion: "keytype-acpf-1.1"))
    }

    func testStaleGeneratorVersionIsRejected() throws {
        let data = try encode(generatorVersion: "keytype-acpf-1.0")
        XCTAssertThrowsError(
            try MmapAutocompleteProfile(data: data, expectedGeneratorVersion: "keytype-acpf-1.1")
        ) { error in
            guard case let ACPFOpenError.generatorVersionMismatch(expected, found) = error else {
                return XCTFail("expected generatorVersionMismatch, got \(error)")
            }
            XCTAssertEqual(expected, "keytype-acpf-1.1")
            XCTAssertEqual(found, "keytype-acpf-1.0")
        }
    }

    /// Passing `nil` opts out of the check (format round-trip tests that write arbitrary versions).
    func testNilExpectationSkipsCheck() throws {
        let data = try encode(generatorVersion: "anything-goes")
        XCTAssertNoThrow(try MmapAutocompleteProfile(data: data, expectedGeneratorVersion: nil))
    }

    /// Back-compat: a profile with an empty/unstamped generator_version skips the check rather than
    /// being rejected, so older profiles without the stamp still open. Only a present, non-empty,
    /// non-matching value is a hard mismatch.
    func testEmptyStampSkipsCheckForBackCompat() throws {
        let data = try encode(generatorVersion: "")
        XCTAssertNoThrow(try MmapAutocompleteProfile(data: data, expectedGeneratorVersion: "keytype-acpf-1.1"))
    }

    /// The default expectation is the build's current `ACPF.generatorVersion`, so a profile this build
    /// produces opens with no explicit argument — and a stale one does not.
    func testDefaultExpectationUsesCurrentBuildVersion() throws {
        let current = try encode(generatorVersion: ACPF.generatorVersion)
        XCTAssertNoThrow(try MmapAutocompleteProfile(data: current))

        let stale = try encode(generatorVersion: "keytype-acpf-0.0")
        XCTAssertThrowsError(try MmapAutocompleteProfile(data: stale))
    }
}
