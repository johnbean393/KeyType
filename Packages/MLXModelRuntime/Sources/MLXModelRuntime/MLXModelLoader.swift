import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Loads a local MLX safetensor directory through the official `mlx-swift-lm` factory.
///
/// Downloading is intentionally outside this package. That keeps model weights out of the
/// repository and lets KeyType's model-management layer decide where to cache them.
public enum MLXModelLoader {
    public static func load(
        modelDirectory: URL,
        contextLength: Int? = nil,
        family: String? = nil
    ) async throws -> MLXLocalModelRuntime {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: modelDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw MLXRuntimeError.modelDirectoryMissing(modelDirectory.path)
        }

        let context = try await LLMModelFactory.shared.load(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        let resolvedContextLength = contextLength ?? readContextLength(from: modelDirectory)
        return MLXLocalModelRuntime(
            context: context,
            contextLength: resolvedContextLength,
            family: family
        )
    }

    /// Reads common context-length keys without coupling the runtime to one model family.
    /// Nested `text_config` values are supported for multimodal checkpoints whose language
    /// model configuration lives below the top-level model config.
    private static func readContextLength(from directory: URL) -> Int {
        let fallback = 4096
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return fallback
        }
        return findContextLength(in: object) ?? fallback
    }

    private static func findContextLength(in value: Any) -> Int? {
        if let object = value as? [String: Any] {
            for key in ["max_position_embeddings", "max_seq_len", "max_sequence_length"] {
                if let number = object[key] as? NSNumber, number.intValue > 0 {
                    return number.intValue
                }
            }
            for child in object.values {
                if let result = findContextLength(in: child) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = findContextLength(in: child) {
                    return result
                }
            }
        }
        return nil
    }
}
