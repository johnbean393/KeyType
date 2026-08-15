import AutocompleteCore
import Foundation
import TokenProfiles

/// Backend-neutral vocabulary seam used by the ACPF builder.
///
/// Each model backend supplies the tokenizer facts that the profile classifier needs. Keeping the
/// seam here avoids making a non-llama backend depend on `LlamaModelRuntime` merely to generate or
/// validate an exact tokenizer profile.
public protocol VocabIntrospecting {
    var vocabSize: Int { get }
    func bytes(for id: TokenID) throws -> [UInt8]
    func text(for id: TokenID) -> String?
    func attr(for id: TokenID) -> TokenAttr
    func isControl(_ id: TokenID) -> Bool
    func isEOG(_ id: TokenID) -> Bool
    func role(of id: TokenID) -> TokenRole?

    /// Source metadata digest. GGUF-backed introspectors populate this; other backends may leave
    /// it empty when their source format has no equivalent metadata contract.
    func ggufMetadataDigest() -> String

    func probe(for id: TokenID) throws -> TokenizerProbe
}

public extension VocabIntrospecting {
    func probe(for id: TokenID) throws -> TokenizerProbe {
        TokenizerProbe(
            tokenID: id,
            bytes: try bytes(for: id),
            attr: attr(for: id),
            role: role(of: id),
            isControl: isControl(id),
            isEOG: isEOG(id)
        )
    }
}
