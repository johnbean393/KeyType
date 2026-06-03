# KeyType - Benchmark Dataset Curation

This documents how the V1 public benchmark dataset snapshot in `KeyTypeBench-20260603/` was
created. The reusable harness lives in `Packages/KeyTypeBench/`; the dated directory is the
auditable source/case snapshot for the June 3, 2026 evaluation work.

## Goals

- Evaluate final visible KeyType behavior, not raw model completions.
- Score useful visible behavior separately from wrong-show risk so model comparisons mirror the
  user experience.
- Keep field text human-written, public, and permissively reusable.
- Use synthetic data only for app/window/domain metadata, labels, placeholders, screen context,
  clipboard state, and previous-input metadata.
- Split at `sourceGroup` boundaries so the same source document family never appears in multiple
  splits.
- Keep private user calibration out of git.

## Artifact Layout

| Path | Purpose |
| --- | --- |
| `KeyTypeBench-20260603/Scripts/generate_datasets.py` | End-to-end generator for source manifests, cases, and summary counts. |
| `KeyTypeBench-20260603/Scripts/generate_comparison_graphs.py` | Rebuilds model-comparison charts from aggregate result JSON files. |
| `KeyTypeBench-20260603/Scripts/run_model_comparison.sh` | Runs a GGUF through the standard comparison suites and regenerates charts. |
| `KeyTypeBench-20260603/Sources/public-source-documents.jsonl` | Auditable source-document manifest used before slicing into cases. |
| `KeyTypeBench-20260603/Sources/summary.json` | Generated counts by source bucket, split, suite, expected kind, and selected tags. |
| `KeyTypeBench-20260603/Datasets/*.jsonl` | Committed public suites: `smoke`, `core`, `edge`, `policy`, and `latency`. |
| `KeyTypeBench-20260603/Results/keytype-model-comparison/` | Generated comparison PNG/CSV/TXT artifacts for current model aggregates. |
| `Packages/KeyTypeBench/Sources/KeyTypeBench/Datasets/smoke.jsonl` | Tiny package resource fixture retained for package-level schema tests. |

Private calibration data is intentionally excluded by `.gitignore` under
`KeyTypeBench-20260603/Private/`, `KeyTypeBench-20260603/Datasets/private/`, and
`KeyTypeBench-20260603/Datasets/local/`.

## Source Selection

The main prose source is English Wikipedia through the Hugging Face Dataset Viewer API:

- Dataset: `singletongue/wikipedia-paragraphs`
- Config: `enwiki-20260301-v1.2.0`
- Split: `train`
- Access pattern: API row requests with fixed offset bands per writing surface

Wikipedia rows are used for the broad prose surfaces: notes/docs, browser/web forms, email-like
drafts, and messaging/chat-like contexts. The field text remains Wikipedia text; the surrounding
app metadata is synthetic so the same kind of human-written prose can exercise different KeyType
contexts.

The V1 snapshot also includes bounded non-Wikipedia sources for surfaces Wikipedia cannot represent
well:

| Source kind | License/provenance | Why included |
| --- | --- | --- |
| `cli-doc` | CC BY 4.0, tldr-pages contributors | Terminal-like command text and CLI documentation. |
| `prompt-list` | CC0 1.0, `awesome-chatgpt-prompts` | Human-authored AI prompt drafting surfaces. |
| `documentation` | MIT, OpenAI Cookbook contributors | Prompt/documentation prose. |
| `project-doc` | MIT, KeyType repository | Local product documentation surfaces. |
| `source-code` | MIT KeyType and Apache-2.0 Swift Argument Parser | Bounded code/comment coverage for editor behavior. |

No Project Gutenberg, classic novel text, Stack Exchange content, or private user text is included.

## Filtering And Cleaning

The generator uses source-specific processors before creating the manifest:

- Hugging Face Wikipedia rows are parsed from API JSON. Only `article` rows are kept.
- Wikipedia pages with `num_inlinks > 250` are skipped when that metadata is present to reduce
  obvious memorization risk.
- A small blocklist removes very common or heavily memorized titles such as major countries,
  major cities, famous franchises, and broad historical topics.
- Markdown sources have code fences, images, links, headings, and list markers normalized away.
- Prompt CSV rows keep only prompt text long enough to produce useful slices.
- Code sources remove imports and marker comments, preserve line structure, and cap long lines.
- Usable prose chunks must be at least 80 characters and contain at least 50 alphabetic characters.
- Chunks containing terms-of-use, unsubscribe, all-rights-reserved, or copyright boilerplate are
  rejected.

After cleaning, prose is chunked into 100-1100 character source documents. Code is chunked into
160-1400 character blocks. Each chunk becomes one row in `public-source-documents.jsonl`.

## Source Manifest

The manifest is written before benchmark cases are compiled. Each row includes:

- `id`
- `sourceGroup`
- `split`
- `text`
- `source.kind`, `source.title`, `source.url` or `source.path`, `source.license`, and optional
  `source.note`
- `tags`, including the source bucket and `real`
- intended `caseTypes`
- synthetic target metadata for the intended app surface
- `contextSources`, with `fieldText: "real"` and synthetic labels/app context where applicable

The V1 public manifest contains:

| Metric | Count |
| --- | ---: |
| Source documents | 1,133 |
| Source groups | 70 |
| Wikipedia source documents | 784 |
| Dev source documents | 131 |
| Eval source documents | 868 |
| Holdout source documents | 134 |

Source bucket distribution:

| Bucket | Source docs |
| --- | ---: |
| `notes-docs` | 288 |
| `browser-web-form` | 224 |
| `email` | 168 |
| `messaging-chat` | 168 |
| `code-comments` | 168 |
| `ai-chat` | 72 |
| `terminal` | 45 |

## Split Assignment

Splits are assigned deterministically from `sourceGroup`:

1. Hash `sourceGroup` with SHA-256.
2. Convert the first 8 hex digits to an integer modulo 100.
3. Assign `dev`, `holdout`, or `eval` from that value.

Generated suites then target the requested dev/eval/holdout proportions by choosing cases from the
already split source pools. The important invariant is that a `sourceGroup` is never split across
multiple dataset splits.

## Case Construction

Cases are generated by slicing source-manifest `text` at deterministic word boundaries:

| Case type | Construction |
| --- | --- |
| `append` | Cursor before a short immediate continuation at the end of the typed prefix. |
| `email` | Append slice placed in Mail/Gmail-like synthetic context. |
| `messaging` | Append slice placed in Messages/Slack/Discord-like synthetic context. |
| `browser` | Append slice placed in browser comment/form synthetic context. |
| `code` | Append slice from bounded source-code/comment chunks in Xcode/VS Code context. |
| `midword` | Cursor splits a long word; expected text completes the current word fragment. |
| `fim` | Cursor is mid-line with `afterCursor` populated from the same source text. |
| `duplication` | `afterCursor` begins with the target continuation; expected result is suppression. |
| `abbrev-list` | Synthetic checklist/list prefix plus real source continuation. |
| `app-trap` | Terminal-like context expected to suppress for app policy. |

Positive cases use short `modelTarget` strings and `shownAcceptable` variants derived from the
same target with whitespace normalized. Suppression cases carry explicit `allowedReasons`, such as
`duplicatesAfterCursor`, `tabShortcutsDisabled`, `midLineCompletionDisabled`, or
`secureFieldExcluded`.

Policy rows are handcrafted synthetic fixtures. They do not contain real field text and cover
password managers, password domains, terminal Tab handling, and terminal mid-line policy.

## Scoring Semantics

The benchmark scores the final ghost text or suppression reason, but the blended `qualityScore` is
not a negative-penalty utility function. A wrong visible suggestion is bad UX and must remain
visible in the report, but the offline benchmark cannot know whether the user would ignore it, lose
trust, or accept it by mistake. Folding an arbitrary negative value into one score can make the
aggregate harder to interpret and can cause "never show anything" behavior to look better than a
model that is sometimes useful but too noisy.

Rows therefore contribute:

| Outcome | Contribution | UX interpretation |
| --- | ---: | --- |
| `correctInsert` | 1.0 | Useful text was shown on a positive row. |
| `correctSuppression` | 1.0 | Unsafe or policy-forbidden text stayed hidden. |
| `acceptableSuppressionOnPositive` | 0.3 | Showing nothing was acceptable but not useful. |
| `wrongShown` | 0.0 | No utility credit; evaluate through `wrongShowRate` and `precisionWhenShown`. |
| `incorrectSuppression` | 0.0 | No utility credit because the suppression reason was wrong. |

Use `qualityScore`, `positiveCoverage`, and latency to compare utility only after checking
`wrongShowRate`, `precisionWhenShown`, and `suppressionAccuracy`. This preserves KeyType's product
rule - prefer suppression to a wrong suggestion - without hiding wrong visible suggestions inside a
single blended score.

## Suite Mix

The generated V1 suites are:

| Suite | Rows | Purpose |
| --- | ---: | --- |
| `smoke` | 36 | Fast public sanity check with positive inserts plus secure-field suppressions. |
| `core` | 700 | Broad quality distribution across prose, email, messaging, browser, code, mid-word, FIM, and duplication traps. |
| `edge` | 300 | Focused edge distribution for mid-word, FIM, duplication, code, abbreviations/lists, and app traps. |
| `policy` | 72 | Handcrafted suppression/app-compatibility checks. |
| `latency` | 100 | Short/medium/long append prompts for release-mode latency comparisons. |

`core` follows the planned mix closely: 210 append, 105 email, 105 messaging, 70 browser, 70 code,
70 mid-word, 35 FIM, and 35 duplication-trap cases. `edge` contains 75 mid-word, 75 FIM, 60
duplication-trap, 30 code, 30 abbreviation/list, and 30 app-trap cases.

## Regeneration

Regenerate the public snapshot from the repository root:

```sh
python3 KeyTypeBench-20260603/Scripts/generate_datasets.py
```

The generator fetches remote public sources, so network access is required. The Hugging Face
Wikipedia source is pinned by dataset config and fixed offsets; GitHub raw sources follow the URLs
specified in the script.

Validate every suite:

```sh
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite smoke
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite core
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite edge
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite policy
swift run --package-path Packages/KeyTypeBench KeyTypeBench validate --suite latency
```

Run the committed dataset guard tests:

```sh
swift test --package-path Packages/KeyTypeBench --filter CommittedDatasetTests
```

Run model evaluation in release mode:

```sh
swift run -c release --package-path Packages/KeyTypeBench KeyTypeBench run --suite smoke
```

Use `--cases KeyTypeBench-20260603/Datasets/<suite>.jsonl` when running a suite from the dated
snapshot explicitly.

For comparison runs, use the wrapper so charts are refreshed after the model finishes:

```sh
KeyTypeBench-20260603/Scripts/run_model_comparison.sh \
  --model "$HOME/Library/Application Support/KeyType/Models/Qwen3.5-2B-Base.i1-Q4_K_M.gguf"
```

That runs `core` and `edge` on the `eval` split plus the `policy` suite, then regenerates
`KeyTypeBench-20260603/Results/keytype-model-comparison/`. To rebuild graphs from existing
aggregate files without running a model:

```sh
python3 KeyTypeBench-20260603/Scripts/generate_comparison_graphs.py
```

## Review Checklist

Before accepting a dataset update:

- Confirm each source has a public URL/path and license/provenance metadata.
- Confirm `fieldText` is `real` except for policy-only synthetic suppression fixtures.
- Confirm no source group appears in more than one split.
- Confirm generated `summary.json` matches the intended suite counts and case mix.
- Run `KeyTypeBench validate` for every committed suite.
- Run `CommittedDatasetTests`.
- Inspect a sample of rows from each suite manually, especially `shownAcceptable`,
  `afterCursor`, and suppression `allowedReasons`.
- Keep private calibration rows only in gitignored private/local paths.
