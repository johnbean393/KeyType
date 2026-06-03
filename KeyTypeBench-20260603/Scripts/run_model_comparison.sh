#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  KeyTypeBench-20260603/Scripts/run_model_comparison.sh --model /path/to/model.gguf [options]

Runs the model through the comparison suites and regenerates:
  KeyTypeBench-20260603/Results/keytype-model-comparison/

Options:
  --model PATH              GGUF model to evaluate. Required.
  --result-name NAME        Result directory name under KeyTypeBench-20260603/Results/.
                            Defaults to a catalog-style slug derived from the filename.
  --context-length N        Llama context length. Defaults to KeyTypeBench default.
  --profile PATH            ACPF profile path to use for this model.
  --profile-directory DIR   Directory containing <family>.acpf.bin profiles.
  --skip-graphs             Run benchmarks but do not regenerate comparison graphs.
  -h, --help                Show this help.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bench_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$bench_root/.." && pwd)"
results_root="$bench_root/Results"

model_path=""
result_name=""
context_length=""
profile_path=""
profile_directory=""
skip_graphs=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      model_path="${2:-}"
      shift 2
      ;;
    --result-name)
      result_name="${2:-}"
      shift 2
      ;;
    --context-length)
      context_length="${2:-}"
      shift 2
      ;;
    --profile)
      profile_path="${2:-}"
      shift 2
      ;;
    --profile-directory)
      profile_directory="${2:-}"
      shift 2
      ;;
    --skip-graphs)
      skip_graphs=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$model_path" ]]; then
  echo "--model is required." >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$model_path" ]]; then
  echo "Model does not exist: $model_path" >&2
  exit 1
fi

derive_result_name() {
  local base
  base="$(basename "$1" .gguf)"
  case "$base" in
    Qwen3.5-0.8B-Base*) echo "qwen3.5-0.8b-base" ;;
    Qwen3.5-2B-Base*) echo "qwen3.5-2b-base" ;;
    Qwen3.5-4B-Base*) echo "qwen3.5-4b-base" ;;
    LFM2.5-8B-A1B*) echo "lfm2.5-8b-a1b" ;;
    gemma-4-E2B*) echo "gemma-4-e2b" ;;
    gemma-4-E4B*) echo "gemma-4-e4b" ;;
    *)
      echo "$base" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9.]+/-/g; s/^-+//; s/-+$//'
      ;;
  esac
}

if [[ -z "$result_name" ]]; then
  result_name="$(derive_result_name "$model_path")"
fi

common_args=()
if [[ -n "$context_length" ]]; then
  common_args+=(--context-length "$context_length")
fi
if [[ -n "$profile_path" ]]; then
  common_args+=(--profile "$profile_path")
fi
if [[ -n "$profile_directory" ]]; then
  common_args+=(--profile-directory "$profile_directory")
fi

run_suite() {
  local suite="$1"
  local cases="$2"
  local output="$3"
  local split="${4:-}"

  mkdir -p "$output"
  local cmd=(
    swift run -c release
    --package-path "$repo_root/Packages/KeyTypeBench"
    KeyTypeBench run
    --suite "$suite"
    --cases "$cases"
    --model "$model_path"
    --output "$output"
  )
  if [[ -n "$split" ]]; then
    cmd+=(--split "$split")
  fi
  if [[ ${#common_args[@]} -gt 0 ]]; then
    cmd+=("${common_args[@]}")
  fi

  echo "Running $suite -> $output"
  (
    cd "$repo_root"
    "${cmd[@]}"
  ) 2>&1 | tee "$output/run.log"
}

model_results="$results_root/$result_name"
mkdir -p "$model_results"

run_suite "core" "$bench_root/Datasets/core.jsonl" "$model_results/core-eval" "eval"
run_suite "edge" "$bench_root/Datasets/edge.jsonl" "$model_results/edge-eval" "eval"
run_suite "policy" "$bench_root/Datasets/policy.jsonl" "$model_results/policy" "eval"

if [[ "$skip_graphs" -eq 0 ]]; then
  python3 "$script_dir/generate_comparison_graphs.py" --results-dir "$results_root"
fi
