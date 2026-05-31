# KeyType — Performance & Latency

KeyType must feel **instant per keystroke**. Latency is a first-class quality signal: a correct
completion that arrives too late is still a bad experience. This doc captures the methodology so
performance work doesn't relearn the same lessons.

## The one rule that matters most

**Always measure in a `release` build.** A debug build inflates per-token Swift work by **1–2 orders
of magnitude**, so debug timings are meaningless for tuning decisions (ADR-012). Run the package
benchmarks and the app with the Release configuration before drawing any conclusion.

```sh
swift test -c release --package-path Packages/ConstrainedGeneration
swift test -c release --package-path Packages/ModelRuntime
```

The GGUF-backed timing tests `XCTSkipUnless` a real model is present in the app-support container
(ADR-007), so they only run on a machine that has downloaded a model.

## Where the time goes

The per-keystroke cost is dominated by model decode, not Swift glue. Capture is cheap
(~0.3 ms; the old "20 ms capture" was a synchronization artifact — ADR-045). The levers, in order of
impact discovered so far:

1. **KV reuse across keystrokes (ADR-018).** Decode the base prompt once and snapshot/restore it per
   branch; append only the typed delta across keystrokes. This is the biggest steady-state win
   (medium-append case ~1140 decoded tokens / ~246 ms → ~115 tokens / ~87 ms; 12 full prefills → 1).
   Note: cross-sequence `seq_cp` **aborts** on the hybrid recurrent/SSM model, so we use
   `llama_state_seq` snapshot/restore, not `seq_cp/keep/rm`.
2. **Batched beam-frontier decoding (ADR-043).** One `llama_decode` per depth level instead of one
   per branch — the cold-start cut.
3. **Incremental beam decoding (ADR-046).** Keep branches resident and decode one new token per
   level on the warm/append path (~1.31× / ~11 ms saved per keystroke, no quality change).
4. **Beam tuning (ADR-012).** Per-completion cost scales with branch expansions; `branchWidth`
   defaults to 4. `TokenSampler` pre-selects top candidates by raw logit so per-step work is bounded
   instead of vocabulary-wide. (Exception: required-prefix decoding bypasses that pre-selection —
   ADR-025.)

## Numerical-correctness envelope (don't chase phantom "bugs")

The hybrid Gated-Delta-Net model is **not bit-identical** between chunk-size-1 and chunk-size-N
decode, so incremental/reseed/snapshot paths differ slightly from a clean sequential decode. The
documented envelope is `|Δlogit| ≤ ~0.12` (ADR-012/018/043/046). A strict top-k-*set* assertion is
too brittle here; the correctness gates use a quantitative max-`|Δlogit|` bound plus argmax stability
only for well-separated branches. Before "fixing" a small logit drift, confirm it's actually outside
this envelope.

## Profiling methodology

- Profile **components**, not just totals — the detailed component profile (ADR-044) found that
  snapshot **capture**, not the LM head, was the next lever. Re-measure where time goes before
  optimizing; intuition about the bottleneck has been wrong before.
- Use the warm/append path for steady-state numbers and the cold path for first-completion cost;
  report both, since they're tuned by different mechanisms.
- Tie any change to a benchmark assertion so a regression is caught by `swift test -c release`.

## Budgets to hold

- **Per-keystroke steady state:** must feel instant; keep leaning on KV reuse as models/contexts
  grow. `maxPromptTokens` is derived from this latency budget (ADR-008) — raising context size
  trades directly against responsiveness.
- **Concurrency:** model decode runs off the main actor; AX + overlay are `@MainActor`. Generation
  is cancellable — a newer keystroke must cancel in-flight work (verify cancellation still propagates
  whenever you touch the engine).

## Log it

Record perf wins/regressions and their release-build measurements as a new ADR in `05-decisions.md`
(prior art: ADR-012/018/043/044/045/046).
