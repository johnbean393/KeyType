import AutocompleteCore
import XCTest
@testable import TokenProfiles

/// Regression tests for **duplicate-byte tokenizers** (e.g. Gemma): two distinct token
/// ids whose raw bytes are byte-for-byte identical. A byte-keyed prefix trie cannot give
/// each id its own terminal node — they collide on one node that can only store a single
/// terminal id. The post-build self-check and the trie-state admissibility query must
/// therefore reason about *bytes*, not token-id identity.
///
/// Before the fix, generating a Gemma profile aborted in `BuildProfile.run` with
/// `[triePresence] token 239 reached state 2 but terminal=Optional(249732)`, so the model
/// could not be used after selection.
final class DuplicateTokenTrieTests: XCTestCase {

    private static let duplicateBytes = Array("ab".utf8)

    /// Builds a minimal profile from `(id, bytes, flags)` specs. Tokens whose `flags`
    /// contain `.excluded` are kept out of the prefix trie by the writer.
    private func makeProfile(
        _ specs: [(TokenID, [UInt8], TokenProfileFlags)]
    ) throws -> MmapAutocompleteProfile {
        let entries = specs.map { id, bytes, flags in
            ACPFTokenEntry(
                tokenID: id,
                bytes: bytes,
                flags: flags,
                staticBias: 0,
                displayWidth: bytes.count,
                tokenType: 0
            )
        }
        let digest = ACPFTokenizerDigest.digest(vocabSize: specs.count) { id in
            specs[Int(id)].1
        }
        let input = ACPFProfileInput(
            modelFamily: "dup-v\(specs.count)",
            vocabSize: specs.count,
            tokenizerDigest: digest,
            entries: entries,
            ggufMetadataDigest: "dup-gguf",
            builderHost: "dup-host",
            buildTimestamp: Date(timeIntervalSince1970: 1_716_000_000)
        )
        return try MmapAutocompleteProfile(data: ACPFWriter.encode(input))
    }

    /// id 0 = "a", id 1 = "b", id 2 = "ab", id 3 = "ab" (a byte-for-byte duplicate of id
    /// 2). All non-excluded, so all four are inserted into the trie; ids 2 and 3 collide
    /// on the single "ab" node.
    private func makeDuplicateProfile() throws -> MmapAutocompleteProfile {
        try makeProfile([
            (0, Array("a".utf8), TokenProfileFlags()),
            (1, Array("b".utf8), TokenProfileFlags()),
            (2, Self.duplicateBytes, TokenProfileFlags()),
            (3, Self.duplicateBytes, TokenProfileFlags()),
        ])
    }

    func testSelfCheckAcceptsDuplicateByteTokens() throws {
        let profile = try makeDuplicateProfile()
        let report = ProfileSelfCheck.runAll(on: profile)
        XCTAssertTrue(
            report.isSuccess,
            "self-check should accept duplicate-byte tokens; failures: \(report.failures)"
        )
        XCTAssertFalse(
            report.failures.contains { $0.check == "triePresence" },
            "triePresence must not flag a genuine duplicate-byte token"
        )
    }

    func testDuplicateBytesResolveToOneTerminalNode() throws {
        let profile = try makeDuplicateProfile()
        guard let state = profile.prefixStart(requiredBytes: Self.duplicateBytes) else {
            return XCTFail("duplicate bytes not walkable from root")
        }
        // The byte-keyed trie stores exactly one terminal id for the shared "ab" node; it
        // is one of the two duplicates (which one depends only on writer insertion order,
        // an implementation detail we deliberately don't pin).
        let terminal = profile.terminalTokenID(at: state)
        XCTAssertTrue(
            terminal == 2 || terminal == 3,
            "terminal at the shared 'ab' node should be a duplicate id, got \(terminal as Any)"
        )
    }

    func testTokenAllowedAcceptsBothDuplicates() throws {
        let profile = try makeDuplicateProfile()
        let root = TrieState(nodeIndex: 0)
        // Both ids walk to the shared terminal node, so both must be admissible even
        // though only one is stored as that node's terminal id.
        XCTAssertTrue(profile.tokenAllowed(2, in: root), "duplicate id 2 must be allowed")
        XCTAssertTrue(profile.tokenAllowed(3, in: root), "duplicate id 3 must be allowed")
    }

    func testExcludedDuplicateIsNotAdmittedByTrieState() throws {
        // id 2 "ab" is allowed; id 3 "ab" is excluded. The writer inserts only id 2, so
        // the shared "ab" node's terminal is 2. Querying the excluded id 3 must NOT be
        // admitted just because its bytes match a non-excluded duplicate — excluded tokens
        // are never trie members, and suppression must hold.
        let profile = try makeProfile([
            (0, Array("a".utf8), TokenProfileFlags()),
            (1, Array("b".utf8), TokenProfileFlags()),
            (2, Self.duplicateBytes, TokenProfileFlags()),
            (3, Self.duplicateBytes, [.excluded]),
        ])
        let root = TrieState(nodeIndex: 0)
        XCTAssertTrue(profile.tokenAllowed(2, in: root), "allowed duplicate id 2 must be admitted")
        XCTAssertFalse(profile.tokenAllowed(3, in: root), "excluded duplicate id 3 must NOT be admitted")
        // The self-check skips excluded tokens and still validates the allowed one.
        let report = ProfileSelfCheck.runAll(on: profile)
        XCTAssertTrue(report.isSuccess, "self-check failures: \(report.failures)")
    }
}
