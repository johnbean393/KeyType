import AutocompleteCore
import Foundation

/// Cursor inside the byte-level prefix trie. Returned by `prefixStart` /
/// `prefixAdvance` on `MmapAutocompleteProfile`. M5's sampler will use this to
/// incrementally constrain decoding once a required prefix has been consumed.
public struct TrieState: Equatable {
    /// Index of the current trie node (root is `0`).
    public let nodeIndex: UInt32

    public init(nodeIndex: UInt32) {
        self.nodeIndex = nodeIndex
    }
}

/// Categorised slice of token ids stored in the SPECIAL_LISTS section. Returned from
/// `MmapAutocompleteProfile.tokens(in:)` so callers can iterate without copying.
public struct SpecialListSlice: RandomAccessCollection {
    public typealias Element = TokenID
    public typealias Index = Int

    private let data: Data
    private let offset: Int
    private let length: Int

    fileprivate init(data: Data, offset: Int, count: Int) {
        self.data = data
        self.offset = offset
        self.length = count
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { length }

    public subscript(position: Int) -> TokenID {
        precondition(position >= 0 && position < length)
        return data.withUnsafeBytes { ptr in
            TokenID(ptr.loadLEInt32(at: offset + position * 4))
        }
    }
}

/// Memory-mapped reader for ACPF profiles. Conforms to `AutocompleteProfile` so the
/// engine can swap an `InMemoryAutocompleteProfile` for the on-disk one without source
/// changes. Exposes additional trie-cursor + special-list APIs on the concrete type
/// (M5 will consume them).
public final class MmapAutocompleteProfile: AutocompleteProfile {

    // MARK: - Stored state

    private let data: Data
    private let header: ACPFHeaderRaw
    public let modelFamily: String
    public let vocabularySize: Int
    public let tokenizerHash: String

    /// Tokenizer digest as carried in the header, returned as a typed value.
    public let tokenizerDigest: ACPFTokenizerDigestValue

    /// Section descriptors keyed by kind, with their on-disk extents pre-validated.
    private let sections: [SectionKind: ACPFSectionRaw]

    /// Decoded number of trie nodes (from the PREFIX_TRIE section preamble).
    private let trieNodeCount: UInt32
    /// Decoded number of trie edges (from the PREFIX_TRIE section preamble).
    private let trieEdgeCount: UInt32
    /// Byte offset of the first trie node inside `data`.
    private let trieNodesOffset: Int
    /// Byte offset of the first trie edge inside `data`.
    private let trieEdgesOffset: Int

    /// Cached per-mode bias overrides. Maps `(mode, tokenID)` to the override delta.
    private let biasOverrides: [BiasMode: [TokenID: Float]]

    // MARK: - Open

    /// Open the file at `url` and validate every header invariant. The optional
    /// `expectedTokenizerDigest` lets callers reject a stale profile up front; pass
    /// `nil` to skip the check (e.g. when the same caller is the one who computed it).
    public static func open(
        at url: URL,
        expectedVocabSize: Int? = nil,
        expectedModelFamily: String? = nil,
        expectedTokenizerDigest: ACPFTokenizerDigestValue? = nil,
        expectedGeneratorVersion: String? = ACPF.generatorVersion
    ) throws -> MmapAutocompleteProfile {
        let data = try Data(contentsOf: url, options: [.alwaysMapped, .uncached])
        return try MmapAutocompleteProfile(
            data: data,
            expectedVocabSize: expectedVocabSize,
            expectedModelFamily: expectedModelFamily,
            expectedTokenizerDigest: expectedTokenizerDigest,
            expectedGeneratorVersion: expectedGeneratorVersion
        )
    }

    /// Convenience that computes the tokenizer digest from a closure over the source
    /// vocab and validates it against the on-disk hash. Lets the app supply a
    /// `ModelTokenizing` without `TokenProfiles` depending on `ModelRuntime`.
    public static func open(
        at url: URL,
        tokenizerVocabSize: Int,
        tokenizerBytes: (TokenID) throws -> [UInt8],
        expectedModelFamily: String? = nil,
        expectedGeneratorVersion: String? = ACPF.generatorVersion
    ) throws -> MmapAutocompleteProfile {
        let digest = try ACPFTokenizerDigest.digest(vocabSize: tokenizerVocabSize, bytesFor: tokenizerBytes)
        return try open(
            at: url,
            expectedVocabSize: tokenizerVocabSize,
            expectedModelFamily: expectedModelFamily,
            expectedTokenizerDigest: digest,
            expectedGeneratorVersion: expectedGeneratorVersion
        )
    }

    /// Direct-from-`Data` constructor used by the round-trip tests. Production code
    /// should use the `open(...)` factories which memory-map the file.
    public init(
        data: Data,
        expectedVocabSize: Int? = nil,
        expectedModelFamily: String? = nil,
        expectedTokenizerDigest: ACPFTokenizerDigestValue? = nil,
        expectedGeneratorVersion: String? = ACPF.generatorVersion
    ) throws {
        // 1. Header sanity.
        let header = try data.withUnsafeBytes { try ACPFHeaderRaw(reading: $0) }
        guard header.magic == ACPF.magic else {
            throw ACPFOpenError.badMagic(found: header.magic)
        }
        guard header.endian == ACPF.endianSentinel else {
            throw ACPFOpenError.endianMismatch(found: header.endian)
        }
        guard header.version == ACPF.currentSchemaVersion else {
            throw ACPFOpenError.unsupportedVersion(found: header.version, supported: ACPF.currentSchemaVersion)
        }
        guard header.sections.count == ACPF.sectionCount else {
            throw ACPFOpenError.sectionCountMismatch(found: header.sections.count, expected: ACPF.sectionCount)
        }

        // 2. header_size must equal ACPFHeaderRawSize + family-string padded to 64 bytes.
        let familyEnd = ACPF.headerRawSize + Int(header.modelFamilyLen)
        let paddedHeaderSize = UInt32(MmapAutocompleteProfile.alignUp(familyEnd, to: ACPF.sectionAlignment))
        guard header.headerSize == paddedHeaderSize else {
            throw ACPFOpenError.headerSizeMismatch(declared: header.headerSize, computed: paddedHeaderSize)
        }
        guard data.count >= Int(paddedHeaderSize) else {
            throw ACPFOpenError.fileTooSmall(expected: Int(paddedHeaderSize), actual: data.count)
        }

        // 3. Decode the model-family string.
        let familyBytes = data.subdata(in: ACPF.headerRawSize..<familyEnd)
        let family = String(data: familyBytes, encoding: .utf8) ?? ""

        // 4. Bounds-check every section and 64-byte-align.
        var sections: [SectionKind: ACPFSectionRaw] = [:]
        for (i, raw) in header.sections.enumerated() {
            guard let kind = SectionKind(rawValue: i) else { continue }
            if raw.offset % UInt64(ACPF.sectionAlignment) != 0 {
                throw ACPFOpenError.sectionMisaligned(kind: kind, offset: raw.offset, alignment: ACPF.sectionAlignment)
            }
            if Int(raw.offset) + Int(raw.length) > data.count {
                throw ACPFOpenError.sectionOutOfBounds(kind: kind, offset: raw.offset, length: raw.length, fileSize: data.count)
            }
            sections[kind] = raw
        }

        // 5. Expectations supplied by the caller.
        if let expectedVocab = expectedVocabSize, expectedVocab != Int(header.vocabSize) {
            throw ACPFOpenError.vocabSizeMismatch(expected: expectedVocab, found: Int(header.vocabSize))
        }
        if let expectedFamily = expectedModelFamily, expectedFamily != family {
            throw ACPFOpenError.modelFamilyMismatch(expected: expectedFamily, found: family)
        }
        let digest = ACPFTokenizerDigestValue(lo: header.tokenizerHashLo, hi: header.tokenizerHashHi)
        if let expectedDigest = expectedTokenizerDigest, expectedDigest != digest {
            throw ACPFOpenError.tokenizerDigestMismatch(expected: expectedDigest, found: digest)
        }

        // 5b. Generator-version cache-buster. The tokenizer digest covers only vocab bytes, so a
        //     `TokenClassifier` logic change (which alters the baked `.excluded`/`.special` flags and
        //     trie) leaves the digest untouched. The VALIDATION section's `generator_version` string
        //     captures that logic version; reject a profile stamped with anything other than the
        //     build's expected value so `ProfileGenerator` rebuilds. An empty/missing stamp (older
        //     profiles, or a section without validation strings) skips the check for back-compat —
        //     only a present, non-empty, non-matching value is a hard mismatch.
        if let expectedGenerator = expectedGeneratorVersion, let validation = sections[.validation] {
            let stamped = MmapAutocompleteProfile.readValidationStrings(data: data, section: validation).generatorVersion
            if !stamped.isEmpty, stamped != expectedGenerator {
                throw ACPFOpenError.generatorVersionMismatch(expected: expectedGenerator, found: stamped)
            }
        }

        // 6. Parse trie preamble (nodeCount, edgeCount) and compute payload offsets.
        let trieSection = sections[.prefixTrie]!
        let trieOffset = Int(trieSection.offset)
        guard trieSection.length >= 8 else {
            throw ACPFOpenError.malformedSectionPayload(kind: .prefixTrie, message: "trie section shorter than preamble")
        }
        let (nodeCount, edgeCount): (UInt32, UInt32) = data.withUnsafeBytes { ptr in
            (ptr.loadLEUInt32(at: trieOffset), ptr.loadLEUInt32(at: trieOffset + 4))
        }
        let nodesStart = trieOffset + 8
        let edgesStart = nodesStart + Int(nodeCount) * ACPF.trieNodeSize
        let trieExpectedLen = 8 + Int(nodeCount) * ACPF.trieNodeSize + Int(edgeCount) * ACPF.trieEdgeSize
        guard trieExpectedLen <= Int(trieSection.length) else {
            throw ACPFOpenError.malformedSectionPayload(
                kind: .prefixTrie,
                message: "declared \(nodeCount) nodes + \(edgeCount) edges does not fit in section length \(trieSection.length)"
            )
        }

        // 7. Pre-load BIAS_TABLES into a per-mode dictionary so `bias(for:mode:)` is O(1).
        let biasSection = sections[.biasTables]!
        let biasOverrides = try MmapAutocompleteProfile.parseBiasTables(
            data: data,
            offset: Int(biasSection.offset),
            length: Int(biasSection.length)
        )

        // 8. Commit.
        self.data = data
        self.header = header
        self.modelFamily = family
        self.vocabularySize = Int(header.vocabSize)
        self.tokenizerDigest = digest
        self.tokenizerHash = digest.hexPrefix
        self.sections = sections
        self.trieNodeCount = nodeCount
        self.trieEdgeCount = edgeCount
        self.trieNodesOffset = nodesStart
        self.trieEdgesOffset = edgesStart
        self.biasOverrides = biasOverrides
    }

    // MARK: - AutocompleteProfile

    public func record(for tokenID: TokenID) -> TokenProfileRecord? {
        guard let raw = rawRecord(for: tokenID) else { return nil }
        return TokenProfileRecord(
            tokenID: tokenID,
            bytes: bytes(forRaw: raw),
            flags: TokenProfileFlags(rawValue: raw.flags),
            staticBias: raw.staticBias,
            displayWidth: Int(raw.displayWidth)
        )
    }

    public func isExcluded(_ tokenID: TokenID, mode: CompletionMode) -> Bool {
        isExcluded(tokenID, mode: mode, isSingleLine: false)
    }

    public func isExcluded(_ tokenID: TokenID, mode: CompletionMode, isSingleLine: Bool) -> Bool {
        guard let raw = rawRecord(for: tokenID) else {
            return tokenID < 0 || tokenID >= TokenID(vocabularySize)
        }
        let flags = TokenProfileFlags(rawValue: raw.flags)
        if flags.contains(.excluded) || flags.contains(.special) || flags.contains(.chatMarker) {
            return true
        }
        if mode != .emoji && flags.contains(.emoji) {
            return true
        }
        if mode == .prose && flags.contains(.newline) {
            return true
        }
        if isSingleLine && flags.contains(.newline) {
            return true
        }
        return false
    }

    public func bias(for tokenID: TokenID, mode: CompletionMode) -> Float {
        bias(for: tokenID, mode: mode, isSingleLine: false)
    }

    public func bias(for tokenID: TokenID, mode: CompletionMode, isSingleLine: Bool) -> Float {
        guard let raw = rawRecord(for: tokenID) else { return 0 }
        var bias = raw.staticBias
        bias += biasOverrides[BiasMode(mode)]?[tokenID] ?? 0
        if isSingleLine {
            bias += biasOverrides[.singleLine]?[tokenID] ?? 0
        }
        return bias
    }

    public func displayWidth(for tokenID: TokenID) -> Int {
        guard let raw = rawRecord(for: tokenID) else { return 0 }
        return Int(raw.displayWidth)
    }

    public func stopBehavior(for tokenID: TokenID) -> TokenStopBehavior {
        guard let raw = rawRecord(for: tokenID) else { return .continueGeneration }
        let flags = TokenProfileFlags(rawValue: raw.flags)
        if flags.contains(.stop) { return .stopAndSuppress }
        if flags.contains(.sentenceEnd) { return .stopAndDisplay }
        return .continueGeneration
    }

    public func tokenAllowed(_ tokenID: TokenID, afterRequiredPrefix prefix: [UInt8]) -> Bool {
        guard !prefix.isEmpty else { return true }
        guard let raw = rawRecord(for: tokenID) else { return false }
        let tokenBytes = bytes(forRaw: raw)
        return tokenBytes.starts(with: prefix) || prefix.starts(with: tokenBytes)
    }

    // MARK: - Bytes blob

    /// Raw bytes for a token id, copied out of the mmap'd bytes blob. Cheap for the
    /// short tokens we care about; callers that need to compare millions of bytes per
    /// frame should use `withRawBytes(for:_:)` to avoid the allocation.
    public func bytes(for tokenID: TokenID) -> [UInt8] {
        guard let raw = rawRecord(for: tokenID) else { return [] }
        return bytes(forRaw: raw)
    }

    /// Zero-copy bytes accessor: hands the caller an `UnsafeRawBufferPointer` slice
    /// into the mmap'd bytes blob. The pointer is only valid for the duration of the
    /// closure.
    public func withRawBytes<R>(for tokenID: TokenID, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R? {
        guard let raw = rawRecord(for: tokenID) else { return nil }
        let bytesSection = sections[.tokenBytes]!
        let start = Int(bytesSection.offset) + Int(raw.bytesOffset)
        let count = Int(raw.bytesLen)
        return try data.withUnsafeBytes { ptr in
            try body(UnsafeRawBufferPointer(rebasing: ptr[start..<start + count]))
        }
    }

    // MARK: - Trie cursor (M5)

    /// Walk `requiredBytes` from the trie root. Returns the deepest reachable state, or
    /// `nil` if the very first byte has no edge (meaning no token whose bytes start
    /// with `requiredBytes[0]` exists). When the walk stalls partway, the returned
    /// state's `nodeIndex` is the last reachable node — callers can detect a stall by
    /// comparing the walked-byte count, or by passing `requiredBytes.isEmpty == true`
    /// which always returns the root state.
    public func prefixStart(requiredBytes: [UInt8]) -> TrieState? {
        var node: UInt32 = 0
        for byte in requiredBytes {
            guard let next = followEdge(from: node, byte: byte) else {
                return node == 0 ? nil : TrieState(nodeIndex: node)
            }
            node = next
        }
        return TrieState(nodeIndex: node)
    }

    /// True iff token `id`'s bytes can be walked from `state.nodeIndex` and the walk ends
    /// at a terminal node for those bytes. Usually that node's `terminal_token_id == id`;
    /// for duplicate-byte tokenizers (e.g. Gemma) the stored terminal may be a different
    /// id whose bytes are identical, which still validly completes `id`'s bytes — so we
    /// compare bytes, not ids. Excluded ids are never trie members and are rejected up
    /// front, so a non-excluded duplicate can't smuggle one back in. The "token is a prefix
    /// of required" case is handled by the protocol's `tokenAllowed(_:afterRequiredPrefix:)`.
    public func tokenAllowed(_ id: TokenID, in state: TrieState) -> Bool {
        guard let raw = rawRecord(for: id) else { return false }
        let tokenBytes = bytes(forRaw: raw)
        guard !tokenBytes.isEmpty else { return false }
        // The trie holds only non-excluded tokens (ACPFWriter.buildAndCompactTrie gates on
        // the base `.excluded` flag), so an excluded id is never a member: reject it before
        // the byte-equality fallback can match it against a non-excluded duplicate's bytes.
        guard !TokenProfileFlags(rawValue: raw.flags).contains(.excluded) else { return false }
        var node = state.nodeIndex
        for b in tokenBytes {
            guard let next = followEdge(from: node, byte: b) else { return false }
            node = next
        }
        let terminal = trieNode(at: node).terminalTokenID
        guard terminal >= 0 else { return false }
        if terminal == Int32(id) { return true }
        // Duplicate token: accept when the stored terminal's bytes match `id`'s bytes.
        return withRawBytes(for: TokenID(terminal)) { $0.elementsEqual(tokenBytes) } ?? false
    }

    /// Advance the trie state by all bytes of token `id`. Returns `nil` if any byte
    /// would step off the trie (e.g. the token's bytes are inconsistent with the
    /// admissible byte continuations from `state.nodeIndex`).
    public func prefixAdvance(_ state: TrieState, by id: TokenID) -> TrieState? {
        guard let raw = rawRecord(for: id) else { return nil }
        let tokenBytes = bytes(forRaw: raw)
        var node = state.nodeIndex
        for b in tokenBytes {
            guard let next = followEdge(from: node, byte: b) else { return nil }
            node = next
        }
        return TrieState(nodeIndex: node)
    }

    /// Returns the terminal token id at the trie node referenced by `state`, or `nil`
    /// if no token terminates there. Used by the writer-correctness tests
    /// ("does the trie store token T's terminal at the node reached by walking T's
    /// bytes?") and the self-check.
    public func terminalTokenID(at state: TrieState) -> TokenID? {
        guard state.nodeIndex < trieNodeCount else { return nil }
        let id = trieNode(at: state.nodeIndex).terminalTokenID
        return id >= 0 ? TokenID(id) : nil
    }

    // MARK: - Special lists

    /// Sorted-id slice for the given category. Backed directly by the mmap'd
    /// SPECIAL_LISTS section, so the cost is one bounds check per element.
    public func tokens(in list: SpecialList) -> SpecialListSlice {
        let section = sections[.specialLists]!
        var cursor = Int(section.offset)
        let listCount = data.withUnsafeBytes { $0.loadLEUInt32(at: cursor) }
        cursor += 4
        for listIndex in 0..<Int(listCount) {
            let count = data.withUnsafeBytes { $0.loadLEUInt32(at: cursor) }
            cursor += 4
            if listIndex == list.rawValue {
                return SpecialListSlice(data: data, offset: cursor, count: Int(count))
            }
            cursor += Int(count) * 4
        }
        return SpecialListSlice(data: data, offset: cursor, count: 0)
    }

    // MARK: - Diagnostics

    public var trieNodeCountValue: Int { Int(trieNodeCount) }
    public var trieEdgeCountValue: Int { Int(trieEdgeCount) }
    public var bytesSectionLength: Int { Int(sections[.tokenBytes]!.length) }
    public func sectionRaw(_ kind: SectionKind) -> ACPFSectionRaw { sections[kind]! }

    /// Returns the validation section's `(ggufMetadataDigest, generatorVersion, builderHost)` triple.
    public func validationStrings() -> (ggufMetadataDigest: String, generatorVersion: String, builderHost: String) {
        Self.readValidationStrings(data: data, section: sections[.validation]!)
    }

    /// Parses the three length-prefixed strings in the VALIDATION section payload. Shared by
    /// `validationStrings()` and the init-time `generator_version` check so both decode identically.
    /// A truncated/empty section yields empty strings (never a crash).
    static func readValidationStrings(
        data: Data,
        section: ACPFSectionRaw
    ) -> (ggufMetadataDigest: String, generatorVersion: String, builderHost: String) {
        var cursor = Int(section.offset)
        let end = cursor + Int(section.length)

        func read() -> String {
            guard cursor + 4 <= end else { return "" }
            let len = Int(data.withUnsafeBytes { $0.loadLEUInt32(at: cursor) })
            cursor += 4
            guard cursor + len <= end else { return "" }
            let s = String(data: data.subdata(in: cursor..<cursor + len), encoding: .utf8) ?? ""
            cursor += len
            return s
        }
        let gguf = read()
        let gen = read()
        let host = read()
        return (gguf, gen, host)
    }

    public var buildTimestamp: Date { Date(timeIntervalSince1970: TimeInterval(header.buildTimestamp)) }

    // MARK: - Internals

    private func rawRecord(for tokenID: TokenID) -> TokenProfileRecordRaw? {
        guard tokenID >= 0, Int(tokenID) < vocabularySize else { return nil }
        let section = sections[.tokenTable]!
        let offset = Int(section.offset) + Int(tokenID) * ACPF.tokenRecordSize
        return data.withUnsafeBytes { TokenProfileRecordRaw(reading: $0, at: offset) }
    }

    private func bytes(forRaw raw: TokenProfileRecordRaw) -> [UInt8] {
        let bytesSection = sections[.tokenBytes]!
        let start = Int(bytesSection.offset) + Int(raw.bytesOffset)
        let count = Int(raw.bytesLen)
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { ptr in
            Array(UnsafeRawBufferPointer(rebasing: ptr[start..<start + count]))
        }
    }

    private func trieNode(at index: UInt32) -> TrieNodeRaw {
        precondition(index < trieNodeCount, "trie node index \(index) out of range (count \(trieNodeCount))")
        return data.withUnsafeBytes { ptr in
            TrieNodeRaw(reading: ptr, at: trieNodesOffset + Int(index) * ACPF.trieNodeSize)
        }
    }

    /// Binary-search the edges of `node` for `byte`. Returns the destination node
    /// index or `nil` if no edge exists. Bounds-checks both the edge index and the
    /// byte's child index so corrupt data can't trap.
    private func followEdge(from node: UInt32, byte: UInt8) -> UInt32? {
        guard node < trieNodeCount else { return nil }
        let raw = trieNode(at: node)
        let count = Int(raw.byteEdgeCount)
        guard count > 0 else { return nil }
        let first = Int(raw.firstEdgeIndex)
        guard first + count <= Int(trieEdgeCount) else { return nil }
        return data.withUnsafeBytes { ptr in
            var lo = 0
            var hi = count
            while lo < hi {
                let mid = (lo + hi) >> 1
                let edgeOffset = trieEdgesOffset + (first + mid) * ACPF.trieEdgeSize
                let edgeByte = ptr[edgeOffset]
                if edgeByte == byte {
                    let child = ptr.loadLEUInt32(at: edgeOffset + 4)
                    return child < trieNodeCount ? child : nil
                } else if edgeByte < byte {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            return nil
        }
    }

    // MARK: - Parsing helpers

    private static func parseBiasTables(data: Data, offset: Int, length: Int) throws -> [BiasMode: [TokenID: Float]] {
        var result: [BiasMode: [TokenID: Float]] = [:]
        for mode in BiasMode.allCases { result[mode] = [:] }
        guard length >= 4 else { return result }
        let end = offset + length
        var cursor = offset
        let modeCount = data.withUnsafeBytes { $0.loadLEUInt32(at: cursor) }
        cursor += 4
        guard Int(modeCount) == BiasMode.allCases.count else {
            throw ACPFOpenError.malformedSectionPayload(kind: .biasTables, message: "mode count \(modeCount) != \(BiasMode.allCases.count)")
        }
        for mode in BiasMode.allCases {
            guard cursor + 4 <= end else {
                throw ACPFOpenError.malformedSectionPayload(kind: .biasTables, message: "truncated mode \(mode)")
            }
            let pairCount = data.withUnsafeBytes { $0.loadLEUInt32(at: cursor) }
            cursor += 4
            guard cursor + Int(pairCount) * 8 <= end else {
                throw ACPFOpenError.malformedSectionPayload(kind: .biasTables, message: "mode \(mode) declared \(pairCount) pairs but truncated")
            }
            var table: [TokenID: Float] = [:]
            table.reserveCapacity(Int(pairCount))
            data.withUnsafeBytes { ptr in
                for i in 0..<Int(pairCount) {
                    let pairOffset = cursor + i * 8
                    let id = ptr.loadLEInt32(at: pairOffset)
                    let bits = ptr.loadLEUInt32(at: pairOffset + 4)
                    table[TokenID(id)] = Float(bitPattern: bits)
                }
            }
            result[mode] = table
            cursor += Int(pairCount) * 8
        }
        return result
    }

    private static func alignUp(_ value: Int, to alignment: Int) -> Int {
        let r = value % alignment
        return r == 0 ? value : value + (alignment - r)
    }
}
