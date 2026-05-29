import Foundation
import llama

/// Calls `llama_backend_init()` exactly once per process. Subsequent `LlamaModelRuntime`
/// instances reuse the same backend; we never call `llama_backend_free()` because it's
/// process-lifetime state.
final class LlamaBackend: @unchecked Sendable {
    static let shared = LlamaBackend()

    private init() {
        llama_backend_init()
    }
}
