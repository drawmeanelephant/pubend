#!/usr/bin/env python3
"""End-to-end product CLI and output-artifact verification for pubend.

This harness copies corpus inputs into /tmp, invokes the committed ./pubend
product CLI, and audits emitted trees with tools/check_output.py.  It writes
nothing into the tracked corpus directories.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

import check_corpus  # noqa: E402  # independent corpus oracle
import check_output  # noqa: E402  # committed output-tree auditor

ROOT = Path(__file__).resolve().parent.parent
CLI = "./pubend"
AUDITOR = "tools/check_output.py"
BUILD_TIMEOUT_SECONDS = 180
AUDIT_TIMEOUT_SECONDS = 60
DIAGNOSTIC_KEY_ORDER = [
    "class",
    "path",
    "page",
    "line",
    "column",
    "target",
    "span",
    "message",
]
HOST_FAILURE_CLASSES = frozenset({
    "input-io",
    "compiler-artifact-build",
    "compiler-artifact-invalid",
    "compiler-invocation",
    "output-symlink",
    "output-not-directory",
    "output-parent-not-directory",
    "output-containment",
    "output-path-collision",
    "output-lock-exists",
    "output-stage-invalid",
    "output-backup-conflict",
    "output-backup-invalid",
    "output-io",
    "output-publication",
    "host-error",
})


@dataclass(frozen=True)
class PositiveSite:
    kind: str
    name: str
    source: Path

    @property
    def label(self) -> str:
        return f"{self.kind}/{self.name}"


@dataclass(frozen=True)
class PreparedPositive:
    site: PositiveSite
    copy: Path
    order_file: Path
    expected_ids: tuple[str, ...]


@dataclass(frozen=True)
class NegativeFixture:
    name: str
    source: Path
    expected_classes: tuple[str, ...]


@dataclass(frozen=True)
class PreparedNegative:
    fixture: NegativeFixture
    copy: Path
    initial_publication_present: tuple[str, ...]


@dataclass(frozen=True)
class BuildTask:
    key: str
    site: Path
    out_name: str | None


@dataclass(frozen=True)
class BuildResult:
    returncode: int | None
    stdout: bytes
    stderr: bytes
    runtime_ms: int
    error: str | None = None


def json_line(obj: dict[str, Any]) -> None:
    print(json.dumps(obj, ensure_ascii=True, separators=(",", ":")))


def compact_bytes(data: bytes, limit: int = 1200) -> str:
    text = data.decode("utf-8", errors="replace")
    if len(text) <= limit:
        return text
    return f"{text[:limit]}...<truncated; {len(text)} characters total>"


def direct_child_dirs(path: Path) -> list[Path]:
    children = []
    for child in path.iterdir():
        if child.is_symlink():
            raise RuntimeError(f"corpus child is a symlink: {child}")
        if child.is_dir():
            children.append(child)
    return sorted(children, key=lambda child: child.name)


def positive_catalog() -> list[PositiveSite]:
    sites: list[PositiveSite] = []
    for kind in ("corpus", "corpus-contract"):
        base = ROOT / kind
        sites.extend(
            PositiveSite(kind=kind, name=child.name, source=child)
            for child in direct_child_dirs(base)
        )
    if not sites:
        raise RuntimeError("no positive corpus sites discovered")
    return sites


def read_expected_classes(path: Path) -> tuple[str, ...]:
    text = path.read_text(encoding="utf-8")
    return tuple(line.strip() for line in text.splitlines() if line.strip())


def negative_catalog() -> tuple[list[NegativeFixture], dict[str, Any]]:
    base = ROOT / "corpus-negative"
    children = direct_child_dirs(base)
    selected: list[NegativeFixture] = []
    synthetic: list[str] = []
    valid_boundary: list[str] = []
    without_expected: list[str] = []

    for child in children:
        expected_path = child / "EXPECTED"
        if not expected_path.is_file():
            without_expected.append(child.name)
            continue
        expected = read_expected_classes(expected_path)
        if (child / "FIXTURE.synthetic.json").is_file():
            synthetic.append(child.name)
        elif set(expected) == {"valid"}:
            valid_boundary.append(child.name)
        else:
            selected.append(NegativeFixture(
                name=child.name,
                source=child,
                expected_classes=expected,
            ))

    if not selected:
        raise RuntimeError("no physical negative corpus fixtures discovered")

    selection = {
        "fixture_directories": len(children),
        "selected_negative": len(selected),
        "excluded_synthetic_injection": synthetic,
        "excluded_valid_boundary": valid_boundary,
        "valid_boundary_reason": (
            "EXPECTED=valid control fixtures cannot satisfy the nonzero "
            "negative-evidence requirement"
        ),
        "excluded_without_expected": without_expected,
    }
    return selected, selection


def discover_page_ids(content_root: Path) -> tuple[str, ...]:
    """Independently derive the spec's deterministic discovery page order."""
    ids: list[str] = []

    def walk(directory: Path, relative_dir: str) -> None:
        with os.scandir(directory) as iterator:
            entries = list(iterator)
        entries.sort(key=lambda entry: entry.name)

        file_entries = []
        directory_entries = []
        for entry in entries:
            if entry.is_symlink():
                continue
            if entry.is_dir(follow_symlinks=False):
                directory_entries.append(entry)
            else:
                file_entries.append(entry)

        for entry in file_entries:
            if not entry.is_file(follow_symlinks=False) or not entry.name.endswith(".md"):
                continue
            relative = f"{relative_dir}/{entry.name}" if relative_dir else entry.name
            ids.append(relative[:-3])
        for entry in directory_entries:
            relative = f"{relative_dir}/{entry.name}" if relative_dir else entry.name
            walk(Path(entry.path), relative)

    walk(content_root, "")
    return tuple(ids)


def write_expected_order(path: Path, ids: tuple[str, ...]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(list(ids), ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def copy_input(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)


def prepare_positive(workspace: Path, sites: list[PositiveSite]) -> list[PreparedPositive]:
    prepared: list[PreparedPositive] = []
    for site in sites:
        copy = workspace / "positive" / site.kind / site.name / "site"
        copy_input(site.source, copy)
        expected_ids = discover_page_ids(copy / "content")
        order_file = workspace / "positive" / site.kind / site.name / "expected-order.json"
        write_expected_order(order_file, expected_ids)
        prepared.append(PreparedPositive(
            site=site,
            copy=copy,
            order_file=order_file,
            expected_ids=expected_ids,
        ))
    return prepared


def prepare_negative(workspace: Path, fixtures: list[NegativeFixture]) -> list[PreparedNegative]:
    prepared: list[PreparedNegative] = []
    for fixture in fixtures:
        copy = workspace / "negative" / fixture.name / "site"
        copy_input(fixture.source, copy)
        initial_publication_present = tuple(
            name for name in PUBLICATION_OUTPUT_NAMES if os.path.lexists(copy / name)
        )
        prepared.append(PreparedNegative(
            fixture=fixture,
            copy=copy,
            initial_publication_present=initial_publication_present,
        ))
    return prepared


def build_environment() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("PUBEND_COMPILE_MJS", None)
    env["BEND_NO_TELEMETRY"] = "1"
    return env


def normalize_timeout_output(value: bytes | str | None) -> bytes:
    if value is None:
        return b""
    if isinstance(value, bytes):
        return value
    return value.encode("utf-8", errors="replace")


def run_pubend(task: BuildTask) -> BuildResult:
    argv = [CLI, "build", str(task.site)]
    if task.out_name is not None:
        argv.extend(["--out", task.out_name])
    started = time.perf_counter()
    try:
        completed = subprocess.run(
            argv,
            cwd=ROOT,
            env=build_environment(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=BUILD_TIMEOUT_SECONDS,
            check=False,
        )
        runtime_ms = round((time.perf_counter() - started) * 1000)
        return BuildResult(
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            runtime_ms=runtime_ms,
        )
    except subprocess.TimeoutExpired as error:
        runtime_ms = round((time.perf_counter() - started) * 1000)
        return BuildResult(
            returncode=None,
            stdout=normalize_timeout_output(error.stdout),
            stderr=normalize_timeout_output(error.stderr),
            runtime_ms=runtime_ms,
            error=f"timed out after {BUILD_TIMEOUT_SECONDS} seconds",
        )
    except OSError as error:
        runtime_ms = round((time.perf_counter() - started) * 1000)
        return BuildResult(
            returncode=None,
            stdout=b"",
            stderr=b"",
            runtime_ms=runtime_ms,
            error=f"could not invoke ./pubend: {error}",
        )


def run_build_tasks(tasks: list[BuildTask], jobs: int) -> dict[str, BuildResult]:
    results: dict[str, BuildResult] = {}
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=jobs,
        thread_name_prefix="pubend-e2e-build",
    ) as pool:
        futures = {pool.submit(run_pubend, task): task.key for task in tasks}
        for future in concurrent.futures.as_completed(futures):
            key = futures[future]
            try:
                results[key] = future.result()
            except Exception as error:  # defensive harness boundary
                results[key] = BuildResult(
                    returncode=None,
                    stdout=b"",
                    stderr=b"",
                    runtime_ms=0,
                    error=f"harness worker failed: {error}",
                )
    return results


def run_auditor_command(argv: list[str]) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        completed = subprocess.run(
            argv,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=AUDIT_TIMEOUT_SECONDS,
            check=False,
        )
        return {
            "exit": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
            "runtime_ms": round((time.perf_counter() - started) * 1000),
            "error": None,
        }
    except (subprocess.TimeoutExpired, OSError) as error:
        return {
            "exit": None,
            "stdout": b"",
            "stderr": b"",
            "runtime_ms": round((time.perf_counter() - started) * 1000),
            "error": str(error),
        }


def run_auditor(out_a: Path, order_file: Path, out_b: Path) -> dict[str, Any]:
    return run_auditor_command([
        sys.executable,
        AUDITOR,
        str(out_a),
        "--expect-order-json",
        str(order_file),
        "--compare",
        str(out_b),
    ])


def run_auditor_only(tree: Path, order_file: Path) -> dict[str, Any]:
    return run_auditor_command([
        sys.executable,
        AUDITOR,
        str(tree),
        "--expect-order-json",
        str(order_file),
    ])


def count_emitted_targets(tree: Path) -> tuple[dict[str, int], list[str]]:
    errors: list[str] = []
    counts = {"html_targets": 0, "internal_md_targets": 0}
    try:
        scan = check_output.scan_tree(str(tree))
        for entry in scan.entries_of_kind("file"):
            if not entry.path.endswith(".html"):
                continue
            text = check_output.read_bytes(entry.full_path).decode("utf-8", errors="strict")
            for target in check_output.extract_html_targets(text):
                counts["html_targets"] += 1
                if check_output.classify_emitted_target(target.value) == "internal-md":
                    counts["internal_md_targets"] += 1
    except Exception as error:
        errors.append(f"could not count emitted HTML targets through auditor hooks: {error}")
    return counts, errors


def require_byte_snippets(path: Path, snippets: list[bytes]) -> list[str]:
    data = path.read_bytes()
    return [
        f"{path.name} is missing required byte snippet {snippet.decode('ascii')!r}"
        for snippet in snippets
        if snippet not in data
    ]


def nav_pairs(links: tuple[check_output.NavLink, ...]) -> list[list[str | None]]:
    return [[link.href, link.text] for link in links]


NAV_DRAFT_TITLE_EXPECTED_HOOKS: dict[str, dict[str, list[list[str]]]] = {
    "child-id.html": {
        "parent": [["index.html", "Root & <Title>"]],
        "children": [],
    },
    "child-no-title.html": {
        "parent": [["index.html", "Root & <Title>"]],
        "children": [],
    },
    "draft-child.html": {
        "parent": [["index.html", "Root & <Title>"]],
        "children": [],
    },
    "draft-parent.html": {
        "parent": [],
        "children": [["grand.html", "Grand"]],
    },
    "grand.html": {
        "parent": [],
        "children": [],
    },
    "index.html": {
        "parent": [],
        "children": [
            ["child-id.html", "child-id"],
            ["child-no-title.html", "Em H1 & more"],
        ],
    },
    "second-root.html": {
        "parent": [],
        "children": [],
    },
}

NAV_DRAFT_TITLE_EXPECTED_TITLES = {
    "child-id.html": "child-id",
    "child-no-title.html": "Em H1 &amp; more",
    "draft-child.html": "Draft Child",
    "draft-parent.html": "Draft Parent",
    "grand.html": "Grand",
    "index.html": "Root &amp; &lt;Title&gt;",
    "second-root.html": "Second Root",
}

HREF_OUTPUT_EXPECTED_TARGETS: dict[str, tuple[tuple[str, str, str], ...]] = {
    "100%.html": (),
    "café.html": (),
    "index.html": (
        ("a", "href", "deep/page.html#frag"),
        ("a", "href", "cousin/other.html"),
        ("a", "href", "deep/sibling.html"),
        ("img", "src", "deep/image.html"),
        ("a", "href", "https://example.com/x.md"),
        ("a", "href", "#top"),
        ("a", "href", "file.txt"),
        ("a", "href", "/deep/page.md"),
        ("a", "href", "space%20page.html"),
        ("a", "href", "caf%C3%A9.html"),
        ("a", "href", "caf%C3%A9.html"),
        ("a", "href", "100%25.html"),
    ),
    "space page.html": (),
    "deep/image.html": (),
    "deep/page.html": (
        ("a", "href", "../index.html"),
        ("a", "href", "sibling.html"),
        ("a", "href", "sibling.html"),
        ("a", "href", "../cousin/other.html#c"),
    ),
    "deep/sibling.html": (
        ("a", "href", "page.html"),
    ),
    "cousin/other.html": (
        ("a", "href", "../deep/page.html"),
    ),
}


def shell_title_text(text: str) -> str | None:
    if not text.startswith(check_output.SHELL_PREFIX_TEXT):
        return None
    end = text.find(check_output.SHELL_HEAD_BODY, len(check_output.SHELL_PREFIX_TEXT))
    if end < 0:
        return None
    return text[len(check_output.SHELL_PREFIX_TEXT):end]


def validate_nav_draft_title(tree: Path) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    details: dict[str, Any] = {"nav_scope": "fixed generated shell nav region only"}
    actual_hooks: dict[str, Any] = {}
    actual_titles: dict[str, str | None] = {}

    for filename, expected in NAV_DRAFT_TITLE_EXPECTED_HOOKS.items():
        try:
            text = (tree / filename).read_bytes().decode("utf-8", errors="strict")
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"could not read {filename} for nav/title contract validation: {error}")
            continue

        hooks = check_output.extract_nav_hooks(text)
        actual = {
            "parent": nav_pairs(hooks.parent),
            "children": nav_pairs(hooks.children),
        }
        actual_hooks[filename] = actual
        if actual != expected:
            errors.append(
                f"{filename} generated-nav hooks differ from the exact ordered contract: "
                f"expected {expected!r}, actual {actual!r}"
            )

        title = shell_title_text(text)
        actual_titles[filename] = title
        expected_title = NAV_DRAFT_TITLE_EXPECTED_TITLES[filename]
        if title != expected_title:
            errors.append(
                f"{filename} shell title differs: expected {expected_title!r}, actual {title!r}"
            )

    details["generated_nav_hooks"] = actual_hooks
    details["shell_titles"] = actual_titles
    details["order_text_comparison"] = "exact per-file parent/child hook sequences"
    return details, errors


def validate_href_output(tree: Path) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    details: dict[str, Any] = {
        "target_comparison": "exact per-file (tag, attribute, target) sequences",
    }

    for filename in ("100%.html", "café.html", "space page.html"):
        details[f"literal_output_{filename}"] = (tree / filename).is_file()
        if not (tree / filename).is_file():
            errors.append(f"literal percent/Unicode output file is missing: {filename}")

    actual_targets: dict[str, list[list[str]]] = {}
    try:
        scan = check_output.scan_tree(str(tree))
    except check_output.HostError as error:
        return details, [f"could not scan href-output tree for exact target validation: {error}"]

    for entry in scan.entries_of_kind("file"):
        if not entry.path.endswith(".html"):
            continue
        try:
            text = check_output.read_bytes(entry.full_path).decode("utf-8", errors="strict")
            actual_targets[entry.path] = [
                [target.tag, target.attribute, target.value]
                for target in check_output.extract_html_targets(text)
            ]
        except (check_output.HostError, UnicodeDecodeError) as error:
            errors.append(f"could not extract exact targets from {entry.path}: {error}")

    details["actual_target_sequences"] = actual_targets
    expected_paths = set(HREF_OUTPUT_EXPECTED_TARGETS)
    actual_paths = set(actual_targets)
    if actual_paths != expected_paths:
        errors.append(
            "href-output .html file set differs from the exact contract: "
            f"missing {sorted(expected_paths - actual_paths)!r}, "
            f"extra {sorted(actual_paths - expected_paths)!r}"
        )

    for path in sorted(expected_paths & actual_paths):
        expected_sequence = [
            [tag, attribute, value]
            for tag, attribute, value in HREF_OUTPUT_EXPECTED_TARGETS[path]
        ]
        actual_sequence = actual_targets[path]
        if actual_sequence != expected_sequence:
            errors.append(
                f"{path} href/src target sequence differs: "
                f"expected {expected_sequence!r}, actual {actual_sequence!r}"
            )

    sibling_sequence = actual_targets.get("deep/page.html", [])
    sibling_count = sum(
        1
        for tag, attribute, value in sibling_sequence
        if [tag, attribute, value] == ["a", "href", "sibling.html"]
    )
    details["duplicate_sibling_target_count"] = sibling_count
    if sibling_count != 2:
        errors.append(
            "deep/page.html does not contain exactly two ordered sibling.html targets; "
            f"count is {sibling_count}"
        )
    return details, errors


def validate_order_manifest(tree: Path) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    details: dict[str, Any] = {}
    empty_output = tree / ".html"
    details["empty_id_output_exists"] = empty_output.is_file()
    if not empty_output.is_file():
        errors.append("empty-id output .html is missing")
    else:
        errors.extend(require_byte_snippets(empty_output, [b'<a href=".html">self</a>']))

    index_output = tree / "index.html"
    if not index_output.is_file():
        errors.append("index.html output is missing for Unicode href validation")
    else:
        errors.extend(require_byte_snippets(index_output, [
            'href="%EF%BD%8F.html"'.encode("ascii"),
            'href="%F0%9F%98%80.html"'.encode("ascii"),
        ]))

    try:
        manifest = json.loads((tree / "_pubend" / "manifest.json").read_text(encoding="utf-8"))
        pages = manifest.get("pages", [])
        details["manifest_page_ids"] = [
            page.get("id") for page in pages if isinstance(page, dict)
        ]
        first_id = pages[0].get("id") if pages else None
        details["manifest_first_id"] = first_id
        if first_id != "":
            errors.append(f"empty id is not first in manifest order: first id is {first_id!r}")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, IndexError, AttributeError) as error:
        errors.append(f"could not inspect order-manifest manifest first id: {error}")
    details["empty_id_link_snippet"] = "required"
    return details, errors


def validate_contract(site_label: str, tree: Path) -> tuple[dict[str, Any], list[str]]:
    if site_label == "corpus-contract/nav-draft-title":
        return validate_nav_draft_title(tree)
    if site_label == "corpus-contract/href-output":
        return validate_href_output(tree)
    if site_label == "corpus-contract/order-manifest":
        return validate_order_manifest(tree)
    return {}, []


def build_report(out_name: str, result: BuildResult) -> dict[str, Any]:
    return {
        "out": out_name,
        "exit": result.returncode,
        "stdout_bytes": len(result.stdout),
        "stderr_bytes": len(result.stderr),
        "runtime_ms": result.runtime_ms,
        "error": result.error,
    }


def evaluate_positive(
    prepared: PreparedPositive,
    results: dict[str, BuildResult],
) -> dict[str, Any]:
    label = prepared.site.label
    errors: list[str] = []
    build_reports: list[dict[str, Any]] = []

    for out_name in ("out-a", "out-b"):
        key = f"positive:{label}:{out_name}"
        result = results[key]
        build_reports.append(build_report(out_name, result))
        if result.error is not None:
            errors.append(f"{out_name}: {result.error}")
        if result.returncode != 0:
            errors.append(
                f"{out_name}: ./pubend exited {result.returncode}; "
                f"stderr={compact_bytes(result.stderr)!r}"
            )
        if result.stdout:
            errors.append(f"{out_name}: stdout was not empty: {compact_bytes(result.stdout)!r}")
        if result.stderr:
            errors.append(f"{out_name}: stderr was not empty: {compact_bytes(result.stderr)!r}")

    audit_report: dict[str, Any] = {"status": "skipped-after-build-failure"}
    target_report: dict[str, Any] | None = None
    contract_details: dict[str, Any] = {}

    if not errors:
        out_a = prepared.copy / "out-a"
        out_b = prepared.copy / "out-b"
        audit = run_auditor(out_a, prepared.order_file, out_b)
        audit_report = {
            "status": "run",
            "mode": "audit out-a with JSON expected order and exact-shape --compare out-b",
            "exit": audit["exit"],
            "stdout_bytes": len(audit["stdout"]),
            "stderr_bytes": len(audit["stderr"]),
            "runtime_ms": audit["runtime_ms"],
            "error": audit["error"],
        }
        if audit["error"] is not None:
            errors.append(f"auditor invocation failed: {audit['error']}")
        if audit["exit"] != 0:
            errors.append(
                f"auditor exited {audit['exit']}; stdout={compact_bytes(audit['stdout'])!r}; "
                f"stderr={compact_bytes(audit['stderr'])!r}"
            )
        if audit["stdout"] and audit["exit"] == 0:
            errors.append(f"auditor stdout was not empty on success: {compact_bytes(audit['stdout'])!r}")
        if audit["stderr"] and audit["exit"] == 0:
            errors.append(f"auditor stderr was not empty on success: {compact_bytes(audit['stderr'])!r}")

        counts, count_errors = count_emitted_targets(out_a)
        target_report = counts
        errors.extend(count_errors)
        if counts["internal_md_targets"] != 0:
            errors.append(
                f"auditor target hooks found {counts['internal_md_targets']} internal .md targets in emitted HTML"
            )

        contract_details, contract_errors = validate_contract(label, out_a)
        errors.extend(contract_errors)

    return {
        "type": "positive-site",
        "site": label,
        "ok": not errors,
        "pages": len(prepared.expected_ids),
        "builds": build_reports,
        "audit": audit_report,
        "targets": target_report,
        "contract": contract_details,
        "errors": errors,
    }


def ordered_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    keys = [key for key, _value in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate JSON object key")
    return dict(pairs)


def is_nonnegative_int_or_null(value: Any) -> bool:
    return (
        value is None
        or (isinstance(value, int) and not isinstance(value, bool) and value >= 0)
    )


def is_string_or_null(value: Any) -> bool:
    return value is None or isinstance(value, str)


def validate_error_payload(stderr: bytes) -> tuple[dict[str, Any] | None, list[str]]:
    errors: list[str] = []
    if not stderr:
        return None, ["stderr is empty; expected one structured JSON error object"]
    if stderr.find(b"\n") != len(stderr) - 1:
        errors.append("stderr is not exactly one newline-terminated JSON line")
    try:
        text = stderr.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        return None, [f"stderr is not strict UTF-8 at byte offset {error.start}"]
    try:
        decoder = json.JSONDecoder(object_pairs_hook=ordered_json_object)
        payload, end = decoder.raw_decode(text)
    except (json.JSONDecodeError, ValueError) as error:
        return None, [f"stderr is not valid duplicate-free JSON: {error}"]
    if end != len(text) - 1:
        errors.append("stderr JSON is not followed immediately by its single newline")

    if not isinstance(payload, dict):
        return None, ["stderr JSON top level is not an object"]
    if list(payload.keys()) != ["version", "status", "diagnostics"]:
        errors.append(f"stderr top-level key order is {list(payload.keys())!r}")
    if payload.get("version") != 1:
        errors.append(f"stderr version is {payload.get('version')!r}, expected 1")
    if payload.get("status") != "error":
        errors.append(f"stderr status is {payload.get('status')!r}, expected 'error'")
    diagnostics = payload.get("diagnostics")
    if not isinstance(diagnostics, list) or not diagnostics:
        errors.append("stderr diagnostics is not a non-empty array")
        return payload, errors

    for index, item in enumerate(diagnostics):
        if not isinstance(item, dict):
            errors.append(f"diagnostic {index} is not an object")
            continue
        if list(item.keys()) != DIAGNOSTIC_KEY_ORDER:
            errors.append(f"diagnostic {index} key order is {list(item.keys())!r}")
        if not isinstance(item.get("class"), str) or not item.get("class"):
            errors.append(f"diagnostic {index} class is not a non-empty string")
        for key in ("path", "page", "target"):
            if not is_string_or_null(item.get(key)):
                errors.append(f"diagnostic {index} {key} is neither a string nor null")
        for key in ("line", "column"):
            if not is_nonnegative_int_or_null(item.get(key)):
                errors.append(
                    f"diagnostic {index} {key} is neither a non-negative integer nor null"
                )
        if not isinstance(item.get("message"), str):
            errors.append(f"diagnostic {index} message is not a string")
        span = item.get("span")
        if span is not None:
            if not isinstance(span, dict) or list(span.keys()) != ["start", "end"]:
                errors.append(f"diagnostic {index} span is not an object with start,end key order")
            else:
                offsets_valid = all(
                    isinstance(span.get(key), int)
                    and not isinstance(span.get(key), bool)
                    and span.get(key) >= 0
                    for key in ("start", "end")
                )
                if not offsets_valid:
                    errors.append(f"diagnostic {index} span offsets are not non-negative integers")
    return payload, errors


ORACLE_EXACT_MULTIPLICITY_SKIP_REASONS = {
    "malformed-frontmatter": (
        "unterminated frontmatter at the trailing-newline boundary is outside the "
        "Python oracle's exact multiplicity approximation; class-set evidence is "
        "still required, but exact oracle multiplicity is intentionally not claimed"
    ),
}

PUBLICATION_OUTPUT_NAMES = (
    "dist",
    "dist.pubend-lock",
    "dist.pubend-stage",
    "dist.pubend-previous",
)


def sorted_counter_object(counts: Counter[str]) -> dict[str, int]:
    return {key: counts[key] for key in sorted(counts)}


def oracle_diagnostic_class_counts(site: Path) -> Counter[str]:
    oracle_diagnostics, _page_count, _link_count = check_corpus.check_site(str(site))
    return Counter(diagnostic.cls for diagnostic in oracle_diagnostics)


def evaluate_negative(
    prepared: PreparedNegative,
    result: BuildResult,
) -> dict[str, Any]:
    fixture = prepared.fixture
    errors: list[str] = []
    payload, payload_errors = validate_error_payload(result.stderr)
    errors.extend(payload_errors)

    diagnostics = payload.get("diagnostics", []) if isinstance(payload, dict) else []
    actual_class_counts = Counter(
        item.get("class")
        for item in diagnostics
        if isinstance(item, dict) and isinstance(item.get("class"), str)
    )
    actual_classes = sorted(actual_class_counts)
    expected_classes = sorted(set(fixture.expected_classes))
    class_agreement = "exact" if actual_classes == expected_classes else "mismatch"

    oracle_counts: Counter[str] | None = None
    oracle_error: str | None = None
    try:
        oracle_counts = oracle_diagnostic_class_counts(prepared.copy)
    except Exception as error:
        oracle_error = f"could not derive independent oracle diagnostic counts: {error}"
        errors.append(oracle_error)

    multiplicity_skip_reason = ORACLE_EXACT_MULTIPLICITY_SKIP_REASONS.get(fixture.name)
    if oracle_counts is None:
        multiset_agreement = "oracle-error"
    elif multiplicity_skip_reason is not None:
        multiset_agreement = "skipped-documented-oracle-limit"
    elif actual_class_counts == oracle_counts:
        multiset_agreement = "exact"
    else:
        multiset_agreement = "mismatch"
        errors.append(
            "diagnostic class multiset mismatch against independent corpus oracle: "
            f"expected {sorted_counter_object(oracle_counts)!r}, "
            f"actual {sorted_counter_object(actual_class_counts)!r}"
        )

    if fixture.name == "link-malformed-percent" and actual_class_counts.get("link-malformed-percent") != 3:
        errors.append(
            "link-malformed-percent must emit exactly 3 link-malformed-percent diagnostics; "
            f"actual count is {actual_class_counts.get('link-malformed-percent', 0)}"
        )

    if result.error is not None:
        errors.append(result.error)
    if result.returncode == 0:
        errors.append("./pubend unexpectedly succeeded for a negative fixture")
    elif result.returncode not in (1, 3):
        errors.append(f"./pubend exited {result.returncode}, expected nonzero content/host class 1 or 3")
    elif actual_classes:
        host_failure = bool(set(actual_classes) & HOST_FAILURE_CLASSES)
        if host_failure and result.returncode != 3:
            errors.append(f"host failure classes exited {result.returncode}, expected 3")
        if not host_failure and result.returncode != 1:
            errors.append(f"content/input failure classes exited {result.returncode}, expected 1")

    if result.stdout:
        errors.append(f"stdout was not empty: {compact_bytes(result.stdout)!r}")
    if class_agreement != "exact":
        errors.append(
            f"diagnostic class set mismatch: expected {expected_classes!r}, actual {actual_classes!r}"
        )

    initial_publication = frozenset(prepared.initial_publication_present)
    publication_paths: dict[str, dict[str, bool]] = {}
    for name in PUBLICATION_OUTPUT_NAMES:
        present_after = os.path.lexists(prepared.copy / name)
        initially_present = name in initial_publication
        publication_paths[name] = {
            "initially_present": initially_present,
            "present_after": present_after,
        }
        if present_after and not initially_present:
            errors.append(f"{name} exists after failed build despite starting absent")

    return {
        "type": "negative-fixture",
        "fixture": fixture.name,
        "ok": not errors,
        "exit": result.returncode,
        "stdout_bytes": len(result.stdout),
        "stderr_bytes": len(result.stderr),
        "runtime_ms": result.runtime_ms,
        "expected_classes": expected_classes,
        "actual_classes": actual_classes,
        "class_agreement": class_agreement,
        "expected_oracle_class_counts": (
            sorted_counter_object(oracle_counts) if oracle_counts is not None else None
        ),
        "actual_class_counts": sorted_counter_object(actual_class_counts),
        "multiset_agreement": multiset_agreement,
        "multiplicity_skip_reason": multiplicity_skip_reason,
        "oracle_error": oracle_error,
        "dist_exists": publication_paths["dist"]["present_after"],
        "publication_paths": publication_paths,
        "errors": errors,
    }


def probe_audit_report(audit: dict[str, Any]) -> dict[str, Any]:
    return {
        "exit": audit["exit"],
        "stdout_bytes": len(audit["stdout"]),
        "stderr_bytes": len(audit["stderr"]),
        "runtime_ms": audit["runtime_ms"],
        "error": audit["error"],
        "stdout": compact_bytes(audit["stdout"]),
        "stderr": compact_bytes(audit["stderr"]),
    }


def audit_clean(audit: dict[str, Any]) -> bool:
    return (
        audit["error"] is None
        and audit["exit"] == 0
        and not audit["stdout"]
        and not audit["stderr"]
    )


def require_successful_build(label: str, result: BuildResult, errors: list[str]) -> None:
    if result.error is not None:
        errors.append(f"{label}: {result.error}")
    if result.returncode != 0:
        errors.append(
            f"{label}: ./pubend exited {result.returncode}; "
            f"stderr={compact_bytes(result.stderr)!r}"
        )
    if result.stdout:
        errors.append(f"{label}: stdout was not empty: {compact_bytes(result.stdout)!r}")
    if result.stderr:
        errors.append(f"{label}: stderr was not empty: {compact_bytes(result.stderr)!r}")


def run_newline_order_probe(workspace: Path) -> dict[str, Any]:
    errors: list[str] = []
    details: dict[str, Any] = {}
    probe_root = workspace / "probes" / "newline-order"
    site = probe_root / "site"
    newline_id = "line\nbreak"

    try:
        content = site / "content"
        content.mkdir(parents=True)
        (content / f"{newline_id}.md").write_text("# Newline id\n", encoding="utf-8")
        expected_ids = discover_page_ids(content)
        details["expected_ids"] = list(expected_ids)
        details["newline_id_repr"] = repr(newline_id)

        result = run_pubend(BuildTask(
            key="probe:newline-order",
            site=site,
            out_name=None,
        ))
        details["build"] = build_report("dist", result)
        require_successful_build("newline-order build", result, errors)

        order_file = probe_root / "expected-order.json"
        write_expected_order(order_file, expected_ids)
        try:
            roundtrip_ids = check_output.read_expect_order_json_file(str(order_file))
            details["json_roundtrip_ids"] = list(roundtrip_ids)
            details["json_roundtrip_exact"] = roundtrip_ids == expected_ids
            if roundtrip_ids != expected_ids:
                errors.append(
                    "JSON order evidence did not round-trip the U+000A id exactly: "
                    f"expected {expected_ids!r}, decoded {roundtrip_ids!r}"
                )
        except (check_output.HostError, OSError) as error:
            errors.append(f"could not read JSON newline-id order evidence: {error}")

        output_file = site / "dist" / f"{newline_id}.html"
        details["literal_newline_output_exists"] = output_file.is_file()
        if result.returncode == 0 and not output_file.is_file():
            errors.append("literal output file containing U+000A in its name is missing")

        if result.returncode == 0:
            audit = run_auditor_only(site / "dist", order_file)
            details["audit"] = probe_audit_report(audit)
            if not audit_clean(audit):
                errors.append(
                    "auditor did not accept the newline-id output with JSON order evidence: "
                    f"{probe_audit_report(audit)!r}"
                )
    except Exception as error:
        errors.append(f"newline-order probe harness failed: {error}")

    return {
        "type": "newline-order-probe",
        "ok": not errors,
        "details": details,
        "errors": errors,
    }


def output_relative_path(tree: Path, relative: str) -> Path:
    return tree.joinpath(*relative.split("/"))


def refresh_manifest_digests(tree: Path) -> None:
    manifest_path = tree / "_pubend" / "manifest.json"
    manifest = json.loads(
        manifest_path.read_text(encoding="utf-8"),
        object_pairs_hook=ordered_json_object,
    )
    pages = manifest.get("pages")
    if not isinstance(pages, list):
        raise ValueError("mutated fixture manifest pages is not a list")
    for index, page in enumerate(pages):
        if not isinstance(page, dict) or not isinstance(page.get("path"), str):
            raise ValueError(f"mutated fixture manifest page {index} has no string path")
        page["sha256"] = hashlib.sha256(
            output_relative_path(tree, page["path"]).read_bytes()
        ).hexdigest()
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def copy_tree_with_mutated_html(
    source: Path,
    destination: Path,
    relative_html: str,
    transform: Callable[[str], str],
) -> None:
    shutil.copytree(source, destination, symlinks=True)
    html_path = output_relative_path(destination, relative_html)
    original = html_path.read_bytes().decode("utf-8", errors="strict")
    mutated = transform(original)
    if mutated == original:
        raise ValueError(f"mutation did not change {relative_html}")
    html_path.write_bytes(mutated.encode("utf-8"))
    refresh_manifest_digests(destination)


NAV_CHILD_LIST_ORIGINAL = (
    '<ul class="pubend-children">'
    '<li><a href="child-id.html">child-id</a></li>'
    '<li><a href="child-no-title.html">Em H1 &amp; more</a></li>'
    '</ul>'
)


def inject_fake_nav_inside_main(text: str) -> str:
    generated = (
        '<nav class="pubend-nav">'
        + NAV_CHILD_LIST_ORIGINAL
        + '</nav><main>'
    )
    hollow_generated = (
        '<nav class="pubend-nav">'
        '<ul class="pubend-children"></ul>'
        '</nav><main>'
    )
    fake_main_nav = (
        '<nav class="pubend-nav">'
        + NAV_CHILD_LIST_ORIGINAL
        + '</nav>'
    )
    if generated not in text:
        raise ValueError("original generated index nav serialization was not found")
    return text.replace(generated, hollow_generated + fake_main_nav, 1)


def add_whitespace_between_generated_nav_items(text: str) -> str:
    needle = '</li><li><a href="child-no-title.html">'
    replacement = '</li> \n  <li><a href="child-no-title.html">'
    if needle not in text:
        raise ValueError("adjacent generated index nav items were not found")
    return text.replace(needle, replacement, 1)


def make_nav_mutation_fixture(
    prepared: PreparedPositive,
    destination: Path,
    transform: Callable[[str], str],
) -> None:
    copy_tree_with_mutated_html(
        prepared.copy / "out-a",
        destination,
        "index.html",
        transform,
    )


def evaluate_nav_injection_probe(
    prepared: PreparedPositive,
    workspace: Path,
) -> dict[str, Any]:
    errors: list[str] = []
    details: dict[str, Any] = {}
    tree = workspace / "probes" / "nav-injected-main" / "tree"

    try:
        make_nav_mutation_fixture(prepared, tree, inject_fake_nav_inside_main)
        audit = run_auditor_only(tree, prepared.order_file)
        details["audit"] = probe_audit_report(audit)
        if not audit_clean(audit):
            errors.append(
                "injected-main-nav mutated fixture is not auditor-valid, so the probe is invalid: "
                f"{probe_audit_report(audit)!r}"
            )

        contract_details, contract_errors = validate_nav_draft_title(tree)
        details["contract_details"] = contract_details
        details["contract_errors"] = contract_errors
        index_children = (
            contract_details.get("generated_nav_hooks", {})
            .get("index.html", {})
            .get("children")
        )
        if not contract_errors:
            errors.append("nav markup injected inside <main> was accepted as generated-nav evidence")
        if index_children != []:
            errors.append(
                "generated nav extraction did not isolate the hollow shell nav; "
                f"index child hooks were {index_children!r}"
            )
    except Exception as error:
        errors.append(f"nav-injection probe harness failed: {error}")

    return {
        "type": "nav-injection-probe",
        "ok": not errors,
        "details": details,
        "errors": errors,
    }


def evaluate_nav_whitespace_probe(
    prepared: PreparedPositive,
    workspace: Path,
) -> dict[str, Any]:
    errors: list[str] = []
    details: dict[str, Any] = {}
    tree = workspace / "probes" / "nav-whitespace" / "tree"

    try:
        make_nav_mutation_fixture(prepared, tree, add_whitespace_between_generated_nav_items)
        audit = run_auditor_only(tree, prepared.order_file)
        details["audit"] = probe_audit_report(audit)
        if not audit_clean(audit):
            errors.append(
                "whitespace-mutated generated nav fixture is not auditor-valid, so the probe is invalid: "
                f"{probe_audit_report(audit)!r}"
            )

        contract_details, contract_errors = validate_nav_draft_title(tree)
        details["contract_details"] = contract_details
        details["contract_errors"] = contract_errors
        if contract_errors:
            errors.append(
                "whitespace between generated nav li elements failed despite exact order/text "
                f"being correct: {contract_errors!r}"
            )
    except Exception as error:
        errors.append(f"nav-whitespace probe harness failed: {error}")

    return {
        "type": "nav-whitespace-probe",
        "ok": not errors,
        "details": details,
        "errors": errors,
    }


def nav_harness_probe_rows(
    workspace: Path,
    positives: list[PreparedPositive],
) -> list[dict[str, Any]]:
    prepared = next(
        (candidate for candidate in positives if candidate.site.label == "corpus-contract/nav-draft-title"),
        None,
    )
    if prepared is None:
        return [{
            "type": "nav-harness-probes",
            "ok": False,
            "details": {},
            "errors": ["corpus-contract/nav-draft-title positive site was not prepared"],
        }]
    if not (prepared.copy / "out-a").is_dir():
        return [{
            "type": "nav-harness-probes",
            "ok": False,
            "details": {},
            "errors": ["corpus-contract/nav-draft-title out-a is unavailable for mutation probes"],
        }]
    return [
        evaluate_nav_injection_probe(prepared, workspace),
        evaluate_nav_whitespace_probe(prepared, workspace),
    ]


def tree_difference_object(difference: check_output.TreeDifference) -> dict[str, Any]:
    return {
        "kind": difference.kind,
        "path": difference.path,
        "first_byte": difference.first_byte,
        "left_kind": difference.left_kind,
        "right_kind": difference.right_kind,
    }


def publication_sibling_states(site: Path) -> dict[str, bool]:
    return {
        name: os.path.lexists(site / name)
        for name in PUBLICATION_OUTPUT_NAMES
        if name != "dist"
    }


def run_preservation_probe(workspace: Path) -> dict[str, Any]:
    errors: list[str] = []
    details: dict[str, Any] = {
        "comparison": "exact entry path/kind shape plus regular-file bytes",
    }
    probe_root = workspace / "probes" / "preservation"
    site = probe_root / "site"

    try:
        content = site / "content"
        content.mkdir(parents=True)
        index = content / "index.md"
        index.write_text("# Home\n", encoding="utf-8")
        order_file = probe_root / "expected-order.json"
        write_expected_order(order_file, discover_page_ids(content))

        first = run_pubend(BuildTask(
            key="probe:preservation:initial",
            site=site,
            out_name=None,
        ))
        details["initial_build"] = build_report("dist", first)
        require_successful_build("preservation initial build", first, errors)
        details["publication_siblings_after_initial"] = publication_sibling_states(site)
        for name, present in details["publication_siblings_after_initial"].items():
            if present:
                errors.append(f"{name} exists after successful initial publication")

        dist = site / "dist"
        if first.returncode == 0:
            initial_audit = run_auditor_only(dist, order_file)
            details["initial_audit"] = probe_audit_report(initial_audit)
            if not audit_clean(initial_audit):
                errors.append(
                    "initial preservation output is not auditor-valid: "
                    f"{probe_audit_report(initial_audit)!r}"
                )

            baseline = probe_root / "dist-baseline"
            shutil.copytree(dist, baseline, symlinks=True)
            index.write_text(
                "# Home\n\nThis now links to [a ghost](ghost.md).\n",
                encoding="utf-8",
            )

            second = run_pubend(BuildTask(
                key="probe:preservation:dangling-rebuild",
                site=site,
                out_name=None,
            ))
            details["rebuild"] = build_report("dist", second)
            if second.error is not None:
                errors.append(f"preservation rebuild: {second.error}")
            if second.returncode != 1:
                errors.append(
                    f"preservation rebuild exited {second.returncode}, expected exactly 1"
                )
            if second.stdout:
                errors.append(
                    "preservation rebuild stdout was not empty: "
                    f"{compact_bytes(second.stdout)!r}"
                )
            payload, payload_errors = validate_error_payload(second.stderr)
            errors.extend(f"preservation rebuild {error}" for error in payload_errors)
            diagnostics = payload.get("diagnostics", []) if isinstance(payload, dict) else []
            rebuild_counts = Counter(
                item.get("class")
                for item in diagnostics
                if isinstance(item, dict) and isinstance(item.get("class"), str)
            )
            details["rebuild_class_counts"] = sorted_counter_object(rebuild_counts)
            if rebuild_counts != Counter({"link-nonexistent-page": 1}):
                errors.append(
                    "preservation rebuild diagnostic multiset differs from exactly one "
                    f"link-nonexistent-page: {sorted_counter_object(rebuild_counts)!r}"
                )

            try:
                differences = check_output.compare_trees(str(baseline), str(dist))
                difference_objects = [
                    tree_difference_object(difference) for difference in differences
                ]
                details["dist_differences_after_failed_rebuild"] = difference_objects
                if differences:
                    errors.append(
                        "failed rebuild changed the previously published dist tree: "
                        f"{difference_objects!r}"
                    )
            except check_output.HostError as error:
                errors.append(f"could not compare preserved dist trees: {error}")

            details["publication_siblings_after_rebuild"] = publication_sibling_states(site)
            for name, present in details["publication_siblings_after_rebuild"].items():
                if present:
                    errors.append(f"{name} exists after failed rebuild")
    except Exception as error:
        errors.append(f"preservation probe harness failed: {error}")

    return {
        "type": "preservation-probe",
        "ok": not errors,
        "details": details,
        "errors": errors,
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="verify pubend product CLI output trees end-to-end using copied corpus inputs",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=min(4, os.cpu_count() or 1),
        help="maximum concurrent ./pubend invocations (default: min(4, cpu count))",
    )
    parser.add_argument(
        "--keep-tmp",
        action="store_true",
        help="retain the /tmp verification workspace for inspection",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.jobs < 1:
        print("error: --jobs must be at least 1", file=sys.stderr)
        return 2

    total_started = time.perf_counter()
    workspace = Path(tempfile.mkdtemp(prefix="pubend-e2e-", dir="/tmp"))
    workspace_retained = args.keep_tmp

    try:
        positive_sites = positive_catalog()
        negative_fixtures, negative_selection = negative_catalog()
        positives = prepare_positive(workspace, positive_sites)
        negatives = prepare_negative(workspace, negative_fixtures)

        tasks: list[BuildTask] = []
        for prepared in positives:
            for out_name in ("out-a", "out-b"):
                tasks.append(BuildTask(
                    key=f"positive:{prepared.site.label}:{out_name}",
                    site=prepared.copy,
                    out_name=out_name,
                ))
        for prepared in negatives:
            tasks.append(BuildTask(
                key=f"negative:{prepared.fixture.name}",
                site=prepared.copy,
                out_name=None,
            ))

        json_line({
            "type": "start",
            "positive_sites": len(positives),
            "positive_builds": len(positives) * 2,
            "negative_fixtures": len(negatives),
            "negative_selection": negative_selection,
            "jobs": args.jobs,
            "workspace": str(workspace),
        })

        build_started = time.perf_counter()
        build_results = run_build_tasks(tasks, args.jobs)
        build_runtime_ms = round((time.perf_counter() - build_started) * 1000)

        rows: list[dict[str, Any]] = []
        positive_passed = 0
        for prepared in positives:
            row = evaluate_positive(prepared, build_results)
            positive_passed += 1 if row["ok"] else 0
            rows.append(row)
            json_line(row)

        negative_passed = 0
        exact_class_matches = 0
        exact_multiset_matches = 0
        skipped_multiset_matches = 0
        for prepared in negatives:
            row = evaluate_negative(prepared, build_results[f"negative:{prepared.fixture.name}"])
            negative_passed += 1 if row["ok"] else 0
            exact_class_matches += 1 if row["class_agreement"] == "exact" else 0
            exact_multiset_matches += 1 if row["multiset_agreement"] == "exact" else 0
            skipped_multiset_matches += (
                1 if row["multiset_agreement"] == "skipped-documented-oracle-limit" else 0
            )
            rows.append(row)
            json_line(row)

        probe_started = time.perf_counter()
        probe_rows = [run_newline_order_probe(workspace)]
        probe_rows.extend(nav_harness_probe_rows(workspace, positives))
        probe_rows.append(run_preservation_probe(workspace))
        probe_runtime_ms = round((time.perf_counter() - probe_started) * 1000)
        probe_passed = 0
        for row in probe_rows:
            probe_passed += 1 if row["ok"] else 0
            rows.append(row)
            json_line(row)

        ok = all(row["ok"] for row in rows)
        runtime_ms = round((time.perf_counter() - total_started) * 1000)
        json_line({
            "type": "summary",
            "ok": ok,
            "positive_sites_total": len(positives),
            "positive_sites_passed": positive_passed,
            "positive_builds": len(positives) * 2,
            "negative_fixtures_total": len(negatives),
            "negative_fixtures_passed": negative_passed,
            "negative_class_agreement_exact": exact_class_matches,
            "negative_class_multiset_exact": exact_multiset_matches,
            "negative_class_multiset_skipped_documented": skipped_multiset_matches,
            "negative_selection": negative_selection,
            "probe_rows_total": len(probe_rows),
            "probe_rows_passed": probe_passed,
            "jobs": args.jobs,
            "build_runtime_ms": build_runtime_ms,
            "probe_runtime_ms": probe_runtime_ms,
            "runtime_ms": runtime_ms,
            "workspace_retained": str(workspace) if workspace_retained else None,
        })
        return 0 if ok else 1
    except Exception as error:
        json_line({
            "type": "fatal",
            "ok": False,
            "error": str(error),
            "workspace_retained": str(workspace) if workspace_retained else None,
        })
        return 2
    finally:
        if not workspace_retained:
            shutil.rmtree(workspace, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
