#!/usr/bin/env python3
"""Generate KeyTypeBench model-comparison graphs from aggregate result files."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
import numpy as np


SUITE_DIRS = {
    "core": "core-eval",
    "edge": "edge-eval",
    "policy": "policy",
}

SUITE_LABELS = {
    "core": "Core",
    "edge": "Edge",
    "policy": "Policy",
}

DEFAULT_SUITES = ("core", "edge", "policy")
DEFAULT_POSITIVE_SUITES = ("core", "edge")

KNOWN_LABELS = [
    (re.compile(r"Qwen3\.5-0\.8B", re.IGNORECASE), "Qwen3.5 0.8B"),
    (re.compile(r"Qwen3\.5-2B", re.IGNORECASE), "Qwen3.5 2B"),
    (re.compile(r"Qwen3\.5-4B", re.IGNORECASE), "Qwen3.5 4B"),
    (re.compile(r"LFM2\.5-8B-A1B", re.IGNORECASE), "LFM2.5 8B A1B"),
    (re.compile(r"gemma-4-E2B", re.IGNORECASE), "Gemma 4 E2B"),
    (re.compile(r"gemma-4-E4B", re.IGNORECASE), "Gemma 4 E4B"),
]


@dataclass(frozen=True)
class ModelRecord:
    identifier: str
    label: str
    directory: str


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_results_dir() -> Path:
    return repo_root() / "KeyTypeBench-20260603" / "Results"


def display_label(row: dict[str, Any]) -> str:
    source = " ".join(
        str(row.get(key, "")) for key in ("modelIdentifier", "modelFilename", "modelPath")
    )
    for pattern, label in KNOWN_LABELS:
        if pattern.search(source):
            return label

    identifier = str(row.get("modelIdentifier") or row.get("modelFilename") or "unknown-model")
    label = re.sub(r"\.gguf$", "", identifier, flags=re.IGNORECASE)
    label = re.sub(r"\.i1-[A-Za-z0-9_]+$", "", label)
    label = re.sub(r"-Q[0-9A-Za-z_]+$", "", label)
    return label.replace("-", " ")


def model_sort_key(record: ModelRecord) -> tuple[int, str]:
    haystack = f"{record.identifier} {record.label}"
    for index, (pattern, _label) in enumerate(KNOWN_LABELS):
        if pattern.search(haystack):
            return (index, record.label)
    return (len(KNOWN_LABELS), record.label.lower())


def load_aggregate(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        loaded = json.load(handle)
    if isinstance(loaded, list):
        return [row for row in loaded if isinstance(row, dict)]
    if isinstance(loaded, dict):
        return [loaded]
    return []


def collect_rows(results_dir: Path, suites: tuple[str, ...]) -> tuple[list[ModelRecord], dict[tuple[str, str], dict[str, Any]]]:
    latest: dict[tuple[str, str], tuple[float, dict[str, Any]]] = {}
    records: dict[str, ModelRecord] = {}

    for model_dir in sorted(results_dir.iterdir() if results_dir.exists() else []):
        if not model_dir.is_dir():
            continue
        if model_dir.name in {"keytype-model-comparison", "comparison"}:
            continue
        if model_dir.name.endswith("-verification"):
            continue

        for suite in suites:
            suite_dir = SUITE_DIRS.get(suite, suite)
            aggregate_path = model_dir / suite_dir / "aggregate.json"
            if not aggregate_path.exists():
                continue

            mtime = aggregate_path.stat().st_mtime
            for row in load_aggregate(aggregate_path):
                actual_suite = str(row.get("suite") or suite)
                if actual_suite not in suites:
                    continue
                identifier = str(row.get("modelIdentifier") or model_dir.name)
                row = dict(row)
                row["model"] = display_label(row)
                row["modelDir"] = model_dir.name

                key = (identifier, actual_suite)
                previous = latest.get(key)
                if previous is None or mtime >= previous[0]:
                    latest[key] = (mtime, row)
                    records[identifier] = ModelRecord(
                        identifier=identifier,
                        label=row["model"],
                        directory=model_dir.name,
                    )

    row_by = {key: row for key, (_mtime, row) in latest.items()}
    model_records = sorted(records.values(), key=model_sort_key)
    return model_records, row_by


def numeric(row_by: dict[tuple[str, str], dict[str, Any]], model_id: str, suite: str, metric: str) -> float:
    row = row_by.get((model_id, suite))
    if row is None:
        return math.nan
    value = row.get(metric)
    if value is None:
        return math.nan
    return float(value)


def present_models(
    models: list[ModelRecord],
    row_by: dict[tuple[str, str], dict[str, Any]],
    suites: tuple[str, ...],
) -> list[ModelRecord]:
    return [
        model
        for model in models
        if any((model.identifier, suite) in row_by for suite in suites)
    ]


def configure_plots() -> None:
    plt.rcParams.update(
        {
            "figure.dpi": 160,
            "savefig.dpi": 180,
            "font.size": 10,
            "axes.titlesize": 13,
            "axes.labelsize": 10,
            "axes.edgecolor": "#334155",
            "axes.labelcolor": "#0f172a",
            "xtick.color": "#0f172a",
            "ytick.color": "#0f172a",
            "grid.color": "#cbd5e1",
            "grid.linewidth": 0.7,
            "legend.frameon": False,
        }
    )


def value_label(value: float, *, percent: bool = False) -> str:
    if percent:
        return f"{value:.1f}%"
    if abs(value) >= 100:
        return f"{value:.0f}"
    return f"{value:.2f}"


def grouped_bars(
    output_dir: Path,
    filename: str,
    title: str,
    ylabel: str,
    models: list[ModelRecord],
    row_by: dict[tuple[str, str], dict[str, Any]],
    suites: tuple[str, ...],
    metric: str,
    colors: dict[str, str],
    *,
    percent: bool = False,
    ylim: tuple[float, float] | None = None,
) -> None:
    x = np.arange(len(suites))
    width = min(0.8 / max(len(models), 1), 0.18)
    fig, ax = plt.subplots(figsize=(max(9.0, 1.0 * len(models) + 6.0), 5.1))

    for index, model in enumerate(models):
        vals = []
        for suite in suites:
            value = numeric(row_by, model.identifier, suite, metric)
            vals.append(value * 100 if percent and math.isfinite(value) else value)
        offset = (index - (len(models) - 1) / 2) * width
        bars = ax.bar(
            x + offset,
            vals,
            width,
            label=model.label,
            color=colors[model.identifier],
        )
        for bar, val in zip(bars, vals):
            if not math.isfinite(float(val)):
                continue
            va = "bottom" if val >= 0 else "top"
            yoff = 4 if val >= 0 else -4
            ax.annotate(
                value_label(float(val), percent=percent),
                (bar.get_x() + bar.get_width() / 2, val),
                xytext=(0, yoff),
                textcoords="offset points",
                ha="center",
                va=va,
                fontsize=8,
                color="#334155",
            )

    ax.set_title(title, pad=12)
    ax.set_ylabel(ylabel)
    ax.set_xticks(x)
    ax.set_xticklabels([SUITE_LABELS.get(suite, suite.title()) for suite in suites])
    if ylim is not None:
        ax.set_ylim(*ylim)
    ax.yaxis.grid(True)
    ax.set_axisbelow(True)
    ax.legend(loc="best", ncols=2 if len(models) > 2 else 1)
    fig.tight_layout()
    fig.savefig(output_dir / filename, bbox_inches="tight")
    plt.close(fig)


def grouped_two_metric(
    output_dir: Path,
    filename: str,
    title: str,
    models: list[ModelRecord],
    row_by: dict[tuple[str, str], dict[str, Any]],
    suites: tuple[str, ...],
    metrics: tuple[tuple[str, str], ...],
    colors: dict[str, str],
) -> None:
    x = np.arange(len(suites))
    width = min(0.8 / max(len(models), 1), 0.18)
    fig, axes = plt.subplots(1, len(metrics), figsize=(12.8, 5.0), sharey=True)
    if len(metrics) == 1:
        axes = [axes]

    for ax, (metric, label) in zip(axes, metrics):
        for index, model in enumerate(models):
            vals = [
                numeric(row_by, model.identifier, suite, metric) * 100
                for suite in suites
            ]
            offset = (index - (len(models) - 1) / 2) * width
            bars = ax.bar(
                x + offset,
                vals,
                width,
                label=model.label,
                color=colors[model.identifier],
            )
            for bar, val in zip(bars, vals):
                if not math.isfinite(float(val)):
                    continue
                ax.annotate(
                    f"{val:.1f}%",
                    (bar.get_x() + bar.get_width() / 2, bar.get_height()),
                    xytext=(0, 4),
                    textcoords="offset points",
                    ha="center",
                    fontsize=8,
                    color="#334155",
                )
        ax.set_title(label)
        ax.set_xticks(x)
        ax.set_xticklabels([SUITE_LABELS.get(suite, suite.title()) for suite in suites])
        ax.set_ylim(0, 100)
        ax.yaxis.grid(True)
        ax.set_axisbelow(True)

    axes[0].set_ylabel("Rate")
    axes[-1].legend(loc="upper right")
    fig.suptitle(title, y=1.02, fontsize=13)
    fig.tight_layout()
    fig.savefig(output_dir / filename, bbox_inches="tight")
    plt.close(fig)


def latency_percentile_panels(
    output_dir: Path,
    filename: str,
    models: list[ModelRecord],
    row_by: dict[tuple[str, str], dict[str, Any]],
    suites: tuple[str, ...],
    colors: dict[str, str],
) -> None:
    metrics = (
        ("p50TotalMs", "p50 Total Latency"),
        ("p95TotalMs", "p95 Total Latency"),
    )
    all_values = [
        numeric(row_by, model.identifier, suite, metric)
        for metric, _label in metrics
        for model in models
        for suite in suites
    ]
    finite_values = [value for value in all_values if math.isfinite(value)]
    top = max(100.0, max(finite_values) * 1.15 if finite_values else 100.0)

    x = np.arange(len(suites))
    width = min(0.8 / max(len(models), 1), 0.18)
    fig, axes = plt.subplots(1, len(metrics), figsize=(12.8, 5.0), sharey=True)

    for ax, (metric, label) in zip(axes, metrics):
        for index, model in enumerate(models):
            vals = [numeric(row_by, model.identifier, suite, metric) for suite in suites]
            offset = (index - (len(models) - 1) / 2) * width
            bars = ax.bar(
                x + offset,
                vals,
                width,
                label=model.label,
                color=colors[model.identifier],
            )
            for bar, val in zip(bars, vals):
                if not math.isfinite(float(val)):
                    continue
                ax.annotate(
                    value_label(float(val)),
                    (bar.get_x() + bar.get_width() / 2, bar.get_height()),
                    xytext=(0, 4),
                    textcoords="offset points",
                    ha="center",
                    fontsize=8,
                    color="#334155",
                )
        ax.set_title(label)
        ax.set_xticks(x)
        ax.set_xticklabels([SUITE_LABELS.get(suite, suite.title()) for suite in suites])
        ax.set_ylim(0, top)
        ax.yaxis.grid(True)
        ax.set_axisbelow(True)

    axes[0].set_ylabel("Milliseconds")
    axes[-1].legend(loc="upper right")
    fig.suptitle("Total Latency by Suite", y=1.02, fontsize=13)
    fig.tight_layout()
    fig.savefig(output_dir / filename, bbox_inches="tight")
    plt.close(fig)


def outcome_mix(
    output_dir: Path,
    filename: str,
    suite: str,
    models: list[ModelRecord],
    row_by: dict[tuple[str, str], dict[str, Any]],
) -> None:
    suite_models = present_models(models, row_by, (suite,))
    labels = ["Correct insert", "Correct suppression", "Wrong shown", "Positive suppressed"]
    keys = [
        "correctInsertCount",
        "correctSuppressionCount",
        "wrongShownCount",
        "positiveSuppressionCount",
    ]
    palette = ["#2563eb", "#059669", "#dc2626", "#64748b"]
    x = np.arange(len(suite_models))
    width = 0.64
    bottoms = np.zeros(len(suite_models))
    fig, ax = plt.subplots(figsize=(max(9.6, 1.0 * len(suite_models) + 6.0), 5.3))

    for key, label, color in zip(keys, labels, palette):
        vals = np.array(
            [numeric(row_by, model.identifier, suite, key) for model in suite_models]
        )
        vals = np.nan_to_num(vals)
        ax.bar(x, vals, width, bottom=bottoms, label=label, color=color)
        bottoms += vals

    ax.set_title(f"Outcome Mix: {SUITE_LABELS.get(suite, suite.title())}", pad=12)
    ax.set_ylabel("Rows")
    ax.set_xticks(x)
    ax.set_xticklabels([model.label for model in suite_models], rotation=12, ha="right")
    ax.yaxis.grid(True)
    ax.set_axisbelow(True)
    ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(output_dir / filename, bbox_inches="tight")
    plt.close(fig)


def tag_quality(
    output_dir: Path,
    filename: str,
    suite: str,
    tags: tuple[str, ...],
    models: list[ModelRecord],
    row_by: dict[tuple[str, str], dict[str, Any]],
    colors: dict[str, str],
) -> None:
    suite_models = present_models(models, row_by, (suite,))
    tags = tuple(sorted(tags, key=lambda tag: (tag_average_score(tag, suite, suite_models, row_by), tag)))
    fig, ax = plt.subplots(figsize=(12.2, 5.5))
    x = np.arange(len(tags))
    width = min(0.8 / max(len(suite_models), 1), 0.18)

    for index, model in enumerate(suite_models):
        row = row_by[(model.identifier, suite)]
        tag_metrics = row.get("byTag") or {}
        vals = [float(tag_metrics.get(tag, {}).get("qualityScore", math.nan)) for tag in tags]
        offset = (index - (len(suite_models) - 1) / 2) * width
        ax.bar(x + offset, vals, width, label=model.label, color=colors[model.identifier])

    ax.set_title(f"Tag Utility Score: {SUITE_LABELS.get(suite, suite.title())}", pad=12)
    ax.set_ylabel("Score")
    ax.set_xticks(x)
    ax.set_xticklabels([tag.replace("-", "\n") for tag in tags])
    ax.set_ylim(0, 1.05)
    ax.yaxis.grid(True)
    ax.set_axisbelow(True)
    ax.legend(loc="best", ncols=2 if len(suite_models) > 2 else 1)
    fig.tight_layout()
    fig.savefig(output_dir / filename, bbox_inches="tight")
    plt.close(fig)


def tag_average_score(
    tag: str,
    suite: str,
    models: list[ModelRecord],
    row_by: dict[tuple[str, str], dict[str, Any]],
) -> float:
    scores = []
    for model in models:
        row = row_by.get((model.identifier, suite))
        if row is None:
            continue
        tag_metrics = row.get("byTag") or {}
        value = tag_metrics.get(tag, {}).get("qualityScore")
        if value is None:
            continue
        score = float(value)
        if math.isfinite(score):
            scores.append(score)
    return sum(scores) / len(scores) if scores else math.inf


def color_map(models: list[ModelRecord]) -> dict[str, str]:
    palette = [
        "#7c3aed",
        "#2563eb",
        "#059669",
        "#c2410c",
        "#0891b2",
        "#be123c",
        "#4f46e5",
        "#ca8a04",
    ]
    return {model.identifier: palette[index % len(palette)] for index, model in enumerate(models)}


def write_summary(
    output_dir: Path,
    models: list[ModelRecord],
    row_by: dict[tuple[str, str], dict[str, Any]],
    suites: tuple[str, ...],
) -> None:
    fields = [
        "model",
        "modelIdentifier",
        "modelDir",
        "suite",
        "rowCount",
        "positiveCount",
        "negativeCount",
        "shownCount",
        "correctInsertCount",
        "correctSuppressionCount",
        "wrongShownCount",
        "positiveSuppressionCount",
        "precisionWhenShown",
        "positiveCoverage",
        "wrongShowRate",
        "suppressionAccuracy",
        "qualityScore",
        "p50TotalMs",
        "p95TotalMs",
    ]
    csv_path = output_dir / "keytype_model_comparison_summary.csv"
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for model in models:
            for suite in suites:
                row = row_by.get((model.identifier, suite))
                if row is None:
                    continue
                output = {field: row.get(field, "") for field in fields}
                output["model"] = model.label
                output["modelIdentifier"] = model.identifier
                output["modelDir"] = model.directory
                writer.writerow(output)

    lines = [
        "KeyTypeBench-20260603 model comparison",
        f"Suites included: {', '.join(suites)}.",
        "Quality is a non-negative utility score; wrong visible suggestions are tracked by wrong-show rate.",
        "Policy has no positive insertion rows; use it for suppression accuracy and wrong-show behavior, not precision/coverage.",
        "",
    ]
    for model in models:
        lines.append(model.label)
        wrote_any = False
        for suite in suites:
            row = row_by.get((model.identifier, suite))
            if row is None:
                continue
            wrote_any = True
            lines.append(
                f"  {SUITE_LABELS.get(suite, suite.title())}: "
                f"quality={float(row['qualityScore']):.3f}, "
                f"precision={float(row['precisionWhenShown']):.1%}, "
                f"coverage={float(row['positiveCoverage']):.1%}, "
                f"wrongShow={float(row['wrongShowRate']):.1%}, "
                f"p50={float(row['p50TotalMs']):.1f}ms, "
                f"p95={float(row['p95TotalMs']):.1f}ms, "
                f"rows={int(row['rowCount'])}"
            )
        if wrote_any:
            lines.append("")

    (output_dir / "keytype_model_comparison_summary.txt").write_text(
        "\n".join(lines).rstrip() + "\n"
    )


def remove_stale_outputs(output_dir: Path) -> None:
    for pattern in ("*.png", "keytype_model_comparison_summary.*"):
        for path in output_dir.glob(pattern):
            path.unlink()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Regenerate KeyTypeBench comparison graphs from result aggregates."
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=default_results_dir(),
        help="Directory containing per-model result folders.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Directory for generated charts. Defaults to <results-dir>/keytype-model-comparison.",
    )
    parser.add_argument(
        "--suites",
        nargs="+",
        default=list(DEFAULT_SUITES),
        choices=sorted(SUITE_DIRS),
        help="Suites to include in summary and suite-level graphs.",
    )
    parser.add_argument(
        "--positive-suites",
        nargs="+",
        default=list(DEFAULT_POSITIVE_SUITES),
        choices=sorted(SUITE_DIRS),
        help="Suites to include in positive insert precision/coverage and latency graphs.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    results_dir = args.results_dir.resolve()
    output_dir = (args.output_dir or results_dir / "keytype-model-comparison").resolve()
    suites = tuple(args.suites)
    positive_suites = tuple(args.positive_suites)

    models, row_by = collect_rows(results_dir, suites)
    models = present_models(models, row_by, suites)
    if not models:
        raise SystemExit(f"No aggregate results found under {results_dir}")

    output_dir.mkdir(parents=True, exist_ok=True)
    remove_stale_outputs(output_dir)
    configure_plots()
    colors = color_map(models)

    grouped_bars(
        output_dir,
        "quality_score_by_suite.png",
        "Utility-Oriented Quality Score by Suite",
        "Score",
        models,
        row_by,
        suites,
        "qualityScore",
        colors,
        ylim=(0, 1.05),
    )
    grouped_two_metric(
        output_dir,
        "precision_and_coverage.png",
        "Positive Insert Precision and Coverage",
        models,
        row_by,
        positive_suites,
        (
            ("precisionWhenShown", "Precision When Shown"),
            ("positiveCoverage", "Positive Coverage"),
        ),
        colors,
    )
    grouped_bars(
        output_dir,
        "wrong_show_rate_by_suite.png",
        "Wrong Show Rate by Suite",
        "Wrong show rate",
        models,
        row_by,
        suites,
        "wrongShowRate",
        colors,
        percent=True,
        ylim=(0, 100),
    )

    latency_percentile_panels(
        output_dir,
        "p95_latency_by_suite.png",
        models,
        row_by,
        positive_suites,
        colors,
    )

    if "core" in suites:
        outcome_mix(output_dir, "outcome_mix_core.png", "core", models, row_by)
        tag_quality(
            output_dir,
            "tag_quality_core.png",
            "core",
            (
                "prose-append",
                "email",
                "messaging-chat",
                "browser-web-form",
                "code-comments",
                "ai-chat",
                "mid-word",
                "duplication-trap",
            ),
            models,
            row_by,
            colors,
        )
    if "edge" in suites:
        outcome_mix(output_dir, "outcome_mix_edge.png", "edge", models, row_by)
        tag_quality(
            output_dir,
            "tag_quality_edge.png",
            "edge",
            (
                "mid-word",
                "fim",
                "duplication-trap",
                "code-comments",
                "abbreviation",
                "numbered-list",
                "app-specific",
                "policy",
            ),
            models,
            row_by,
            colors,
        )

    write_summary(output_dir, models, row_by, suites)
    print(f"Wrote comparison graphs to {output_dir}")


if __name__ == "__main__":
    main()
