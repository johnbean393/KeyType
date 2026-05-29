import AutocompleteCore
import Foundation
import ModelRuntime
import llama

/// `ModelTokenizing` implementation backed by `llama_tokenize` / `llama_detokenize` /
/// `llama_token_to_piece`. The llama.h header documents these as thread-safe (see the
/// "Tokenization" comment block), so we don't need any additional synchronisation here —
/// the struct can be held by the actor as a `nonisolated let` and shared across callers.
///
/// `@unchecked Sendable` because the stored `OpaquePointer` is not statically `Sendable`,
/// but the pointee (`const llama_vocab *`) is owned by the parent `LlamaModelRuntime` and
/// only read via the documented-thread-safe llama tokenization API.
public struct LlamaTokenizer: ModelTokenizing, @unchecked Sendable {
    /// `const llama_vocab *` — opaque pointer owned by the parent `LlamaModelRuntime`.
    private let vocab: OpaquePointer
    public let vocabSize: Int

    init(vocab: OpaquePointer, vocabSize: Int) {
        self.vocab = vocab
        self.vocabSize = vocabSize
    }

    public func tokenize(_ text: String) throws -> [TokenID] {
        let utf8Count = Int32(text.utf8.count)
        // Start with a generous upper bound; we grow on demand if llama_tokenize asks for more.
        var capacity: Int32 = max(8, utf8Count + 8)
        while true {
            var tokens = [llama_token](repeating: 0, count: Int(capacity))
            let result = text.withCString { cText -> Int32 in
                tokens.withUnsafeMutableBufferPointer { buf in
                    llama_tokenize(
                        vocab,
                        cText,
                        utf8Count,
                        buf.baseAddress,
                        Int32(buf.count),
                        /* add_special */ false,
                        /* parse_special */ false
                    )
                }
            }
            if result >= 0 {
                tokens.removeLast(Int(capacity) - Int(result))
                return tokens.map { TokenID($0) }
            }
            // llama_tokenize returns -n where n is the required buffer size.
            let required = -result
            if required <= capacity {
                throw LlamaRuntimeError.tokenizeFailed(result)
            }
            capacity = required
        }
    }

    public func detokenize(_ tokenIDs: [TokenID]) throws -> String {
        if tokenIDs.isEmpty { return "" }
        let llamaTokens = tokenIDs.map { llama_token($0) }
        // Start with a generous upper bound — most tokens are 1–8 bytes; round up.
        var capacity: Int32 = Int32(max(32, llamaTokens.count * 16))
        while true {
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            let result = llamaTokens.withUnsafeBufferPointer { tokBuf -> Int32 in
                buffer.withUnsafeMutableBufferPointer { strBuf in
                    llama_detokenize(
                        vocab,
                        tokBuf.baseAddress,
                        Int32(tokBuf.count),
                        strBuf.baseAddress,
                        Int32(strBuf.count),
                        /* remove_special */ false,
                        /* unparse_special */ false
                    )
                }
            }
            if result >= 0 {
                let byteCount = Int(result)
                let bytes: [UInt8] = (0..<byteCount).map { UInt8(bitPattern: Int8(buffer[$0])) }
                return String(decoding: bytes, as: UTF8.self)
            }
            let required = -result
            if required <= capacity {
                throw LlamaRuntimeError.detokenizeFailed(result)
            }
            capacity = required
        }
    }

    public func rawBytes(for tokenID: TokenID) throws -> [UInt8] {
        var capacity: Int32 = 32
        while true {
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            let result = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                llama_token_to_piece(
                    vocab,
                    llama_token(tokenID),
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
}
