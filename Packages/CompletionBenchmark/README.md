# KeyType Completion Benchmark

Offline evaluation harness for KeyType's final, user-visible completion behavior.

The runner evaluates the production-like path:

1. Resolve `AppCompatibilityStore` policy.
2. Apply mid-word healing.
3. Build the production prompt with `PromptBuilder` and the model tokenizer.
4. Decode through `ConstrainedGenerationEngine` with FIM enabled.
5. Run `DefaultCandidateFilter`.
6. Strip healed stems and reconcile the caret boundary.
7. Score the final shown text or suppression reason.

Latency numbers are only meaningful in release builds:

```sh
swift run -c release --package-path Packages/CompletionBenchmark keytype-benchmark run --suite smoke
```

Useful commands:

```sh
# Validate the committed public smoke fixture without loading a model.
swift run --package-path Packages/CompletionBenchmark keytype-benchmark validate --suite smoke

# Run smoke against the default KeyType model/profile, if installed.
swift run -c release --package-path Packages/CompletionBenchmark keytype-benchmark run --suite smoke

# Run one or more explicit models.
swift run -c release --package-path Packages/CompletionBenchmark keytype-benchmark run \
  --suite core \
  --cases Benchmarks/Datasets/core.jsonl \
  --model "/path/to/model-a.gguf" \
  --model "/path/to/model-b.gguf"

# Compile human-written source documents into cases.
swift run --package-path Packages/CompletionBenchmark keytype-benchmark compile \
  --sources Benchmarks/Private/source-docs.jsonl \
  --output Benchmarks/Private/core.jsonl \
  --suite core \
  --split eval
```

The committed `smoke` suite is tiny and public. Larger `core`, `hard`, `latency`, and
`human-calibration` datasets should live under `Benchmarks/Private/` or
`Benchmarks/Datasets/private/`, both of which are gitignored.

Outputs are written as:

- `rows.jsonl`: row-level diagnostics, including top candidates, prompt token count,
  suppression reason, score contribution, and latency.
- `aggregate.json`: aggregate metrics plus per-tag breakdowns.
- `aggregate.csv`: one row per model, suitable for plotting quality/precision against p95 latency.
