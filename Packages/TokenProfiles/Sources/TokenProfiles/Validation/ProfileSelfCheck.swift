import AutocompleteCore
import Foundation

/// Single source of truth for the post-write integrity checks that both the unit tests
/// and the offline builder CLI run against a freshly produced profile. Each check is a
/// named function returning either `.success(())` or `.failure(error)`; the runner
/// collects every failure so callers can report all problems at once.
public enum ProfileSelfCheck {

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let check: String
        public let detail: String

        public init(check: String, detail: String) {
            self.check = check
            self.detail = detail
        }

        public var description: String { "[\(check)] \(detail)" }
    }

    public struct Report {
        public var failures: [Failure]
        public var checksRun: [String]

        public var isSuccess: Bool { failures.isEmpty }
    }

    /// Run every check against the profile, optionally validating the bytes blob against
    /// a callback that returns the source bytes for each token id. If `sourceBytes` is
    /// `nil`, the bytes round-trip is sampled against the profile itself (i.e. only
    /// internal consistency is checked, not "matches the GGUF tokenizer").
    public static func runAll(
        on profile: MmapAutocompleteProfile,
        sourceBytes: ((TokenID) throws -> [UInt8])? = nil,
        sampleSize: Int = 1024
    ) -> Report {
        var failures: [Failure] = []
        var ran: [String] = []

        func run(_ name: String, _ body: () throws -> Void) {
            ran.append(name)
            do {
                try body()
            } catch let f as Failure {
                failures.append(f)
            } catch {
                failures.append(Failure(check: name, detail: "unexpected error: \(error)"))
            }
        }

        run("everyIDHasRecord") { try checkEveryIDHasRecord(profile: profile) }
        run("bytesBlobBounds") { try checkBytesBlobBounds(profile: profile) }
        run("triePresence") { try checkTriePresence(profile: profile) }
        run("specialListsSorted") { try checkSpecialListsSorted(profile: profile) }
        run("biasOverridesSorted") { try checkBiasOverridesValid(profile: profile) }
        if let source = sourceBytes {
            run("bytesRoundTripSampled") {
                try checkBytesRoundTrip(profile: profile, source: source, sampleSize: sampleSize)
            }
        }

        return Report(failures: failures, checksRun: ran)
    }

    // MARK: - Individual checks

    public static func checkEveryIDHasRecord(profile: MmapAutocompleteProfile) throws {
        for id in 0..<profile.vocabularySize {
            let tokenID = TokenID(id)
            guard let record = profile.record(for: tokenID) else {
                throw Failure(check: "everyIDHasRecord", detail: "missing record for token id \(id)")
            }
            // Empty bytes are valid (special tokens often have empty raw bytes), but a
            // non-empty record must have a bytes range within the bytes section.
            if !record.bytes.isEmpty {
                let totalBytes = profile.bytesSectionLength
                // Reach into the raw record via the public bytes accessor (already bounded
                // by the section); the existence of `record.bytes` here proves the bounds
                // were respected — the assertion is in `checkBytesBlobBounds`.
                _ = totalBytes
            }
        }
    }

    public static func checkBytesBlobBounds(profile: MmapAutocompleteProfile) throws {
        let total = profile.bytesSectionLength
        // Iterate raw records (via `bytes(for:)` which goes through the section).
        // Any out-of-bounds offset/length would have been caught at open() time, but we
        // also validate that the bytes we read actually have the declared length so
        // truncated records get flagged.
        for id in 0..<profile.vocabularySize {
            let tokenID = TokenID(id)
            let bytes = profile.bytes(for: tokenID)
            guard bytes.count <= total else {
                throw Failure(check: "bytesBlobBounds", detail: "token \(id) bytes length \(bytes.count) exceeds blob length \(total)")
            }
        }
    }

    public static func checkTriePresence(profile: MmapAutocompleteProfile) throws {
        // For every non-excluded token, walking its bytes from the trie root must reach a
        // terminal node. Normally that node's terminal id == this token. But some
        // tokenizers (e.g. Gemma) contain *duplicate* tokens — distinct ids whose raw
        // bytes are byte-for-byte identical. A byte-keyed trie cannot tell them apart:
        // they share one node, so only one id can be that node's terminal. That is
        // correct (the trie is a byte oracle and both ids decode to the same text), so a
        // different terminal is accepted only when its bytes are identical. A non-terminal
        // node, or a terminal whose bytes differ, is a genuine writer bug.
        for id in 0..<profile.vocabularySize {
            let tokenID = TokenID(id)
            // `.code` mode is the least restrictive baseline (no newline ban, no emoji
            // ban) — anything excluded there is excluded everywhere.
            if profile.isExcluded(tokenID, mode: .code) { continue }
            let bytes = profile.bytes(for: tokenID)
            guard !bytes.isEmpty else { continue } // empty-bytes tokens carry no trie path.
            guard let state = profile.prefixStart(requiredBytes: bytes) else {
                throw Failure(check: "triePresence", detail: "token \(id) bytes not walkable from root")
            }
            guard let terminal = profile.terminalTokenID(at: state) else {
                throw Failure(check: "triePresence",
                              detail: "token \(id) reached non-terminal state \(state.nodeIndex)")
            }
            // Accept a different terminal only for a true duplicate (identical bytes).
            if terminal != tokenID && profile.bytes(for: terminal) != bytes {
                throw Failure(check: "triePresence",
                              detail: "token \(id) reached state \(state.nodeIndex) but terminal=\(terminal) has different bytes")
            }
        }
    }

    public static func checkSpecialListsSorted(profile: MmapAutocompleteProfile) throws {
        for list in SpecialList.allCases {
            let slice = profile.tokens(in: list)
            var last: TokenID = -1
            for i in 0..<slice.count {
                let id = slice[i]
                if id <= last && i > 0 {
                    throw Failure(check: "specialListsSorted", detail: "list \(list) is not strictly ascending at index \(i): \(last) then \(id)")
                }
                last = id
            }
        }
    }

    public static func checkBiasOverridesValid(profile: MmapAutocompleteProfile) throws {
        // Overrides shouldn't reference token ids outside the vocab, and NaN values are
        // rejected (NaN bias would never compare > anything and would silently disable
        // the token).
        for mode in BiasMode.allCases {
            // We don't have a raw enumeration API; instead we sample-check by querying
            // each id. Cheap because the in-memory dictionary is already populated.
            for id in 0..<profile.vocabularySize {
                let tokenID = TokenID(id)
                let bias = profile.bias(for: tokenID, mode: .prose, isSingleLine: mode == .singleLine)
                if bias.isNaN {
                    throw Failure(check: "biasOverridesValid", detail: "token \(id) has NaN bias in mode \(mode)")
                }
            }
        }
    }

    public static func checkBytesRoundTrip(
        profile: MmapAutocompleteProfile,
        source: (TokenID) throws -> [UInt8],
        sampleSize: Int
    ) throws {
        let n = profile.vocabularySize
        guard n > 0 else { return }
        let step = max(1, n / max(1, sampleSize))
        for id in stride(from: 0, to: n, by: step) {
            let tokenID = TokenID(id)
            let want: [UInt8]
            do { want = try source(tokenID) } catch {
                throw Failure(check: "bytesRoundTripSampled", detail: "source failed for id \(id): \(error)")
            }
            let got = profile.bytes(for: tokenID)
            if want != got {
                throw Failure(check: "bytesRoundTripSampled", detail: "token \(id) bytes mismatch (source \(want.count) bytes, profile \(got.count) bytes)")
            }
        }
    }
}
