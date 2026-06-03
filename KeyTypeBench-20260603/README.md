# Benchmark Datasets

These are the committed public/permissive fixtures for `Packages/KeyTypeBench`.

## Files

- `Datasets/smoke.jsonl`: 36 fast public cases.
- `Datasets/core.jsonl`: 700 broad quality cases.
- `Datasets/edge.jsonl`: 300 mid-word, FIM, duplication, code, abbreviation, and app-trap cases.
- `Datasets/policy.jsonl`: 72 handcrafted suppression/app-compatibility cases.
- `Datasets/latency.jsonl`: 100 short/medium/long prompt-shape cases.
- `Sources/public-source-documents.jsonl`: 1,133 source-document chunks used to generate the cases.
- `Sources/summary.json`: generated counts by suite, tag, split, and source bucket.
- `Scripts/generate_datasets.py`: regenerates the committed datasets.
- `Scripts/generate_comparison_graphs.py`: regenerates comparison graphs from `Results/*/aggregate.json`.
- `Scripts/run_model_comparison.sh`: runs a GGUF through `core`, `edge`, and `policy`, then regenerates graphs.

## Sources

Field text is human-written and public/permissive. The main prose source is
`singletongue/wikipedia-paragraphs` via the Hugging Face Dataset Viewer, using the
`enwiki-20260301-v1.2.0` split. The generator selects later offset bands and skips high-inlink
pages where metadata is available to reduce obvious memorization risk.

Other sources are tldr pages, CC0 prompt examples, OpenAI Cookbook documentation, KeyType docs, and
bounded Swift source/comment snippets from KeyType and Swift Argument Parser. No Project Gutenberg
or classic novel source text is used.

App/window/domain labels, placeholders, screen context, and previous-input metadata are synthetic.
Some Wikipedia prose is placed in Mail, Messages, and browser-form surfaces to exercise app context;
those rows remain tagged with `wikipedia` provenance.

## Regeneration

```sh
python3 KeyTypeBench-20260603/Scripts/generate_datasets.py
```

Then validate:

```sh
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite smoke
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite core
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite edge
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite policy
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite latency
```

Private calibration data stays under `KeyTypeBench-20260603/Private/` or `KeyTypeBench-20260603/Datasets/private/`; both
paths are gitignored.

## Model Comparison

Run a model through the standard comparison suites and refresh the graphs:

```sh
KeyTypeBench-20260603/Scripts/run_model_comparison.sh \
  --model "$HOME/Library/Application Support/KeyType/Models/Qwen3.5-2B-Base.i1-Q4_K_M.gguf"
```

The script writes suite outputs under `KeyTypeBench-20260603/Results/<model>/` and regenerates
`KeyTypeBench-20260603/Results/keytype-model-comparison/`.

Interpret `qualityScore` as non-negative utility, not as a penalty-weighted trust score. Wrong
visible suggestions contribute `0.0` and remain visible through `wrongShowRate` and
`precisionWhenShown`; use those guardrails before comparing quality, coverage, and latency.

To rebuild graphs from existing aggregates without running a model:

```sh
python3 KeyTypeBench-20260603/Scripts/generate_comparison_graphs.py
```
