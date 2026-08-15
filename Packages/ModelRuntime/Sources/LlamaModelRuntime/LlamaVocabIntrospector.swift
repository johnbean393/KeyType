import AutocompleteCore
import CryptoKit
import Foundation
import ModelRuntime
import llama

/// Concrete `VocabIntrospecting` implementation backed by `llama_vocab *`. The
/// llama.h tokenization APIs are documented as thread-safe (see the "Tokenization"
/// comment block at the top of the header), so this struct is `@unchecked Sendable`
/// like `LlamaTokenizer`.
public struct LlamaVocabIntrospector: VocabIntrospecting, @unchecked Sendable {
    /// `const llama_model *` — used only for the GGUF metadata digest.
    private let model: OpaquePointer
    /// `const llama_vocab *` — owned by the parent `LlamaModelRuntime`.
    private let vocab: OpaquePointer
    public let vocabSize: Int

    /// Cached role-by-id table so `role(of:)` is O(1). Populated once at init.
    private let roleByID: [TokenID: TokenRole]

    public init(model: OpaquePointer, vocab: OpaquePointer) {
        self.model = model
        self.vocab = vocab
        self.vocabSize = Int(llama_vocab_n_tokens(vocab))
        self.roleByID = Self.buildRoleTable(vocab: vocab)
    }

    public func bytes(for id: TokenID) throws -> [UInt8] {
        var capacity: Int32 = 32
        while true {
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            let result = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                // `special: false` so this matches `LlamaTokenizer.rawBytes(for:)` exactly —
                // they must agree, otherwise the tokenizer digest the builder stamps into the
                // profile won't equal the digest the runtime recomputes at open time (control /
                // special tokens render differently under `special: true`). Special tokens are
                // excluded by attribute/role regardless of their byte content.
                llama_token_to_piece(
                    vocab,
                    llama_token(id),
                    buf.baseAddress,
                    Int32(buf.count),
                    /* lstrip */ 0,
                    /* special */ false
                )
            }
            if result >= 0 {
                let byteCount = Int(result)
                return (0..<byteCount).map { UInt8(bitPattern: Int8(buffer[$0])) }
            }
            let required = -result
            if required <= capacity {
                throw LlamaRuntimeError.tokenToPieceFailed(result)
            }
            capacity = required
        }
    }

    public func text(for id: TokenID) -> String? {
        guard let cText = llama_vocab_get_text(vocab, llama_token(id)) else { return nil }
        return String(cString: cText)
    }

    public func attr(for id: TokenID) -> TokenAttr {
        let raw = llama_vocab_get_attr(vocab, llama_token(id))
        return Self.translate(raw)
    }

    public func isControl(_ id: TokenID) -> Bool {
        llama_vocab_is_control(vocab, llama_token(id))
    }

    public func isEOG(_ id: TokenID) -> Bool {
        llama_vocab_is_eog(vocab, llama_token(id))
    }

    public func role(of id: TokenID) -> TokenRole? {
        roleByID[id]
    }

    public func ggufMetadataDigest() -> String {
        // Pull every metadata key whose name starts with `tokenizer.ggml.` and feed
        // (key, value) pairs in sorted order into SHA-256. Skip the giant `tokens`
        // entry — its bytes are already covered by the tokenizer digest — but keep
        // everything else (e.g. `tokenizer.ggml.model`, `…bos_token_id`).
        let count = llama_model_meta_count(model)
        var pairs: [(String, String)] = []
        for i in 0..<count {
            let key = readMetadataString { buf, size in
                llama_model_meta_key_by_index(model, i, buf, size)
            }
            guard key.hasPrefix("tokenizer.ggml.") else { continue }
            if key == "tokenizer.ggml.tokens" { continue }
            if key == "tokenizer.ggml.scores" { continue }
            if key == "tokenizer.ggml.token_type" { continue }
            if key == "tokenizer.ggml.merges" { continue }
            let value = readMetadataString { buf, size in
                llama_model_meta_val_str_by_index(model, i, buf, size)
            }
            pairs.append((key, value))
        }
        pairs.sort { $0.0 < $1.0 }
        var hasher = SHA256()
        for (k, v) in pairs {
            let line = "\(k)=\(v)\n"
            line.withCString { ptr in
                let len = strlen(ptr)
                ptr.withMemoryRebound(to: UInt8.self, capacity: len) { byteBase in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: byteBase, count: len))
                }
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static func translate(_ raw: llama_token_attr) -> TokenAttr {
        let rv = UInt32(raw.rawValue)
        var attr = TokenAttr()
        if rv & UInt32(LLAMA_TOKEN_ATTR_UNKNOWN.rawValue) != 0 { attr.insert(.unknown) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_UNUSED.rawValue) != 0 { attr.insert(.unused) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_NORMAL.rawValue) != 0 { attr.insert(.normal) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_CONTROL.rawValue) != 0 { attr.insert(.control) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_USER_DEFINED.rawValue) != 0 { attr.insert(.userDefined) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_BYTE.rawValue) != 0 { attr.insert(.byte) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_NORMALIZED.rawValue) != 0 { attr.insert(.normalized) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_LSTRIP.rawValue) != 0 { attr.insert(.lstrip) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_RSTRIP.rawValue) != 0 { attr.insert(.rstrip) }
        if rv & UInt32(LLAMA_TOKEN_ATTR_SINGLE_WORD.rawValue) != 0 { attr.insert(.singleWord) }
        return attr
    }

    private static func buildRoleTable(vocab: OpaquePointer) -> [TokenID: TokenRole] {
        var table: [TokenID: TokenRole] = [:]
        let bos = llama_vocab_bos(vocab)
        let eos = llama_vocab_eos(vocab)
        let eot = llama_vocab_eot(vocab)
        let sep = llama_vocab_sep(vocab)
        let nl = llama_vocab_nl(vocab)
        let pad = llama_vocab_pad(vocab)
        func note(_ raw: llama_token, _ role: TokenRole) {
            guard raw != LLAMA_TOKEN_NULL else { return }
            table[TokenID(raw)] = role
        }
        note(bos, .bos)
        note(eos, .eos)
        note(eot, .eot)
        note(sep, .sep)
        note(nl, .nl)
        note(pad, .pad)
        // llama doesn't expose `unk` via a dedicated accessor; the UNK token shows up
        // as `LLAMA_TOKEN_ATTR_UNKNOWN` in `llama_vocab_get_attr`. The classifier
        // handles that case independently.
        return table
    }

    /// Run a llama metadata getter into a sized buffer, doubling on each
    /// underflow. Returns "" if the getter reports an error.
    private func readMetadataString(_ getter: (UnsafeMutablePointer<CChar>, Int) -> Int32) -> String {
        var capacity = 64
        while true {
            var buf = [CChar](repeating: 0, count: capacity + 1)
            let needed = buf.withUnsafeMutableBufferPointer { ptr in
                getter(ptr.baseAddress!, capacity + 1)
            }
            if needed < 0 { return "" }
            if Int(needed) <= capacity {
                return String(cString: buf)
            }
            capacity = Int(needed)
        }
    }
}

// MARK: - LlamaModelRuntime convenience

public extension LlamaModelRuntime {
    /// Build a `VocabIntrospecting` view over this runtime's vocab. Cheap — just packs
    /// up the model/vocab pointers and a role table.
    nonisolated func makeIntrospector() -> LlamaVocabIntrospector {
        LlamaVocabIntrospector(model: modelPointer, vocab: vocabPointer)
    }
}
