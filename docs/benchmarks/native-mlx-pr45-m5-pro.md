# PR #45 native MLX benchmark

Date: 2026-08-15

Machine: 24 GB Apple M5 Pro

Build: release (`swift test -c release`)

## Method

Each backend used the same deterministic workload:

- anchor: `The quick brown fox`
- suffix set: ` jumps`, ` runs`, ` walks`, ` moves`, ` waits`, ` speaks`, ` writes`, ` works`
- 200 warm anchored requests, selected with seed `0x4D4C585F323030`
- first-visible latency: the first anchored request after the runtime finished loading
- percentiles: nearest-rank, lower interpolation
- prompt tokens: mean over the suffix set
- forward passes: one per request, 200 total

MLX used the exact pinned public bundles from the catalog:

These are `mlx-community` post-trained conversions. They are not Qwen-published MLX bundles and
are not labeled as Base checkpoints.

| Model | Model card | Revision | `model.safetensors` SHA-256 |
| --- | --- | --- | --- |
| 0.8B MLX 6-bit | [mlx-community/Qwen3.5-0.8B-6bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-6bit) | `779b383518183ae3af13b26a5cdc829a26f7c937` | `24e8db49de3a266ff8d3a0aa7277244c44982ad9f78584923500de46b0bfb8fe` |
| 2B MLX 4-bit | [mlx-community/Qwen3.5-2B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit) | `93760be4f1f69842a46bc13dbdc0f19e291392a3` | `713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5` |
| 4B MLX 4-bit | [mlx-community/Qwen3.5-4B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit) | `32f3e8ecf65426fc3306969496342d504bfa13f3` | `5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db` |

The comparison GGUF files were the matching Qwen3.5 Base variants from the
`mradermacher` GGUF repositories: 0.8B `Q6_K`, 2B `Q4_K_M`, and 4B `Q4_K_M`.
The benchmark accepts `KEYTYPE_LLAMA_MODEL_PATH` for the 0.8B and 4B files; the 2B comparison
uses the existing default GGUF path.

## Results

Values are milliseconds except prompt tokens, forward passes, and RSS. Delta rows are
`MLX - GGUF` as a percentage; positive latency means slower, while negative latency means faster.
Peak RSS is the maximum resident memory observed for the test process at 50 ms sampling intervals;
it is not a complete unified-memory or system-energy measurement.

| Model | Backend | Cold load | First visible | Warm p50 | Warm p90 | Warm p95 | Prompt tokens | Forward passes | Peak test RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.8B | GGUF | 491.15 ms | 30.88 ms | 5.24 ms | 5.48 ms | 5.68 ms | 5.00 | 200 | 873.5 MB |
| 0.8B | MLX | 1398.39 ms | 37.72 ms | 6.00 ms | 6.62 ms | 6.76 ms | 5.00 | 200 | 869.0 MB |
| 0.8B | MLX delta | +184.7% | +22.2% | +14.5% | +20.8% | +19.0% | 0.0% | 0.0% | -0.5% |
| 2B | GGUF | 545.03 ms | 33.36 ms | 7.58 ms | 7.79 ms | 7.88 ms | 5.00 | 200 | 1480.4 MB |
| 2B | MLX | 1297.44 ms | 36.84 ms | 7.23 ms | 7.64 ms | 7.89 ms | 5.00 | 200 | 1283.0 MB |
| 2B | MLX delta | +138.0% | +10.4% | -4.6% | -1.9% | +0.1% | 0.0% | 0.0% | -13.3% |
| 4B | GGUF | 1037.58 ms | 61.91 ms | 15.63 ms | 16.25 ms | 16.53 ms | 5.00 | 200 | 2957.6 MB |
| 4B | MLX | 1774.42 ms | 286.91 ms | 13.79 ms | 14.24 ms | 14.57 ms | 5.00 | 200 | 1397.2 MB |
| 4B | MLX delta | +71.0% | +363.4% | -11.8% | -12.4% | -11.9% | 0.0% | 0.0% | -52.8% |

## Limits

- Energy was not captured: `powermetrics` requires superuser access in this environment.
- User-facing completion quality was not measured. The existing KeyTypeBench pipeline is GGUF-only,
  so this benchmark makes no unsupported MLX quality or parity claim.
- This is an anchored-logit runtime microbenchmark, not an end-to-end typing-to-overlay test.
- MTP is not included. GGUF remains the default backend and default model path.

The MLX warm p50/p90 path is faster for the 2B and 4B pairs in this run; the 2B p95 is effectively
flat. Every MLX bundle had slower cold load, and the 4B bundle had materially higher first-visible
latency. Those are reported as regressions rather than hidden behind an aggregate score.
