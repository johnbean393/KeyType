import AutocompleteCore
import ModelRuntime
import TokenProfiles

/// ACPF vocabulary view for an MLX tokenizer.
///
/// MLX/Hugging Face does not expose llama.cpp's attribute bitset, so this adapter reports the
/// conservative facts available from the tokenizer contract: ordinary tokens are normal, added
/// control markers are special, and the runtime's EOS/EOT metadata supplies stop roles.
public struct MLXVocabIntrospector: VocabIntrospecting, Sendable {
    private let tokenizer: MLXTokenizerAdapter
    private let eosTokenID: TokenID?
    private let eotTokenID: TokenID?

    public let vocabSize: Int

    public init(runtime: MLXLocalModelRuntime) {
        self.tokenizer = runtime.mlxTokenizer
        self.eosTokenID = runtime.metadata.eosTokenID
        self.eotTokenID = runtime.metadata.eotTokenID
        self.vocabSize = runtime.metadata.vocabularySize
    }

    public func bytes(for id: TokenID) throws -> [UInt8] {
        try tokenizer.rawBytes(for: id)
    }

    public func text(for id: TokenID) -> String? {
        tokenizer.tokenString(for: id)
    }

    public func attr(for id: TokenID) -> TokenAttr {
        tokenizer.isSpecialToken(id) ? .control : .normal
    }

    public func isControl(_ id: TokenID) -> Bool {
        tokenizer.isSpecialToken(id)
    }

    public func isEOG(_ id: TokenID) -> Bool {
        id == eosTokenID || id == eotTokenID
    }

    public func role(of id: TokenID) -> TokenRole? {
        if id == eosTokenID { return .eos }
        if id == eotTokenID { return .eot }
        switch tokenizer.tokenString(for: id) {
        case "<s>", "<|begin_of_text|>": return .bos
        case "<unk>": return .unk
        case "<pad>": return .pad
        default: return nil
        }
    }

    public func ggufMetadataDigest() -> String {
        ""
    }
}
