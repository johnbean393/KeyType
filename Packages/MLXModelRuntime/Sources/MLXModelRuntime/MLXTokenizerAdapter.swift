import AutocompleteCore
import Foundation
import MLXLMCommon
import ModelRuntime
import TokenProfiles

/// Adapts the tokenizer supplied by `mlx-swift-lm` to KeyType's tokenizer contract.
///
/// `mlx-swift-lm` intentionally exposes token strings rather than a llama-style
/// `token_to_piece` byte API. Decoding one token with special-token handling disabled
/// gives us the bytes that KeyType needs for its incremental UTF-8 and ACPF checks.
public struct MLXTokenizerAdapter: ModelTokenizing, @unchecked Sendable {
    private let tokenizer: any MLXLMCommon.Tokenizer
    private let specialTokenIDs: Set<TokenID>

    public let vocabularySize: Int

    public init(tokenizer: any MLXLMCommon.Tokenizer, vocabularySize: Int) {
        self.tokenizer = tokenizer
        self.vocabularySize = vocabularySize

        var specialIDs = Set<TokenID>()
        let knownMarkers = [
            "<|endoftext|>",
            "<|im_start|>",
            "<|im_end|>",
            "<|fim_prefix|>",
            "<|fim_suffix|>",
            "<|fim_middle|>",
            "<|end|>",
            "<|eot_id|>",
            "<|start_header_id|>",
            "<|end_header_id|>",
        ]
        for id in 0..<vocabularySize {
            guard let token = tokenizer.convertIdToToken(id) else { continue }
            if knownMarkers.contains(token) || Self.looksLikeSpecialToken(token) {
                specialIDs.insert(TokenID(id))
            }
        }
        if let eosToken = tokenizer.eosToken,
           let id = tokenizer.convertTokenToId(eosToken)
        {
            specialIDs.insert(TokenID(id))
        }
        if let unknownToken = tokenizer.unknownToken,
           let id = tokenizer.convertTokenToId(unknownToken)
        {
            specialIDs.insert(TokenID(id))
        }
        self.specialTokenIDs = specialIDs
    }

    public func tokenize(_ text: String) throws -> [TokenID] {
        tokenizer.encode(text: text, addSpecialTokens: false).map(TokenID.init)
    }

    public func tokenizeAllowingSpecial(_ text: String) throws -> [TokenID] {
        // The public mlx-swift-lm tokenizer protocol has no separate parse-special flag.
        // Its Hugging Face adapter still recognizes configured added tokens while special
        // token insertion remains disabled, which is the behavior required by KeyType's
        // FIM marker probe.
        try tokenize(text)
    }

    public func detokenize(_ tokenIDs: [TokenID]) throws -> String {
        tokenizer.decode(
            tokenIds: tokenIDs.compactMap(Int.init),
            skipSpecialTokens: false
        )
    }

    public func rawBytes(for tokenID: TokenID) throws -> [UInt8] {
        guard let id = Int(exactly: tokenID), id >= 0, id < vocabularySize else {
            throw MLXTokenizerError.invalidTokenID(tokenID)
        }
        guard !specialTokenIDs.contains(tokenID) else { return [] }

        let piece = tokenizer.decode(tokenIds: [id], skipSpecialTokens: false)
        return Array(piece.utf8)
    }

    public func tokenString(for tokenID: TokenID) -> String? {
        guard let id = Int(exactly: tokenID), id >= 0, id < vocabularySize else { return nil }
        return tokenizer.convertIdToToken(id)
    }

    public func isSpecialToken(_ tokenID: TokenID) -> Bool {
        specialTokenIDs.contains(tokenID)
    }

    /// The digest is the exact ACPF identity: vocabulary size plus raw bytes for every token ID.
    /// It is intentionally computed from this adapter rather than from model metadata.
    public func tokenizerDigest() throws -> ACPFTokenizerDigestValue {
        try ACPFTokenizerDigest.digest(vocabSize: vocabularySize) { id in
            try rawBytes(for: id)
        }
    }

    private static func looksLikeSpecialToken(_ token: String) -> Bool {
        (token.hasPrefix("<|") && token.hasSuffix("|>"))
            || ["<s>", "</s>", "<unk>", "<pad>", "<mask>", "[CLS]", "[SEP]", "[MASK]"]
                .contains(token)
    }
}

public enum MLXTokenizerError: Error, Equatable, CustomStringConvertible {
    case invalidTokenID(TokenID)

    public var description: String {
        switch self {
        case let .invalidTokenID(tokenID):
            return "MLX tokenizer token ID is out of range: \(tokenID)"
        }
    }
}
