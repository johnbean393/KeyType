import AutocompleteCore
import Foundation

public struct TokenProfileFlags: OptionSet, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let special = TokenProfileFlags(rawValue: 1 << 0)
    public static let excluded = TokenProfileFlags(rawValue: 1 << 1)
    public static let stop = TokenProfileFlags(rawValue: 1 << 2)
    public static let whitespace = TokenProfileFlags(rawValue: 1 << 3)
    public static let newline = TokenProfileFlags(rawValue: 1 << 4)
    public static let wordStart = TokenProfileFlags(rawValue: 1 << 5)
    public static let wordContinuation = TokenProfileFlags(rawValue: 1 << 6)
    public static let punctuation = TokenProfileFlags(rawValue: 1 << 7)
    public static let sentenceEnd = TokenProfileFlags(rawValue: 1 << 8)
    public static let emoji = TokenProfileFlags(rawValue: 1 << 9)
    public static let chatMarker = TokenProfileFlags(rawValue: 1 << 10)
    public static let invalidUTF8 = TokenProfileFlags(rawValue: 1 << 11)
    /// A whole markup tag as a single vocab token (Gemma bakes `<b>`, `</code>`, `<table>`, … into
    /// its vocabulary as dedicated tokens the GGUF reports as NORMAL). Not excluded — markup is
    /// legitimate output in code/terminal modes — but down-biased in prose (see `BiasPolicy`).
    public static let markupTag = TokenProfileFlags(rawValue: 1 << 12)
}

public struct TokenProfileRecord: Equatable {
    public var tokenID: TokenID
    public var bytes: [UInt8]
    public var flags: TokenProfileFlags
    public var staticBias: Float
    public var displayWidth: Int

    public init(
        tokenID: TokenID,
        bytes: [UInt8],
        flags: TokenProfileFlags = [],
        staticBias: Float = 0,
        displayWidth: Int = 0
    ) {
        self.tokenID = tokenID
        self.bytes = bytes
        self.flags = flags
        self.staticBias = staticBias
        self.displayWidth = displayWidth
    }
}

public enum TokenStopBehavior: Equatable {
    case continueGeneration
    case stopAndSuppress
    case stopAndDisplay
}

public protocol AutocompleteProfile {
    var vocabularySize: Int { get }
    var tokenizerHash: String { get }

    func record(for tokenID: TokenID) -> TokenProfileRecord?
    func isExcluded(_ tokenID: TokenID, mode: CompletionMode) -> Bool
    func bias(for tokenID: TokenID, mode: CompletionMode) -> Float
    func displayWidth(for tokenID: TokenID) -> Int
    func stopBehavior(for tokenID: TokenID) -> TokenStopBehavior
    func tokenAllowed(_ tokenID: TokenID, afterRequiredPrefix prefix: [UInt8]) -> Bool
}

public struct InMemoryAutocompleteProfile: AutocompleteProfile {
    public var vocabularySize: Int
    public var tokenizerHash: String
    private var recordsByTokenID: [TokenID: TokenProfileRecord]

    public init(
        vocabularySize: Int,
        tokenizerHash: String = "in-memory",
        records: [TokenProfileRecord] = []
    ) {
        self.vocabularySize = vocabularySize
        self.tokenizerHash = tokenizerHash
        self.recordsByTokenID = Dictionary(uniqueKeysWithValues: records.map { ($0.tokenID, $0) })
    }

    public func record(for tokenID: TokenID) -> TokenProfileRecord? {
        recordsByTokenID[tokenID]
    }

    public func isExcluded(_ tokenID: TokenID, mode: CompletionMode) -> Bool {
        guard let flags = recordsByTokenID[tokenID]?.flags else {
            return tokenID < 0 || tokenID >= vocabularySize
        }

        if flags.contains(.excluded) || flags.contains(.special) || flags.contains(.chatMarker) {
            return true
        }
        if mode != .emoji && flags.contains(.emoji) {
            return true
        }
        if mode == .prose && flags.contains(.newline) {
            return true
        }
        return false
    }

    public func bias(for tokenID: TokenID, mode: CompletionMode) -> Float {
        recordsByTokenID[tokenID]?.staticBias ?? 0
    }

    public func displayWidth(for tokenID: TokenID) -> Int {
        recordsByTokenID[tokenID]?.displayWidth ?? 0
    }

    public func stopBehavior(for tokenID: TokenID) -> TokenStopBehavior {
        guard let record = recordsByTokenID[tokenID] else {
            return .continueGeneration
        }
        if record.flags.contains(.stop) {
            return .stopAndSuppress
        }
        if record.flags.contains(.sentenceEnd) {
            return .stopAndDisplay
        }
        return .continueGeneration
    }

    public func tokenAllowed(_ tokenID: TokenID, afterRequiredPrefix prefix: [UInt8]) -> Bool {
        guard !prefix.isEmpty else {
            return true
        }
        guard let bytes = recordsByTokenID[tokenID]?.bytes else {
            return false
        }
        return bytes.starts(with: prefix) || prefix.starts(with: bytes)
    }
}
