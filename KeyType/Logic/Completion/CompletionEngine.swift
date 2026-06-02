//
//  CompletionEngine.swift
//  KeyType
//
//  Protocol abstracting over local (llama.cpp) and remote (OpenAI-compatible API) completion
//  engines so CompletionController can use either without coupling to the concrete type.
//

import AutocompleteCore
import Foundation

/// Interface every completion engine must implement: generating completions, warming up, and
/// releasing resources. Both the local `ConstrainedGenerationEngine` and the new
/// `OpenAICompletionEngine` conform to this protocol.
public protocol CompletionEngine {
    /// Generate completion candidates for the given request. Throw on transient errors; return an
    /// empty array when the engine cannot produce a sensible completion (e.g. the user is typing in
    /// a field whose app policy suppresses completions).
    func completions(for request: CompletionRequest) async throws -> [CompletionCandidate]

    /// Optional warm-up: run a cheap forward pass so the first real generation is faster. The local
    /// engine uses this to prime the GPU; remote engines may skip or use a lightweight connectivity
    /// check. Safe to call redundantly.
    func warmUp(for request: CompletionRequest) async throws

    /// Release any native resources (model handles, GPU memory, network connections). Called during
    /// engine reload and app shutdown.
    func shutdown() async
}
