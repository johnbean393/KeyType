#!/usr/bin/env python3
"""Generate KeyType's committed public benchmark datasets.

The generator intentionally keeps source-document chunks separate from compiled
cases so provenance, split assignment, and case mix remain auditable.
"""

from __future__ import annotations

import csv
import hashlib
import json
import re
import textwrap
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


csv.field_size_limit(10_000_000)

ROOT = Path(__file__).resolve().parents[2]
BENCHMARKS = ROOT / "KeyTypeBench-20260603"
DATASETS = BENCHMARKS / "Datasets"
SOURCES = BENCHMARKS / "Sources"

USER_AGENT = "KeyType benchmark dataset generator/1.0"


@dataclass(frozen=True)
class SourceSpec:
    group: str
    bucket: str
    kind: str
    title: str
    license: str
    url: str | None = None
    path: str | None = None
    tags: tuple[str, ...] = ()
    max_docs: int = 24
    source_note: str | None = None
    processor: str = "plain"


TLDR_PAGES = [
    "git-commit",
    "git-rebase",
    "git-log",
    "grep",
    "rg",
    "curl",
    "tar",
    "rsync",
    "ssh",
    "scp",
    "docker",
    "docker-compose",
    "kubectl",
    "jq",
    "sed",
    "awk",
    "find",
    "xargs",
    "make",
    "npm",
    "pnpm",
    "swift",
    "ffmpeg",
]

TLDR_SOURCES = [
    SourceSpec(
        group=f"tldr-{page}",
        bucket="terminal",
        kind="cli-doc",
        title=f"tldr {page}",
        url=f"https://raw.githubusercontent.com/tldr-pages/tldr/main/pages/common/{page}.md",
        license="CC BY 4.0; tldr-pages contributors",
        tags=("terminal", "cli", "documentation"),
        max_docs=2,
        processor="markdown",
    )
    for page in TLDR_PAGES
]

TLDR_SOURCES.append(
    SourceSpec(
        group="tldr-xcodebuild",
        bucket="terminal",
        kind="cli-doc",
        title="tldr xcodebuild",
        url="https://raw.githubusercontent.com/tldr-pages/tldr/main/pages/osx/xcodebuild.md",
        license="CC BY 4.0; tldr-pages contributors",
        tags=("terminal", "cli", "documentation", "xcode"),
        max_docs=2,
        processor="markdown",
    )
)

HF_WIKIPEDIA_DATASET = "singletongue/wikipedia-paragraphs"
HF_WIKIPEDIA_CONFIG = "enwiki-20260301-v1.2.0"
HF_WIKIPEDIA_SPLIT = "train"
HF_WIKIPEDIA_BANDS = {
    "notes-docs": [92_000, 148_000, 211_000, 305_000, 428_000, 612_000, 880_000, 1_240_000],
    "browser-web-form": [73_000, 166_000, 255_000, 377_000, 540_000, 735_000, 990_000, 1_420_000],
    "email": [58_000, 132_000, 219_000, 344_000, 501_000, 705_000],
    "messaging-chat": [64_000, 155_000, 238_000, 390_000, 575_000, 820_000],
}


def hf_wikipedia_source(bucket: str, offset: int) -> SourceSpec:
    return SourceSpec(
        group=f"hf-wikipedia-{bucket}-enwiki-20260301-{offset:07d}",
        bucket=bucket,
        kind="wikipedia-paragraphs",
        title=f"English Wikipedia paragraphs for {bucket} surface at offset {offset}",
        url="https://datasets-server.huggingface.co/rows?"
        + urllib.parse.urlencode(
            {
                "dataset": HF_WIKIPEDIA_DATASET,
                "config": HF_WIKIPEDIA_CONFIG,
                "split": HF_WIKIPEDIA_SPLIT,
                "offset": offset,
                "length": 100,
            }
        ),
        license="CC BY-SA 4.0 and GFDL; Wikipedia contributors via singletongue/wikipedia-paragraphs",
        tags=(bucket, "wikipedia", "encyclopedic", "cc-by-sa", "hf-dataset"),
        max_docs=28,
        source_note=(
            "Rows fetched through the Hugging Face Dataset Viewer API. "
            "The generator prefers lower-inlink pages to reduce memorization risk."
        ),
        processor="hf-wikipedia-paragraphs",
    )


HF_WIKIPEDIA_SOURCES = [
    hf_wikipedia_source(bucket, offset)
    for bucket, offsets in HF_WIKIPEDIA_BANDS.items()
    for offset in offsets
]

AI_PROMPT_SOURCE = SourceSpec(
    group="awesome-chatgpt-prompts",
    bucket="ai-chat",
    kind="prompt-list",
    title="awesome-chatgpt-prompts prompts.csv",
    url="https://raw.githubusercontent.com/f/awesome-chatgpt-prompts/main/prompts.csv",
    license="CC0 1.0; prompt content from awesome-chatgpt-prompts",
    tags=("ai-chat", "prompt", "public-domain-dedication"),
    max_docs=70,
    processor="prompts-csv",
)

OPENAI_COOKBOOK_SOURCE = SourceSpec(
    group="openai-cookbook-readme",
    bucket="ai-chat",
    kind="documentation",
    title="OpenAI Cookbook README",
    url="https://raw.githubusercontent.com/openai/openai-cookbook/main/README.md",
    license="MIT; OpenAI Cookbook contributors",
    tags=("ai-chat", "documentation", "prompting"),
    max_docs=8,
    processor="markdown",
)

KEYTYPE_DOCS = [
    "docs/00-overview.md",
    "docs/01-architecture.md",
    "docs/02-prompting.md",
    "docs/06-quality-playbook.md",
    "docs/07-performance.md",
    "docs/08-app-compatibility.md",
]

KEYTYPE_SOURCES = [
    SourceSpec(
        group="keytype-" + Path(path).stem,
        bucket="notes-docs",
        kind="project-doc",
        title=path,
        path=path,
        license="MIT; KeyType repository",
        tags=("notes", "documentation", "local"),
        max_docs=16,
        processor="markdown",
    )
    for path in KEYTYPE_DOCS
]

SWIFT_ARGUMENT_PARSER_FILES = [
    "Sources/ArgumentParser/Parsable Types/ParsableCommand.swift",
    "Sources/ArgumentParser/Parsable Types/CommandConfiguration.swift",
    "Sources/ArgumentParser/Parsing/ArgumentDecoder.swift",
    "Sources/ArgumentParser/Parsing/CommandParser.swift",
    "Sources/ArgumentParser/Usage/HelpGenerator.swift",
    "Sources/ArgumentParser/Completions/ZshCompletionsGenerator.swift",
]

SWIFT_ARGUMENT_SOURCES = [
    SourceSpec(
        group="swift-argument-parser-" + re.sub(r"[^a-z0-9]+", "-", Path(path).stem.lower()).strip("-"),
        bucket="code-comments",
        kind="source-code",
        title="Swift Argument Parser " + Path(path).name,
        url="https://raw.githubusercontent.com/apple/swift-argument-parser/main/"
        + urllib.parse.quote(path, safe="/"),
        license="Apache-2.0; Swift Argument Parser contributors",
        tags=("swift", "code", "comments", "open-source"),
        max_docs=18,
        processor="code",
    )
    for path in SWIFT_ARGUMENT_PARSER_FILES
]

KEYTYPE_CODE_FILES = [
    "Packages/KeyTypeBench/Sources/KeyTypeBench/CaseSchema.swift",
    "Packages/KeyTypeBench/Sources/KeyTypeBench/EvaluationPipeline.swift",
    "Packages/ConstrainedGeneration/Sources/ConstrainedGeneration/Filtering/CandidateFilter.swift",
    "Packages/AppCompatibility/Sources/AppCompatibility/DefaultOverrides.swift",
]

KEYTYPE_CODE_SOURCES = [
    SourceSpec(
        group="keytype-code-" + Path(path).stem.lower(),
        bucket="code-comments",
        kind="source-code",
        title=path,
        path=path,
        license="MIT; KeyType repository",
        tags=("swift", "code", "comments", "local"),
        max_docs=14,
        processor="code",
    )
    for path in KEYTYPE_CODE_FILES
]

SOURCE_SPECS = (
    TLDR_SOURCES
    + HF_WIKIPEDIA_SOURCES
    + [AI_PROMPT_SOURCE, OPENAI_COOKBOOK_SOURCE]
    + KEYTYPE_SOURCES
    + SWIFT_ARGUMENT_SOURCES
    + KEYTYPE_CODE_SOURCES
)


TARGETS = {
    "notes-docs": [
        {"bundleIdentifier": "com.apple.TextEdit", "appName": "TextEdit", "windowTitle": "Draft.txt"},
        {"bundleIdentifier": "md.obsidian", "appName": "Obsidian", "windowTitle": "Daily note"},
        {"bundleIdentifier": "notion.id", "appName": "Notion", "windowTitle": "Project notes", "domain": "notion.so"},
    ],
    "email": [
        {"bundleIdentifier": "com.apple.mail", "appName": "Mail", "windowTitle": "Draft"},
        {
            "bundleIdentifier": "com.google.Chrome",
            "appName": "Google Chrome",
            "windowTitle": "Compose",
            "domain": "mail.google.com",
        },
    ],
    "messaging-chat": [
        {"bundleIdentifier": "com.apple.MobileSMS", "appName": "Messages", "windowTitle": "Conversation"},
        {
            "bundleIdentifier": "com.tinyspeck.slackmacgap",
            "appName": "Slack",
            "windowTitle": "project-team",
            "domain": "slack.com",
        },
        {"bundleIdentifier": "com.hnc.Discord", "appName": "Discord", "windowTitle": "general", "domain": "discord.com"},
    ],
    "browser-web-form": [
        {
            "bundleIdentifier": "com.google.Chrome",
            "appName": "Google Chrome",
            "windowTitle": "Comment",
            "domain": "en.wikipedia.org",
        },
        {"bundleIdentifier": "com.apple.Safari", "appName": "Safari", "windowTitle": "Feedback", "domain": "example.com"},
    ],
    "code-comments": [
        {"bundleIdentifier": "com.apple.dt.Xcode", "appName": "Xcode", "windowTitle": "Source.swift"},
        {"bundleIdentifier": "com.microsoft.VSCode", "appName": "Visual Studio Code", "windowTitle": "Source.swift"},
    ],
    "terminal": [
        {"bundleIdentifier": "com.apple.TextEdit", "appName": "TextEdit", "windowTitle": "Shell notes"},
        {"bundleIdentifier": "com.microsoft.VSCode", "appName": "Visual Studio Code", "windowTitle": "README.md"},
    ],
    "ai-chat": [
        {"bundleIdentifier": "com.openai.chat", "appName": "ChatGPT", "windowTitle": "Prompt draft"},
        {
            "bundleIdentifier": "com.google.Chrome",
            "appName": "Google Chrome",
            "windowTitle": "Chat prompt",
            "domain": "chat.openai.com",
        },
    ],
}

TYPE_TAGS = {
    "append": ("append", "prose-append"),
    "email": ("email",),
    "messaging": ("messaging", "chat"),
    "browser": ("browser", "web-form", "comment"),
    "code": ("code", "comment"),
    "midword": ("mid-word", "edge"),
    "fim": ("fim", "mid-line", "edge"),
    "duplication": ("duplication-trap", "after-cursor", "edge"),
    "abbrev-list": ("abbreviation", "numbered-list", "edge"),
    "app-trap": ("app-specific", "policy", "edge", "suppress"),
}

MANIFEST_CASE_TYPES = {
    "append": "end-of-line-append",
    "email": "email",
    "messaging": "messaging-chat",
    "browser": "browser-web-form",
    "code": "code-identifiers-comments",
    "midword": "mid-word-completion",
    "fim": "fill-in-middle",
    "duplication": "duplication-trap",
    "abbrev-list": "end-of-line-append",
    "app-trap": "app-policy-suppression",
}


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last_error: Exception | None = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
            break
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code < 500 and error.code != 429:
                raise
        except (urllib.error.URLError, TimeoutError) as error:
            last_error = error

        if attempt == 3:
            assert last_error is not None
            raise last_error
        time.sleep(1.5 * (attempt + 1))
    for encoding in ("utf-8-sig", "utf-8", "latin-1"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def read_source_text(spec: SourceSpec) -> str:
    try:
        if spec.path:
            return (ROOT / spec.path).read_text(encoding="utf-8")
        assert spec.url is not None
        return fetch(spec.url)
    except Exception as error:
        location = spec.path or spec.url or "<missing location>"
        raise RuntimeError(f"Failed to read source {spec.group} from {location}") from error


def clean_text(spec: SourceSpec, text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if spec.processor == "hf-wikipedia-paragraphs":
        text = hf_wikipedia_rows_to_text(text)
    elif spec.processor == "prompts-csv":
        text = prompts_csv_to_text(text)
    elif spec.processor == "markdown":
        text = clean_markdown(text)
    elif spec.processor == "code":
        text = clean_code(text)
    else:
        text = normalize_spacing(text)
    return text.strip()


def clean_markdown(text: str) -> str:
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"!\[[^\]]*\]\([^)]+\)", " ", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"(?m)^#{1,6}\s*", "", text)
    text = re.sub(r"(?m)^\s*[-*]\s+", "", text)
    return normalize_spacing(text)


def clean_code(text: str) -> str:
    text = re.sub(r"(?m)^\s*// MARK:.*$", " ", text)
    text = re.sub(r"(?m)^\s*import\s+.*$", " ", text)
    text = re.sub(r"(?m)^\s*#if.*$|^\s*#endif.*$", " ", text)
    return normalize_spacing(text, keep_line_structure=True)


def prompts_csv_to_text(text: str) -> str:
    rows = []
    reader = csv.DictReader(text.splitlines())
    for row in reader:
        prompt = (row.get("prompt") or "").strip()
        act = (row.get("act") or "").strip()
        if len(prompt) >= 120:
            rows.append(f"{act}: {prompt}")
    return "\n\n".join(rows)


def hf_wikipedia_rows_to_text(text: str) -> str:
    data = json.loads(text)
    paragraphs = []
    for wrapped in data.get("rows", []):
        row = wrapped.get("row", {})
        title = (row.get("title") or "Wikipedia").strip()
        if not should_use_wikipedia_row(row, title):
            continue
        for paragraph in row.get("paragraph_texts") or []:
            paragraph = normalize_spacing(str(paragraph))
            if usable_paragraph(paragraph):
                paragraphs.append(f"{title}: {paragraph}")
    return "\n\n".join(paragraphs)


def should_use_wikipedia_row(row: dict, title: str) -> bool:
    if row.get("page_type") != "article":
        return False
    if int(row.get("num_inlinks") or 0) > 250:
        return False
    lowered = title.lower()
    blocked_fragments = [
        "anarchism",
        "australia",
        "beatles",
        "christianity",
        "france",
        "george washington",
        "harry potter",
        "japan",
        "jesus",
        "london",
        "new york",
        "python",
        "romeo",
        "shakespeare",
        "star wars",
        "united states",
        "world war",
    ]
    return not any(fragment in lowered for fragment in blocked_fragments)


def normalize_spacing(text: str, keep_line_structure: bool = False) -> str:
    text = text.replace("\u00a0", " ")
    if keep_line_structure:
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text
    paragraphs = []
    for paragraph in re.split(r"\n\s*\n+", text):
        paragraph = re.sub(r"\s+", " ", paragraph).strip()
        if paragraph:
            paragraphs.append(paragraph)
    return "\n\n".join(paragraphs)


def chunk_text(text: str, max_docs: int, code: bool = False) -> list[str]:
    if code:
        return chunk_code(text, max_docs=max_docs)
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n+", text) if usable_paragraph(p)]
    chunks: list[str] = []
    current: list[str] = []
    current_len = 0
    for paragraph in paragraphs:
        paragraph = re.sub(r"\s+", " ", paragraph)
        if len(paragraph) > 980:
            for sentence_chunk in sentence_chunks(paragraph, limit=820):
                chunks.append(sentence_chunk)
                if len(chunks) >= max_docs:
                    return chunks
            continue
        if current_len + len(paragraph) + 2 > 820 and current:
            chunks.append(" ".join(current).strip())
            current = []
            current_len = 0
            if len(chunks) >= max_docs:
                return chunks
        current.append(paragraph)
        current_len += len(paragraph) + 1
        if current_len >= 360:
            chunks.append(" ".join(current).strip())
            current = []
            current_len = 0
            if len(chunks) >= max_docs:
                return chunks
    if current and len(chunks) < max_docs:
        chunks.append(" ".join(current).strip())
    return [c for c in chunks if 100 <= len(c) <= 1100][:max_docs]


def chunk_code(text: str, max_docs: int) -> list[str]:
    lines = [line.rstrip() for line in text.splitlines()]
    blocks: list[str] = []
    current: list[str] = []
    for line in lines:
        if not line.strip():
            if current:
                block = "\n".join(current).strip()
                if len(block) >= 180:
                    blocks.append(block)
                current = []
            continue
        if len(line) > 160:
            continue
        current.append(line)
        if len("\n".join(current)) >= 620:
            blocks.append("\n".join(current).strip())
            current = []
            if len(blocks) >= max_docs:
                return blocks
    if current:
        blocks.append("\n".join(current).strip())
    return [b for b in blocks if 160 <= len(b) <= 1400][:max_docs]


def usable_paragraph(paragraph: str) -> bool:
    p = re.sub(r"\s+", " ", paragraph).strip()
    if len(p) < 80:
        return False
    lower = p.lower()
    blocked = [
        "terms of use",
        "unsubscribe",
        "all rights reserved",
        "copyright",
    ]
    if any(term in lower for term in blocked):
        return False
    if len(re.findall(r"[A-Za-z]", p)) < 50:
        return False
    return True


def sentence_chunks(paragraph: str, limit: int) -> Iterable[str]:
    sentences = re.split(r"(?<=[.!?])\s+", paragraph)
    current: list[str] = []
    current_len = 0
    for sentence in sentences:
        if current_len + len(sentence) > limit and current:
            yield " ".join(current).strip()
            current = []
            current_len = 0
        current.append(sentence)
        current_len += len(sentence) + 1
    if current:
        yield " ".join(current).strip()


def group_split(source_group: str) -> str:
    digest = int(hashlib.sha256(source_group.encode("utf-8")).hexdigest()[:8], 16) % 100
    if digest < 23:
        return "dev"
    if digest < 34:
        return "holdout"
    return "eval"


def case_types_for_bucket(bucket: str) -> list[str]:
    mapping = {
        "email": ["email", "append", "midword", "fim", "duplication"],
        "messaging-chat": ["messaging", "append", "midword", "fim", "duplication"],
        "browser-web-form": ["browser", "append", "midword", "fim", "duplication"],
        "code-comments": ["code", "midword", "fim", "duplication"],
        "terminal": ["append", "midword", "app-trap"],
        "ai-chat": ["append", "browser", "midword", "fim"],
        "notes-docs": ["append", "midword", "fim", "duplication"],
    }
    return mapping.get(bucket, ["append", "midword"])


def build_source_documents() -> list[dict]:
    documents: list[dict] = []
    for spec in SOURCE_SPECS:
        print(f"Fetching {spec.group}...", flush=True)
        raw = read_source_text(spec)
        cleaned = clean_text(spec, raw)
        chunks = chunk_text(cleaned, max_docs=spec.max_docs, code=spec.processor == "code")
        if not chunks:
            raise RuntimeError(f"No usable chunks produced for {spec.group}")
        for index, chunk in enumerate(chunks, start=1):
            documents.append(
                {
                    "id": f"{spec.group}-{index:03d}",
                    "sourceGroup": spec.group,
                    "split": group_split(spec.group),
                    "text": chunk,
                    "source": {
                        "kind": spec.kind,
                        "title": spec.title,
                        **({"url": spec.url} if spec.url else {}),
                        **({"path": spec.path} if spec.path else {}),
                        "license": spec.license,
                        **({"note": spec.source_note} if spec.source_note else {}),
                    },
                    "tags": sorted(set((spec.bucket, "real", *spec.tags))),
                    "suites": ["core", "edge", "latency"],
                    "contextSources": {
                        "fieldText": "real",
                        "appContext": "synthetic",
                        "screenContext": "none",
                        "clipboard": "none",
                        "labels": "synthetic",
                    },
                    "target": target_for_bucket(spec.bucket, index),
                    "detectedLanguage": "en",
                    "typingContext": typing_context_for_bucket(spec.bucket),
                    "placeholder": placeholder_for_bucket(spec.bucket),
                    "labels": labels_for_bucket(spec.bucket),
                    "caseTypes": [MANIFEST_CASE_TYPES[name] for name in case_types_for_bucket(spec.bucket)],
                }
            )
    documents.sort(key=lambda row: (row["sourceGroup"], row["id"]))
    return documents


def target_for_bucket(bucket: str, index: int) -> dict:
    targets = TARGETS.get(bucket, TARGETS["notes-docs"])
    return dict(targets[(index - 1) % len(targets)])


def typing_context_for_bucket(bucket: str) -> str:
    return {
        "email": "email",
        "messaging-chat": "message",
        "browser-web-form": "browser-form",
        "code-comments": "code",
        "terminal": "terminal-doc",
        "ai-chat": "prompt",
        "notes-docs": "document",
    }.get(bucket, "document")


def placeholder_for_bucket(bucket: str) -> str | None:
    return {
        "email": "Write your message",
        "messaging-chat": "Message",
        "browser-web-form": "Leave a comment",
        "ai-chat": "Send a message",
    }.get(bucket)


def labels_for_bucket(bucket: str) -> list[str]:
    return {
        "email": ["Body"],
        "messaging-chat": ["Message"],
        "browser-web-form": ["Comment"],
        "ai-chat": ["Prompt"],
        "code-comments": ["Editor"],
    }.get(bucket, [])


WORD_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_'-]{3,}")


def word_boundaries(text: str) -> list[int]:
    boundaries = []
    for match in re.finditer(r"(?<=[\s({\[])[A-Za-z0-9_]", " " + text):
        pos = match.start() - 1
        if 30 <= pos <= len(text) - 24:
            boundaries.append(pos)
    return boundaries


def following_text(text: str, start: int, max_chars: int = 32) -> str | None:
    start = skip_leading_spaces(text, start)
    if start >= len(text):
        return None
    end = start
    last_good = start
    while end < len(text) and end - start < max_chars:
        ch = text[end]
        end += 1
        if ch in ".!?\n":
            last_good = end
            break
        if ch.isspace() or ch in ",;:)":
            last_good = end
    if last_good == start:
        last_good = end
    target = text[start:last_good]
    target = target.replace("\n", " ")
    if not re.search(r"[A-Za-z0-9]", target):
        return None
    return target


def skip_leading_spaces(text: str, index: int) -> int:
    while index < len(text) and text[index] in " \t\n":
        index += 1
    return index


def pick_boundary(text: str, variant: int) -> int | None:
    boundaries = word_boundaries(text)
    if not boundaries:
        return None
    return boundaries[(variant * 17 + 3) % len(boundaries)]


def append_slice(text: str, variant: int, max_chars: int = 32) -> tuple[str, str, str] | None:
    cursor = pick_boundary(text, variant)
    if cursor is None:
        return None
    cursor = skip_leading_spaces(text, cursor)
    target = following_text(text, cursor, max_chars=max_chars)
    if not target:
        return None
    return text[:cursor], target, ""


def midword_slice(text: str, variant: int, max_chars: int = 18) -> tuple[str, str, str] | None:
    words = [m for m in WORD_RE.finditer(text) if len(m.group(0)) >= 7]
    words = [w for w in words if 24 <= w.start() <= len(text) - 24]
    if not words:
        return None
    word = words[(variant * 19 + 5) % len(words)]
    split = min(max(3, len(word.group(0)) // 2), 5)
    cursor = word.start() + split
    target = text[cursor : min(word.end(), cursor + max_chars)]
    if not target or not re.search(r"[A-Za-z0-9]", target):
        return None
    return text[:cursor], target, ""


def fim_slice(text: str, variant: int) -> tuple[str, str, str] | None:
    base = append_slice(text, variant, max_chars=26)
    if base is None:
        return None
    before, target, _ = base
    start = len(before)
    target_end = start + len(target)
    after = text[target_end : target_end + 90].strip()
    if len(after) < 20:
        return None
    return before, target, after


def duplication_slice(text: str, variant: int) -> tuple[str, str, str] | None:
    base = append_slice(text, variant, max_chars=24)
    if base is None:
        return None
    before, target, _ = base
    start = len(before)
    after = text[start : start + max(80, len(target) + 40)].strip()
    if not after.startswith(target.strip()) or len(after) < len(target) + 15:
        return None
    return before, target.strip(), after


def abbrev_list_slice(doc: dict, variant: int) -> tuple[str, str, str] | None:
    prefix = [
        "Next steps:\n1. Review the source manifest.\n2. Verify each split by source group.\n3. ",
        "Checklist:\n- Confirm provenance metadata.\n- Run validation.\n- ",
        "Release notes:\n1. Benchmark data is public and permissive.\n2. Private calibration remains local.\n3. ",
    ][variant % 3]
    text = doc["text"]
    target = following_text(text, skip_leading_spaces(text, 0), max_chars=30)
    if not target:
        return None
    return prefix, target, ""


def make_context(doc: dict, before: str, after: str, case_type: str, variant: int) -> dict:
    bucket = bucket_from_doc(doc)
    target = target_for_case(bucket, case_type, variant, doc.get("target") or {})
    context = {
        "beforeCursor": before,
        "afterCursor": after,
        "target": target,
        "detectedLanguage": doc.get("detectedLanguage", "en"),
        "typingContext": typing_context_for_case(bucket, case_type),
        "placeholder": doc.get("placeholder"),
        "labels": doc.get("labels", []),
        "traits": {
            "isSecureTextEntry": False,
            "isPasswordField": False,
            "isPasswordManagerContext": False,
            "isWebField": target.get("domain") is not None or case_type == "browser",
            "isTerminalLike": False,
        },
        "screenContext": screen_context_for_case(case_type, variant),
        "clipboardContext": None,
        "previousUserInputs": previous_inputs_for_case(case_type, bucket),
    }
    if case_type == "code":
        context["placeholder"] = None
        context["labels"] = ["Editor"]
    if case_type == "messaging":
        context["screenContext"] = "Thread preview: last reply mentioned the same topic."
    if case_type == "browser":
        context["screenContext"] = "Visible page text includes navigation, sidebar labels, and a comment editor."
    return {k: v for k, v in context.items() if v is not None}


def target_for_case(bucket: str, case_type: str, variant: int, default_target: dict) -> dict:
    if case_type == "email":
        return TARGETS["email"][variant % len(TARGETS["email"])]
    if case_type == "messaging":
        return TARGETS["messaging-chat"][variant % len(TARGETS["messaging-chat"])]
    if case_type == "browser":
        return TARGETS["browser-web-form"][variant % len(TARGETS["browser-web-form"])]
    if case_type == "code":
        return TARGETS["code-comments"][variant % len(TARGETS["code-comments"])]
    if case_type == "app-trap":
        return {
            "bundleIdentifier": "com.apple.Terminal",
            "appName": "Terminal",
            "windowTitle": "zsh",
        }
    return default_target or target_for_bucket(bucket, variant + 1)


def typing_context_for_case(bucket: str, case_type: str) -> str:
    if case_type == "email":
        return "email"
    if case_type == "messaging":
        return "message"
    if case_type == "browser":
        return "browser-form"
    if case_type == "code":
        return "code"
    if case_type == "app-trap":
        return "terminal"
    return typing_context_for_bucket(bucket)


def screen_context_for_case(case_type: str, variant: int) -> str | None:
    if case_type in {"browser", "email", "messaging"}:
        return [
            "Nearby UI: Reply, Forward, Comment, Attach, Send",
            "Nearby UI: Search, Sidebar, Notifications, Thread",
            "Nearby UI: Formatting toolbar and document comments",
        ][variant % 3]
    return None


def previous_inputs_for_case(case_type: str, bucket: str) -> list[str]:
    if case_type == "email":
        return ["Thanks for the update.", "I will take another look later today."]
    if case_type == "messaging":
        return ["got it", "will check after the meeting"]
    if bucket == "ai-chat":
        return ["Please keep the answer concise.", "Use examples only when necessary."]
    return []


def bucket_from_doc(doc: dict) -> str:
    for tag in doc.get("tags", []):
        if tag in {
            "email",
            "messaging-chat",
            "browser-web-form",
            "code-comments",
            "terminal",
            "ai-chat",
            "notes-docs",
        }:
            return tag
    return "notes-docs"


def case_context_sources(doc: dict, case_type: str) -> dict:
    sources = dict(doc["contextSources"])
    if case_type in {"browser", "email", "messaging"}:
        sources["screenContext"] = "synthetic"
    return sources


def make_case(doc: dict, suite: str, case_type: str, ordinal: int, suppress: bool = False) -> dict | None:
    text = doc["text"]
    if case_type in {"append", "email", "messaging", "browser", "code"}:
        sliced = append_slice(text, ordinal, max_chars=30 if case_type != "code" else 24)
    elif case_type == "midword":
        sliced = midword_slice(text, ordinal)
    elif case_type == "fim":
        sliced = fim_slice(text, ordinal)
    elif case_type == "duplication":
        sliced = duplication_slice(text, ordinal)
        suppress = True
    elif case_type == "abbrev-list":
        sliced = abbrev_list_slice(doc, ordinal)
    elif case_type == "app-trap":
        sliced = append_slice(text, ordinal, max_chars=24)
        suppress = True
    else:
        raise ValueError(case_type)
    if sliced is None:
        return None

    before, target, after = sliced
    tags = sorted(set(doc["tags"] + list(TYPE_TAGS[case_type]) + [suite]))
    expected = (
        {"kind": "suppress", "allowedReasons": allowed_reasons_for_suppress(case_type)}
        if suppress
        else {
            "kind": "insert",
            "modelTarget": target,
            "shownAcceptable": sorted(set([target.strip()] if target.strip() else [])),
            "allowedReasons": [],
        }
    )
    case = {
        "id": f"{suite}-{case_type}-{doc['id']}-{ordinal:03d}",
        "split": doc["split"],
        "sourceGroup": doc["sourceGroup"],
        "suites": [suite],
        "tags": tags,
        "contextSources": case_context_sources(doc, case_type),
        "source": doc["source"],
        "context": make_context(doc, before, after, case_type, ordinal),
        "expected": expected,
        "limits": limits_for_case(suite, case_type, len(before)),
    }
    if suppress and case_type == "app-trap":
        case["context"]["traits"]["isTerminalLike"] = True
    return case


def allowed_reasons_for_suppress(case_type: str) -> list[str]:
    if case_type == "duplication":
        return ["duplicatesAfterCursor"]
    if case_type == "app-trap":
        return ["tabShortcutsDisabled"]
    return []


def limits_for_case(suite: str, case_type: str, before_len: int) -> dict:
    if suite == "latency":
        return {"maxCompletionTokens": 4, "maxDisplayWidth": 80}
    if case_type == "midword":
        return {"maxCompletionTokens": 3, "maxDisplayWidth": 40}
    if case_type == "fim":
        return {"maxCompletionTokens": 5, "maxDisplayWidth": 80}
    return {"maxCompletionTokens": 4, "maxDisplayWidth": 80}


def choose_docs(documents: list[dict], buckets: set[str] | None = None) -> list[dict]:
    if buckets is None:
        return documents
    filtered = [doc for doc in documents if bucket_from_doc(doc) in buckets]
    if not filtered:
        raise RuntimeError(f"No source documents for buckets: {sorted(buckets)}")
    return filtered


def build_cases_for_mix(documents: list[dict], suite: str, mix: list[tuple[str, int, set[str] | None]]) -> list[dict]:
    cases: list[dict] = []
    seen: set[str] = set()
    for case_type, target_count, buckets in mix:
        pool = choose_docs(documents, buckets)
        produced_for_type = 0
        for split, split_count in split_target_counts(target_count):
            split_pool = [doc for doc in pool if doc["split"] == split]
            if not split_pool:
                split_pool = pool
            produced_for_type += append_cases(
                cases=cases,
                seen=seen,
                pool=split_pool,
                suite=suite,
                case_type=case_type,
                desired_count=split_count,
                ordinal_seed=produced_for_type + 1,
            )
        if produced_for_type < target_count:
            raise RuntimeError(f"Could only produce {produced_for_type}/{target_count} {case_type} cases for {suite}")
    cases.sort(key=lambda row: row["id"])
    return cases


def split_target_counts(total: int) -> list[tuple[str, int]]:
    dev = max(1, round(total * 0.15)) if total >= 10 else 0
    holdout = max(1, round(total * 0.15)) if total >= 10 else 0
    eval_count = total - dev - holdout
    return [("dev", dev), ("eval", eval_count), ("holdout", holdout)]


def append_cases(
    cases: list[dict],
    seen: set[str],
    pool: list[dict],
    suite: str,
    case_type: str,
    desired_count: int,
    ordinal_seed: int,
) -> int:
    produced = 0
    attempts = 0
    while produced < desired_count and attempts < max(80, desired_count * 30):
        doc = pool[(attempts * 7 + produced * 3 + ordinal_seed) % len(pool)]
        ordinal = ordinal_seed + attempts
        case = make_case(doc, suite=suite, case_type=case_type, ordinal=ordinal)
        attempts += 1
        if case is None or case["id"] in seen:
            continue
        cases.append(case)
        seen.add(case["id"])
        produced += 1
    return produced


def build_core_cases(documents: list[dict]) -> list[dict]:
    return build_cases_for_mix(
        documents,
        "core",
        [
            ("append", 210, {"notes-docs", "ai-chat"}),
            ("email", 105, {"email"}),
            ("messaging", 105, {"messaging-chat"}),
            ("browser", 70, {"browser-web-form"}),
            ("code", 70, {"code-comments"}),
            ("midword", 70, None),
            ("fim", 35, None),
            ("duplication", 35, None),
        ],
    )


def build_edge_cases(documents: list[dict]) -> list[dict]:
    return build_cases_for_mix(
        documents,
        "edge",
        [
            ("midword", 75, None),
            ("fim", 75, None),
            ("duplication", 60, None),
            ("code", 30, {"code-comments"}),
            ("abbrev-list", 30, None),
            ("app-trap", 30, {"terminal"}),
        ],
    )


def build_latency_cases(documents: list[dict]) -> list[dict]:
    buckets_by_length = [
        ("short", 34, 80, 180),
        ("medium", 33, 280, 520),
        ("long", 33, 700, 1200),
    ]
    cases: list[dict] = []
    pool = [doc for doc in documents if bucket_from_doc(doc) not in {"terminal"}]
    ordinal = 0
    for label, count, min_len, max_len in buckets_by_length:
        produced = 0
        for split, split_count in split_target_counts(count):
            split_pool = [doc for doc in pool if doc["split"] == split]
            if not split_pool:
                split_pool = pool
            produced += append_latency_cases(
                cases=cases,
                pool=split_pool,
                label=label,
                min_len=min_len,
                max_len=max_len,
                desired_count=split_count,
                ordinal_seed=ordinal + produced + 1,
            )
        if produced < count:
            raise RuntimeError(f"Could only produce {produced}/{count} latency {label} cases")
        ordinal += count
    cases.sort(key=lambda row: row["id"])
    return cases


def append_latency_cases(
    cases: list[dict],
    pool: list[dict],
    label: str,
    min_len: int,
    max_len: int,
    desired_count: int,
    ordinal_seed: int,
) -> int:
    produced = 0
    attempts = 0
    while produced < desired_count and attempts < max(80, desired_count * 30):
        source = pool[(attempts * 5 + produced * 11 + ordinal_seed) % len(pool)]
        doc = dict(source)
        text = source["text"]
        if len(text) < min_len:
            attempts += 1
            continue
        trimmed = text[:max_len]
        cut = pick_boundary(trimmed, attempts + 1)
        if cut is None or cut < min_len:
            cut = min(len(trimmed) - 24, max(min_len, len(trimmed) // 2))
        doc["text"] = trimmed
        case = make_case(doc, suite="latency", case_type="append", ordinal=ordinal_seed + attempts)
        attempts += 1
        if case is None:
            continue
        existing_count = sum(1 for row in cases if row["id"].startswith(f"latency-{label}-"))
        case["id"] = f"latency-{label}-{existing_count + 1:03d}"
        case["tags"] = sorted(set(case["tags"] + [f"latency-{label}"]))
        before = case["context"]["beforeCursor"]
        if label == "short":
            case["context"]["beforeCursor"] = before[-180:]
        elif label == "medium":
            case["context"]["beforeCursor"] = before[-520:]
        else:
            case["context"]["beforeCursor"] = before[-1200:]
        cases.append(case)
        produced += 1
    return produced


def build_policy_cases() -> list[dict]:
    cases: list[dict] = []
    secure_apps = [
        ("com.1password.1password", "1Password"),
        ("com.apple.Passwords", "Passwords"),
        ("com.bitwarden.desktop", "Bitwarden"),
        ("com.dashlane.Dashlane", "Dashlane"),
        ("com.keepersecurity.passwordmanager", "Keeper"),
        ("com.lastpass.LastPass", "LastPass"),
    ]
    secure_domains = ["1password.com", "bitwarden.com", "dashlane.com", "lastpass.com", "keepersecurity.com"]
    terminals = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("org.alacritty", "Alacritty"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("com.github.wez.wezterm", "WezTerm"),
    ]
    midline_apps = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("org.alacritty", "Alacritty"),
    ]

    for index in range(24):
        bundle, name = secure_apps[index % len(secure_apps)]
        cases.append(
            policy_case(
                case_id=f"policy-secure-app-{index + 1:03d}",
                source_group="policy-secure-apps",
                before=["hunter", "correct horse", "api_key_", "otp-", "master pass", "vault secret"][index % 6],
                target={"bundleIdentifier": bundle, "appName": name, "windowTitle": "Unlock"},
                traits={"isSecureTextEntry": True, "isPasswordField": True, "isPasswordManagerContext": True},
                allowed=["secureFieldExcluded"],
                tags=["secure-field", "password-manager"],
            )
        )
    for index in range(16):
        domain = secure_domains[index % len(secure_domains)]
        cases.append(
            policy_case(
                case_id=f"policy-secure-domain-{index + 1:03d}",
                source_group="policy-secure-domains",
                before=["password", "account recovery", "secret note", "login token"][index % 4],
                target={
                    "bundleIdentifier": "com.google.Chrome",
                    "appName": "Google Chrome",
                    "windowTitle": "Sign in",
                    "domain": domain,
                },
                traits={"isSecureTextEntry": True, "isPasswordField": True, "isWebField": True},
                allowed=["secureFieldExcluded"],
                tags=["secure-field", "password-domain", "browser"],
            )
        )
    for index in range(20):
        bundle, name = terminals[index % len(terminals)]
        cases.append(
            policy_case(
                case_id=f"policy-terminal-tab-{index + 1:03d}",
                source_group="policy-terminal-tab",
                before=[
                    "git checkout fea",
                    "kubectl get po",
                    "ssh deploy@",
                    "docker compose up ",
                    "rg \"KeyType\" ",
                ][index % 5],
                target={"bundleIdentifier": bundle, "appName": name, "windowTitle": "zsh"},
                traits={"isTerminalLike": True},
                allowed=["tabShortcutsDisabled"],
                tags=["terminal", "tab-disabled"],
            )
        )
    for index in range(12):
        bundle, name = midline_apps[index % len(midline_apps)]
        cases.append(
            policy_case(
                case_id=f"policy-terminal-midline-{index + 1:03d}",
                source_group="policy-terminal-midline",
                before=["git commit --am", "npm run bu", "swift test --pack"][index % 3],
                after=["end", "ild", "age-path Packages/KeyTypeBench"][index % 3],
                target={"bundleIdentifier": bundle, "appName": name, "windowTitle": "zsh"},
                traits={"isTerminalLike": True},
                allowed=["midLineCompletionDisabled"],
                tags=["terminal", "mid-line"],
            )
        )
    if len(cases) != 72:
        raise AssertionError(len(cases))
    return cases


def policy_case(
    case_id: str,
    source_group: str,
    before: str,
    target: dict,
    traits: dict,
    allowed: list[str],
    tags: list[str],
    after: str = "",
) -> dict:
    default_traits = {
        "isSecureTextEntry": False,
        "isPasswordField": False,
        "isPasswordManagerContext": False,
        "isWebField": target.get("domain") is not None,
        "isTerminalLike": False,
    }
    default_traits.update(traits)
    return {
        "id": case_id,
        "split": group_split(source_group),
        "sourceGroup": source_group,
        "suites": ["policy"],
        "tags": sorted(set(["policy", "suppress", *tags])),
        "contextSources": {
            "fieldText": "synthetic",
            "appContext": "synthetic",
            "screenContext": "none",
            "clipboard": "none",
            "labels": "synthetic",
        },
        "source": {
            "kind": "policy-handcrafted",
            "title": source_group,
            "license": "Synthetic policy fixture; no user text",
        },
        "context": {
            "beforeCursor": before,
            "afterCursor": after,
            "target": target,
            "detectedLanguage": "en",
            "typingContext": "policy",
            "placeholder": None,
            "labels": ["Password" if default_traits["isPasswordField"] else "Input"],
            "traits": default_traits,
            "previousUserInputs": [],
        },
        "expected": {"kind": "suppress", "allowedReasons": allowed},
        "limits": {"maxCompletionTokens": 4, "maxDisplayWidth": 80},
    }


def build_smoke_cases(core: list[dict], edge: list[dict], policy: list[dict]) -> list[dict]:
    positive = core[:18] + [case for case in edge if case["expected"]["kind"] == "insert"][:6]
    negative = policy[:12]
    smoke = []
    for index, row in enumerate(positive + negative, start=1):
        copy = json.loads(json.dumps(row))
        copy["id"] = f"smoke-{index:03d}"
        copy["suites"] = ["smoke"]
        copy["tags"] = sorted(set(copy["tags"] + ["smoke"]))
        smoke.append(copy)
    if len(smoke) != 36:
        raise AssertionError(len(smoke))
    return smoke


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            handle.write("\n")


def write_summary(source_docs: list[dict], datasets: dict[str, list[dict]]) -> None:
    summary = {
        "sourceDocumentCount": len(source_docs),
        "sourceGroupCount": len({doc["sourceGroup"] for doc in source_docs}),
        "splits": count_values(doc["split"] for doc in source_docs),
        "sourceBuckets": count_values(bucket_from_doc(doc) for doc in source_docs),
        "datasets": {
            name: {
                "rowCount": len(rows),
                "splits": count_values(row["split"] for row in rows),
                "expectedKinds": count_values(row["expected"]["kind"] for row in rows),
                "caseTags": count_selected_tags(rows),
            }
            for name, rows in datasets.items()
        },
    }
    (SOURCES / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def count_values(values: Iterable[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    return dict(sorted(counts.items()))


def count_selected_tags(rows: list[dict]) -> dict[str, int]:
    selected = [
        "append",
        "email",
        "messaging",
        "browser",
        "code",
        "mid-word",
        "fim",
        "duplication-trap",
        "abbreviation",
        "app-specific",
        "secure-field",
        "terminal",
        "latency-short",
        "latency-medium",
        "latency-long",
    ]
    counts = {tag: 0 for tag in selected}
    for row in rows:
        tags = set(row["tags"])
        for tag in selected:
            if tag in tags:
                counts[tag] += 1
    return {tag: count for tag, count in counts.items() if count}


def main() -> None:
    source_docs = build_source_documents()
    core = build_core_cases(source_docs)
    edge = build_edge_cases(source_docs)
    policy = build_policy_cases()
    latency = build_latency_cases(source_docs)
    smoke = build_smoke_cases(core, edge, policy)
    datasets = {
        "smoke": smoke,
        "core": core,
        "edge": edge,
        "policy": policy,
        "latency": latency,
    }
    write_jsonl(SOURCES / "public-source-documents.jsonl", source_docs)
    for name, rows in datasets.items():
        write_jsonl(DATASETS / f"{name}.jsonl", rows)
    write_summary(source_docs, datasets)
    print(
        textwrap.dedent(
            f"""
            Generated:
              source documents: {len(source_docs)}
              smoke: {len(smoke)}
              core: {len(core)}
              edge: {len(edge)}
              policy: {len(policy)}
              latency: {len(latency)}
            """
        ).strip()
    )


if __name__ == "__main__":
    main()
