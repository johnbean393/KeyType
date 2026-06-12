import AutocompleteCore
import Foundation

/// On-disk format constants for the **ACPF** (Autocomplete Profile) file. The format is
/// versioned, little-endian, offset-based, and 64-byte-section-aligned so it memory-maps
/// cleanly. See `docs/03-token-profiles.md` and ADR-009 for the design rationale; the C
/// struct sketch in those docs is mirrored here.
public enum ACPF {
    /// `"ACPF"` in ASCII; the four magic bytes at offset 0 of every profile file.
    public static let magic: [UInt8] = [0x41, 0x43, 0x50, 0x46]

    /// Little-endian sentinel. On disk this appears as `02 01`; reading it back as a
    /// `UInt16` host-LE value yields `0x0102`. Any other value at this offset means the
    /// file was produced for a different endianness and must be rejected.
    public static let endianSentinel: UInt16 = 0x0102

    /// On-disk *binary format* version. Bump only when the byte layout of the header, sections, or
    /// records changes — never for changes to what gets baked into those bytes. Cache-busting for
    /// *classifier output* changes is `generatorVersion`'s job, not this field's (see below).
    public static let currentSchemaVersion: UInt16 = 1

    /// One section descriptor per `SectionKind`, in the header's section array.
    public static let sectionCount: Int = SectionKind.allCases.count

    /// Every section starts on a 64-byte boundary so the file can be mmap'd cleanly and
    /// section payloads land on cache-line boundaries.
    public static let sectionAlignment: Int = 64

    /// Fixed on-disk size of one `TokenProfileRecordRaw`. Indexed directly by token id.
    public static let tokenRecordSize: Int = 32

    /// On-disk size of one `ACPFSectionRaw` (offset, length, item_size, item_count).
    public static let sectionRawSize: Int = 24

    /// On-disk size of the `ACPFHeaderRaw` struct (without the trailing family-string
    /// payload). Header layout:
    ///
    ///     magic[4] version[2] endian[2] header_size[4] vocab_size[4]
    ///     tokenizer_hash_lo[8] tokenizer_hash_hi[8] model_family_len[4] flags[4]
    ///     build_timestamp[8] sections[sectionCount * 24]
    ///
    /// = 4+2+2+4+4+8+8+4+4+8 + 24 * sectionCount = 48 + 24 * sectionCount bytes.
    public static let headerRawSize: Int = 48 + sectionCount * sectionRawSize

    /// On-disk size of one `TrieNodeRaw` in the PREFIX_TRIE section payload.
    public static let trieNodeSize: Int = 12

    /// On-disk size of one `TrieEdge` in the PREFIX_TRIE section payload.
    public static let trieEdgeSize: Int = 8

    /// Sentinel stored in `TokenProfileRecordRaw.reserved` when the token has no trie
    /// terminal node (excluded tokens, empty-bytes tokens, or unmapped ids).
    public static let noTrieTerminal: UInt16 = .max

    /// Sentinel stored in `TokenProfileRecordRaw.first_byte` when the token has empty
    /// bytes. Anything in `0...255` is a real first byte.
    public static let emptyFirstByte: UInt16 = 256

    /// Identifier stamped into the validation section's `generator_version` slot, and the cache-busting
    /// key for the *classifier* output. The tokenizer digest covers only vocab bytes, so a change to
    /// `TokenClassifier` (which decides the `.excluded`/`.special` flags baked into every record and the
    /// trie) does NOT change the digest and would otherwise leave stale profiles in place.
    /// `MmapAutocompleteProfile.init` rejects a profile whose stamped `generator_version` differs from
    /// this, forcing `ProfileGenerator` to rebuild. **Bump this whenever `TokenClassifier` output
    /// changes**, independent of the binary `currentSchemaVersion`.
    ///   1.0 → 1.1: reserved-placeholder exclusion by byte content (Gemma `<unusedN>` leak fix).
    ///   1.1 → 1.2: markup-tag flag + prose demotion for Gemma's single-token HTML-tag block
    ///              (`</code>` shown in prose contexts; cancelled in code/terminal modes).
    public static let generatorVersion: String = "keytype-acpf-1.2"
}

/// Ordinals into the header's section array. **Stable across schema versions** — once an
/// ordinal is assigned to a section kind it cannot be reused for anything else.
public enum SectionKind: Int, CaseIterable {
    case tokenTable = 0
    case tokenBytes = 1
    case prefixTrie = 2
    case prefixBuckets = 3
    case specialLists = 4
    case biasTables = 5
    case validation = 6
}

/// Bias mode index inside the BIAS_TABLES section. Six modes: the five `CompletionMode`
/// values plus `singleLine`, which is a per-request flag at the API surface (see the
/// `isSingleLine` overloads on `MmapAutocompleteProfile`).
public enum BiasMode: Int, CaseIterable {
    case prose = 0
    case code = 1
    case terminal = 2
    case emoji = 3
    case correction = 4
    case singleLine = 5

    public init(_ mode: CompletionMode) {
        switch mode {
        case .prose: self = .prose
        case .code: self = .code
        case .terminal: self = .terminal
        case .emoji: self = .emoji
        case .correction: self = .correction
        }
    }
}

/// Logical categories stored in the SPECIAL_LISTS section as sorted arrays of token ids
/// so consumers can binary-search.
public enum SpecialList: Int, CaseIterable {
    case excluded = 0
    case stop = 1
    case newline = 2
    case whitespace = 3
    case sentenceEnd = 4
    case emoji = 5
    case chatMarker = 6
}

// MARK: - Raw on-disk records

/// Mirror of `struct Section` from `docs/03-token-profiles.md`. Always 24 bytes on disk.
public struct ACPFSectionRaw: Equatable {
    public var offset: UInt64
    public var length: UInt64
    public var itemSize: UInt32
    public var itemCount: UInt32

    public init(offset: UInt64 = 0, length: UInt64 = 0, itemSize: UInt32 = 0, itemCount: UInt32 = 0) {
        self.offset = offset
        self.length = length
        self.itemSize = itemSize
        self.itemCount = itemCount
    }

    public init(reading bytes: UnsafeRawBufferPointer, at byteOffset: Int) {
        precondition(byteOffset + ACPF.sectionRawSize <= bytes.count)
        self.offset = bytes.loadLEUInt64(at: byteOffset)
        self.length = bytes.loadLEUInt64(at: byteOffset + 8)
        self.itemSize = bytes.loadLEUInt32(at: byteOffset + 16)
        self.itemCount = bytes.loadLEUInt32(at: byteOffset + 20)
    }

    public func encode(into data: inout Data) {
        data.appendLE(offset)
        data.appendLE(length)
        data.appendLE(itemSize)
        data.appendLE(itemCount)
    }
}

/// Mirror of `struct Header` from `docs/03-token-profiles.md`. `magic`/`endian`/`version`
/// give a cheap sanity check; the section array sits at the tail of the header so
/// `header_size = headerRawSize + paddedFamilyLen`.
public struct ACPFHeaderRaw: Equatable {
    public var magic: [UInt8]                       // 4
    public var version: UInt16                      // 2
    public var endian: UInt16                       // 2
    public var headerSize: UInt32                   // 4
    public var vocabSize: UInt32                    // 4
    public var tokenizerHashLo: UInt64              // 8
    public var tokenizerHashHi: UInt64              // 8
    public var modelFamilyLen: UInt32               // 4
    public var flags: UInt32                        // 4
    public var buildTimestamp: Int64                // 8
    public var sections: [ACPFSectionRaw]           // 24 * sectionCount

    public init(
        magic: [UInt8] = ACPF.magic,
        version: UInt16 = ACPF.currentSchemaVersion,
        endian: UInt16 = ACPF.endianSentinel,
        headerSize: UInt32 = 0,
        vocabSize: UInt32 = 0,
        tokenizerHashLo: UInt64 = 0,
        tokenizerHashHi: UInt64 = 0,
        modelFamilyLen: UInt32 = 0,
        flags: UInt32 = 0,
        buildTimestamp: Int64 = 0,
        sections: [ACPFSectionRaw] = Array(repeating: ACPFSectionRaw(), count: ACPF.sectionCount)
    ) {
        self.magic = magic
        self.version = version
        self.endian = endian
        self.headerSize = headerSize
        self.vocabSize = vocabSize
        self.tokenizerHashLo = tokenizerHashLo
        self.tokenizerHashHi = tokenizerHashHi
        self.modelFamilyLen = modelFamilyLen
        self.flags = flags
        self.buildTimestamp = buildTimestamp
        self.sections = sections
    }

    public init(reading bytes: UnsafeRawBufferPointer) throws {
        guard bytes.count >= ACPF.headerRawSize else {
            throw ACPFOpenError.fileTooSmall(expected: ACPF.headerRawSize, actual: bytes.count)
        }
        self.magic = [bytes[0], bytes[1], bytes[2], bytes[3]]
        self.version = bytes.loadLEUInt16(at: 4)
        self.endian = bytes.loadLEUInt16(at: 6)
        self.headerSize = bytes.loadLEUInt32(at: 8)
        self.vocabSize = bytes.loadLEUInt32(at: 12)
        self.tokenizerHashLo = bytes.loadLEUInt64(at: 16)
        self.tokenizerHashHi = bytes.loadLEUInt64(at: 24)
        self.modelFamilyLen = bytes.loadLEUInt32(at: 32)
        self.flags = bytes.loadLEUInt32(at: 36)
        self.buildTimestamp = Int64(bitPattern: bytes.loadLEUInt64(at: 40))
        var sections: [ACPFSectionRaw] = []
        sections.reserveCapacity(ACPF.sectionCount)
        for i in 0..<ACPF.sectionCount {
            sections.append(ACPFSectionRaw(reading: bytes, at: 48 + i * ACPF.sectionRawSize))
        }
        self.sections = sections
    }

    public func encode(into data: inout Data) {
        precondition(magic.count == 4)
        precondition(sections.count == ACPF.sectionCount)
        data.append(contentsOf: magic)
        data.appendLE(version)
        data.appendLE(endian)
        data.appendLE(headerSize)
        data.appendLE(vocabSize)
        data.appendLE(tokenizerHashLo)
        data.appendLE(tokenizerHashHi)
        data.appendLE(modelFamilyLen)
        data.appendLE(flags)
        data.appendLE(UInt64(bitPattern: buildTimestamp))
        for s in sections { s.encode(into: &data) }
    }
}

/// Mirror of `struct TokenProfile` from `docs/03-token-profiles.md`. Exactly 32 bytes on
/// disk so it can be indexed by token id with a single multiplication.
public struct TokenProfileRecordRaw: Equatable {
    public var bytesOffset: UInt64                  // 8
    public var bytesLen: UInt32                     // 4
    public var flags: UInt32                        // 4
    public var staticBias: Float                    // 4
    public var displayWidth: UInt16                 // 2
    public var tokenType: UInt16                    // 2
    /// `0..<256` = the first byte of `bytes`. `256` = empty (no bytes).
    public var firstByte: UInt16                    // 2
    /// Trie terminal node index (`ACPF.noTrieTerminal` = no terminal). Lets the runtime
    /// jump straight to a token's terminal node without walking the trie from the root.
    public var trieTerminal: UInt16                 // 2

    public init(
        bytesOffset: UInt64 = 0,
        bytesLen: UInt32 = 0,
        flags: UInt32 = 0,
        staticBias: Float = 0,
        displayWidth: UInt16 = 0,
        tokenType: UInt16 = 0,
        firstByte: UInt16 = ACPF.emptyFirstByte,
        trieTerminal: UInt16 = ACPF.noTrieTerminal
    ) {
        self.bytesOffset = bytesOffset
        self.bytesLen = bytesLen
        self.flags = flags
        self.staticBias = staticBias
        self.displayWidth = displayWidth
        self.tokenType = tokenType
        self.firstByte = firstByte
        self.trieTerminal = trieTerminal
    }

    public init(reading bytes: UnsafeRawBufferPointer, at byteOffset: Int) {
        precondition(byteOffset + ACPF.tokenRecordSize <= bytes.count)
        self.bytesOffset = bytes.loadLEUInt64(at: byteOffset + 0)
        self.bytesLen = bytes.loadLEUInt32(at: byteOffset + 8)
        self.flags = bytes.loadLEUInt32(at: byteOffset + 12)
        self.staticBias = Float(bitPattern: bytes.loadLEUInt32(at: byteOffset + 16))
        self.displayWidth = bytes.loadLEUInt16(at: byteOffset + 20)
        self.tokenType = bytes.loadLEUInt16(at: byteOffset + 22)
        self.firstByte = bytes.loadLEUInt16(at: byteOffset + 24)
        self.trieTerminal = bytes.loadLEUInt16(at: byteOffset + 26)
        // bytes 28..31 are reserved padding to fill 32 bytes; we ignore them on read.
    }

    public func encode(into data: inout Data) {
        data.appendLE(bytesOffset)
        data.appendLE(bytesLen)
        data.appendLE(flags)
        data.appendLE(staticBias.bitPattern)
        data.appendLE(displayWidth)
        data.appendLE(tokenType)
        data.appendLE(firstByte)
        data.appendLE(trieTerminal)
        // 4 reserved bytes of trailing padding so the record is exactly 32 bytes.
        data.append(contentsOf: [0, 0, 0, 0])
    }
}

/// One node of the byte-level prefix trie. The trie lives in the PREFIX_TRIE section as a
/// flat `[TrieNodeRaw]` followed by a flat `[TrieEdge]`. Root node is at index 0.
public struct TrieNodeRaw: Equatable {
    /// Token id that ends at this node (`-1` if no token ends here).
    public var terminalTokenID: Int32                // 4
    /// Index of the first edge in the edges array (or 0 when `byteEdgeCount == 0`).
    public var firstEdgeIndex: UInt32                // 4
    /// Number of outgoing edges from this node.
    public var byteEdgeCount: UInt16                 // 2
    public var reserved: UInt16                      // 2

    public init(
        terminalTokenID: Int32 = -1,
        firstEdgeIndex: UInt32 = 0,
        byteEdgeCount: UInt16 = 0,
        reserved: UInt16 = 0
    ) {
        self.terminalTokenID = terminalTokenID
        self.firstEdgeIndex = firstEdgeIndex
        self.byteEdgeCount = byteEdgeCount
        self.reserved = reserved
    }

    public init(reading bytes: UnsafeRawBufferPointer, at byteOffset: Int) {
        precondition(byteOffset + ACPF.trieNodeSize <= bytes.count)
        self.terminalTokenID = Int32(bitPattern: bytes.loadLEUInt32(at: byteOffset + 0))
        self.firstEdgeIndex = bytes.loadLEUInt32(at: byteOffset + 4)
        self.byteEdgeCount = bytes.loadLEUInt16(at: byteOffset + 8)
        self.reserved = bytes.loadLEUInt16(at: byteOffset + 10)
    }

    public func encode(into data: inout Data) {
        data.appendLE(UInt32(bitPattern: terminalTokenID))
        data.appendLE(firstEdgeIndex)
        data.appendLE(byteEdgeCount)
        data.appendLE(reserved)
    }
}

/// One outgoing edge from a trie node. Edges for a node are stored contiguously, sorted by
/// `byte` ascending so the runtime can binary-search children in O(log k).
public struct TrieEdge: Equatable {
    /// Byte value taken to follow this edge.
    public var byte: UInt8                           // 1
    /// 3 reserved bytes of padding for alignment.
    public var reserved0: UInt8                      // 1
    public var reserved1: UInt8                      // 1
    public var reserved2: UInt8                      // 1
    /// Index of the destination node in the nodes array.
    public var childIndex: UInt32                    // 4

    public init(byte: UInt8 = 0, childIndex: UInt32 = 0) {
        self.byte = byte
        self.reserved0 = 0
        self.reserved1 = 0
        self.reserved2 = 0
        self.childIndex = childIndex
    }

    public init(reading bytes: UnsafeRawBufferPointer, at byteOffset: Int) {
        precondition(byteOffset + ACPF.trieEdgeSize <= bytes.count)
        self.byte = bytes[byteOffset + 0]
        self.reserved0 = bytes[byteOffset + 1]
        self.reserved1 = bytes[byteOffset + 2]
        self.reserved2 = bytes[byteOffset + 3]
        self.childIndex = bytes.loadLEUInt32(at: byteOffset + 4)
    }

    public func encode(into data: inout Data) {
        data.append(byte)
        data.append(0)
        data.append(0)
        data.append(0)
        data.appendLE(childIndex)
    }
}

// MARK: - Errors

/// Errors surfaced by `MmapAutocompleteProfile.open(...)` when validating a file. Each
/// case is a separate enum tag so callers (and tests) can match on individual failure
/// modes.
public enum ACPFOpenError: Error, Equatable, CustomStringConvertible {
    case fileTooSmall(expected: Int, actual: Int)
    case badMagic(found: [UInt8])
    case endianMismatch(found: UInt16)
    case unsupportedVersion(found: UInt16, supported: UInt16)
    case sectionCountMismatch(found: Int, expected: Int)
    case sectionMisaligned(kind: SectionKind, offset: UInt64, alignment: Int)
    case sectionOutOfBounds(kind: SectionKind, offset: UInt64, length: UInt64, fileSize: Int)
    case headerSizeMismatch(declared: UInt32, computed: UInt32)
    case modelFamilyMismatch(expected: String, found: String)
    case vocabSizeMismatch(expected: Int, found: Int)
    case tokenizerDigestMismatch(expected: ACPFTokenizerDigestValue, found: ACPFTokenizerDigestValue)
    case generatorVersionMismatch(expected: String, found: String)
    case malformedSectionPayload(kind: SectionKind, message: String)

    public var description: String {
        switch self {
        case let .fileTooSmall(expected, actual):
            return "ACPF: file is too small (expected at least \(expected) bytes, got \(actual))"
        case let .badMagic(found):
            return "ACPF: bad magic bytes \(found); expected \(ACPF.magic)"
        case let .endianMismatch(found):
            return "ACPF: endian sentinel \(String(found, radix: 16)) != 0x0102"
        case let .unsupportedVersion(found, supported):
            return "ACPF: schema version \(found) not supported (this build understands \(supported))"
        case let .sectionCountMismatch(found, expected):
            return "ACPF: section count \(found) != expected \(expected)"
        case let .sectionMisaligned(kind, offset, alignment):
            return "ACPF: section \(kind) offset \(offset) is not aligned to \(alignment) bytes"
        case let .sectionOutOfBounds(kind, offset, length, fileSize):
            return "ACPF: section \(kind) offset+length \(offset)+\(length) exceeds file size \(fileSize)"
        case let .headerSizeMismatch(declared, computed):
            return "ACPF: header_size \(declared) != computed \(computed)"
        case let .modelFamilyMismatch(expected, found):
            return "ACPF: model_family '\(found)' != expected '\(expected)'"
        case let .vocabSizeMismatch(expected, found):
            return "ACPF: vocab_size \(found) != expected \(expected)"
        case let .tokenizerDigestMismatch(expected, found):
            return "ACPF: tokenizer digest \(found.hexPrefix) != expected \(expected.hexPrefix)"
        case let .generatorVersionMismatch(expected, found):
            return "ACPF: generator_version '\(found)' != expected '\(expected)' (rebuild required)"
        case let .malformedSectionPayload(kind, message):
            return "ACPF: section \(kind) payload is malformed: \(message)"
        }
    }
}

/// Errors surfaced by `ACPFWriter` when the input is structurally invalid (rather than
/// the on-disk image being broken). These are programmer errors caught early.
public enum ACPFWriteError: Error, Equatable, CustomStringConvertible {
    case wrongRecordCount(expected: Int, actual: Int)
    case recordOutOfRange(tokenID: TokenID, vocabSize: Int)
    case tokenBytesTooLong(tokenID: TokenID, length: Int, max: Int)
    case familyStringTooLong(length: Int, max: Int)

    public var description: String {
        switch self {
        case let .wrongRecordCount(expected, actual):
            return "ACPFWriter: expected exactly \(expected) records, got \(actual)"
        case let .recordOutOfRange(tokenID, vocabSize):
            return "ACPFWriter: token id \(tokenID) out of range for vocab size \(vocabSize)"
        case let .tokenBytesTooLong(tokenID, length, max):
            return "ACPFWriter: token \(tokenID) bytes length \(length) exceeds max \(max)"
        case let .familyStringTooLong(length, max):
            return "ACPFWriter: model_family string length \(length) exceeds max \(max)"
        }
    }
}
