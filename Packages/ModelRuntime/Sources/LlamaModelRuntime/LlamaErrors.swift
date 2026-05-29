import Foundation

public enum LlamaRuntimeError: Error, CustomStringConvertible, Equatable {
    case modelFileMissing(path: String)
    case modelLoadFailed
    case contextInitFailed
    case vocabUnavailable
    case memoryUnavailable
    case tokenizeFailed(Int32)
    case detokenizeFailed(Int32)
    case tokenToPieceFailed(Int32)
    case decodeFailed(Int32)
    case promptTooLong(promptTokens: Int, contextLength: Int)
    case logitsUnavailable

    public var description: String {
        switch self {
        case .modelFileMissing(let path):
            return "Model file missing at \(path)"
        case .modelLoadFailed:
            return "llama_model_load_from_file returned NULL"
        case .contextInitFailed:
            return "llama_init_from_model returned NULL"
        case .vocabUnavailable:
            return "llama_model_get_vocab returned NULL"
        case .memoryUnavailable:
            return "llama_get_memory returned NULL"
        case .tokenizeFailed(let n):
            return "llama_tokenize failed with code \(n)"
        case .detokenizeFailed(let n):
            return "llama_detokenize failed with code \(n)"
        case .tokenToPieceFailed(let n):
            return "llama_token_to_piece failed with code \(n)"
        case .decodeFailed(let n):
            return "llama_decode failed with code \(n)"
        case .promptTooLong(let p, let c):
            return "Prompt of \(p) tokens exceeds context length \(c)"
        case .logitsUnavailable:
            return "llama_get_logits_ith returned NULL"
        }
    }
}
