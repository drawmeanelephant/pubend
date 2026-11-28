#!/usr/bin/env python3
"""Filesystem-boundary regression probes for the pubend product CLI.

These probes exercise behavior that corpus verification cannot express: case
aliases, symlinked ancestors, fixed publication sibling names, ownership
markers, foreign-data preservation, output path collisions, and wrapper
symlink resolution. Tree preservation means exact relative entry paths, entry
kinds, symlink targets, and regular-file bytes; metadata is outside scope.
Every writable tree is confined to a temporary workspace.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable

sys.dont_write_bytecode = True

import check_output  # noqa: E402
import verify_end_to_end  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
CLI = REPO / "pubend"
AUDITOR = REPO / "tools" / "check_output.py"
BUILD_TIMEOUT_SECONDS = 180
STAGE_OWNER = "pubend incomplete stage owner v1\n"
BACKUP_OWNER = "pubend backup owner v1\n"
PUBLICATION_SUFFIXES = (".pubend-lock", ".pubend-stage", ".pubend-previous")


def publication_sibling_names(output_name: str = "dist") -> tuple[str, ...]:
    return tuple(f"{output_name}{suffix}" for suffix in PUBLICATION_SUFFIXES)


TreeSnapshot = dict[str, tuple[str, bytes | str | None]]


class ProbeFailure(AssertionError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


def compact_bytes(data: bytes, limit: int = 500) -> str:
    text = data.decode("utf-8", errors="replace")
    if len(text) <= limit:
        return text
    return f"{text[:limit]}...<truncated; {len(text)} characters total>"


def build_environment() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("PUBEND_COMPILE_MJS", None)
    env["BEND_NO_TELEMETRY"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def snapshot_tree(root: Path) -> TreeSnapshot | None:
    if not os.path.lexists(root):
        return None
    entries: TreeSnapshot = {}

    def record(path: Path, relative: str) -> None:
        if os.path.islink(path):
            entries[relative] = ("symlink", os.readlink(path))
        elif path.is_dir():
            entries[relative] = ("directory", None)
        elif path.is_file():
            entries[relative] = ("file", path.read_bytes())
        else:
            entries[relative] = ("nonregular", None)

    def walk(directory: Path, relative_dir: str) -> None:
        with os.scandir(directory) as iterator:
            children = sorted(iterator, key=lambda entry: entry.name)
        for child in children:
            child_path = Path(child.path)
            relative = f"{relative_dir}/{child.name}" if relative_dir else child.name
            record(child_path, relative)
            if not child.is_symlink() and child.is_dir(follow_symlinks=False):
                walk(child_path, relative)

    record(root, "")
    if entries[""][0] == "directory":
        walk(root, "")
    return entries


def first_tree_difference(before: TreeSnapshot | None, after: TreeSnapshot | None) -> str:
    if before is None or after is None:
        return f"existence changed: before {'exists' if before is not None else 'absent'}, after {'exists' if after is not None else 'absent'}"
    for relative in sorted(set(before) | set(after)):
        if relative not in before:
            return f"added entry {relative!r}"
        if relative not in after:
            return f"removed entry {relative!r}"
        if before[relative][0] != after[relative][0]:
            return f"kind changed for {relative!r}: {before[relative][0]} -> {after[relative][0]}"
        if before[relative][1] != after[relative][1]:
            return f"payload changed for {relative!r}"
    return "trees differ"


def require_tree_unchanged(before: TreeSnapshot | None, path: Path, label: str) -> None:
    after = snapshot_tree(path)
    require(after == before, f"{label}: tree was not exactly preserved: {first_tree_difference(before, after)}")


def require_lock_absent(site: Path, label: str) -> None:
    require(not os.path.lexists(site / "dist.pubend-lock"), f"{label}: publication lock remains")


def require_publication_siblings_absent(site: Path, label: str, output_name: str = "dist") -> None:
    remaining = [name for name in publication_sibling_names(output_name) if os.path.lexists(site / name)]
    require(not remaining, f"{label}: publication siblings remain: {remaining!r}")


def ascii_case_alias_visible(content: Path) -> bool:
    alias = content.parent / "CONTENT"
    try:
        if os.path.islink(alias) or not alias.is_dir():
            return False
        content_stat = content.stat()
        alias_stat = alias.stat()
        return content_stat.st_dev == alias_stat.st_dev and content_stat.st_ino == alias_stat.st_ino
    except OSError:
        return False


def run_pubend(wrapper: Path, *args: object) -> dict[str, Any]:
    argv = [str(wrapper), *[str(arg) for arg in args]]
    started = time.perf_counter()
    try:
        completed = subprocess.run(
            argv,
            cwd=REPO,
            env=build_environment(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=BUILD_TIMEOUT_SECONDS,
            check=False,
        )
        return {
            "exit": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
            "runtime_ms": round((time.perf_counter() - started) * 1000),
            "error": None,
        }
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, bytes) else b""
        stderr = error.stderr if isinstance(error.stderr, bytes) else b""
        return {
            "exit": None,
            "stdout": stdout,
            "stderr": stderr,
            "runtime_ms": round((time.perf_counter() - started) * 1000),
            "error": f"timed out after {BUILD_TIMEOUT_SECONDS} seconds",
        }


def one_diagnostic(proc: dict[str, Any]) -> dict[str, Any]:
    require(proc["error"] is None, f"CLI invocation error: {proc['error']}")
    payload, schema_errors = verify_end_to_end.validate_error_payload(proc["stderr"])
    require(not schema_errors, f"structured diagnostic schema errors: {schema_errors!r}")
    require(isinstance(payload, dict), "stderr payload is not an object")
    diagnostics = payload.get("diagnostics")
    require(isinstance(diagnostics, list) and len(diagnostics) == 1,
            f"expected exactly one diagnostic, got {diagnostics!r}")
    return diagnostics[0]


def make_site(root: Path, name: str) -> Path:
    site = root / "sites" / name
    content = site / "content"
    content.mkdir(parents=True)
    (content / "index.md").write_text("# Home\n\nboundary probe\n", encoding="utf-8")
    return site


def require_success(proc: dict[str, Any], label: str) -> None:
    require(proc["error"] is None, f"{label}: invocation error: {proc['error']}")
    require(proc["exit"] == 0,
            f"{label}: expected exit 0, got {proc['exit']}; stderr={compact_bytes(proc['stderr'])!r}")
    require(proc["stdout"] == b"", f"{label}: stdout was not empty")
    require(proc["stderr"] == b"", f"{label}: stderr was not empty")


def require_diagnostic(proc: dict[str, Any], label: str, exit_code: int,
                       diagnostic_class: str) -> dict[str, Any]:
    diagnostic = one_diagnostic(proc)
    require(proc["exit"] == exit_code,
            f"{label}: expected exit {exit_code}, got {proc['exit']}")
    require(diagnostic["class"] == diagnostic_class,
            f"{label}: expected diagnostic {diagnostic_class}, got {diagnostic['class']}")
    if diagnostic_class.startswith("output-"):
        require(isinstance(diagnostic.get("path"), str) and os.path.isabs(diagnostic.get("path")),
                f"{label}: output diagnostic does not carry an absolute path")
    require(proc["stdout"] == b"", f"{label}: stdout was not empty")
    return diagnostic


def probe_case_alias_and_reserved(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "case-alias")
    content_before = snapshot_tree(site / "content")
    case_alias_visible = ascii_case_alias_visible(site / "content")
    refused_spellings = ["content"]
    if case_alias_visible:
        refused_spellings.extend(("CONTENT", "CONTENT/new"))
    for spelling in refused_spellings:
        proc = run_pubend(wrapper, "build", site, "--out", spelling)
        require_diagnostic(proc, spelling, 2, "output-forbidden")
        require_tree_unchanged(content_before, site / "content", spelling)

    distinct_case_output_built = False
    if not case_alias_visible:
        proc = run_pubend(wrapper, "build", site, "--out", "CONTENT")
        require_success(proc, "case-distinct CONTENT output")
        require((site / "CONTENT" / "index.html").is_file(),
                "case-distinct CONTENT output did not contain index.html")
        distinct_case_output_built = True
        require_publication_siblings_absent(site, "case-distinct CONTENT output", "CONTENT")

    reserved_spellings = []
    for suffix in PUBLICATION_SUFFIXES:
        reserved_spellings.extend(("x" + suffix, "x" + suffix.upper()))
    for spelling in reserved_spellings:
        proc = run_pubend(wrapper, "build", site, "--out", spelling)
        require_diagnostic(proc, spelling, 2, "output-forbidden")
    require_tree_unchanged(content_before, site / "content", "case-alias content")
    allowed = {"content"}
    if distinct_case_output_built:
        allowed.add("CONTENT")
    unexpected = {child.name for child in site.iterdir()} - allowed
    require(not unexpected, f"case-alias/reserved probe created publication paths: {sorted(unexpected)!r}")
    return {
        "case_alias_visible_on_filesystem": case_alias_visible,
        "refused_spellings": tuple(refused_spellings),
        "distinct_case_output_built": distinct_case_output_built,
        "reserved_spellings": len(reserved_spellings),
        "content_tree_exactly_preserved": True,
    }


def probe_canonical_outside_symlink(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "outside-symlink")
    outside = root / "outside-victim"
    outside.mkdir()
    (outside / "sentinel.txt").write_text("victim\n", encoding="utf-8")
    outside_before = snapshot_tree(outside)
    (site / "link").symlink_to(outside, target_is_directory=True)
    link_before = snapshot_tree(site / "link")
    proc = run_pubend(wrapper, "build", site, "--out", "link/dist")
    require_diagnostic(proc, "symlinked outside output", 2, "output-outside-site")
    require_tree_unchanged(outside_before, outside, "outside victim")
    require_tree_unchanged(link_before, site / "link", "outside output symlink")
    require(not os.path.lexists(outside / "dist"), "outside dist was created")
    return {"victim_tree_exactly_preserved": True, "outside_dist_created": False}


def probe_positive_wrapper_determinism(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "positive")
    site_alias = root / "positive-root-alias"
    site_alias.symlink_to(site, target_is_directory=True)
    first = run_pubend(wrapper, "build", site_alias)
    require_success(first, "first positive build through symlinked site root")
    first_copy = root / "positive-first-copy"
    shutil.copytree(site / "dist", first_copy, symlinks=True)
    second = run_pubend(wrapper, "build", site_alias)
    require_success(second, "second positive build through symlinked site root")
    differences = check_output.compare_trees(str(first_copy), str(site / "dist"))
    require(not differences, f"repeated output trees differ: {differences!r}")
    require(not os.path.lexists(site / "dist" / ".pubend-incomplete-stage"), "stage marker remained")
    require(not os.path.lexists(site / "dist" / ".pubend-backup-owner"), "backup marker remained")
    require_publication_siblings_absent(site, "positive build")

    order_file = root / "positive-order.json"
    order_file.write_text(json.dumps(["index"], separators=(",", ":")) + "\n", encoding="utf-8")
    audit = subprocess.run(
        [sys.executable, str(AUDITOR), str(site / "dist"), "--expect-order-json", str(order_file)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=build_environment(),
        timeout=30,
        check=False,
    )
    require(audit.returncode == 0 and audit.stdout == b"" and audit.stderr == b"",
            f"output audit failed: exit={audit.returncode}, stdout={audit.stdout!r}, stderr={audit.stderr!r}")
    return {
        "first_exit": first["exit"],
        "second_exit": second["exit"],
        "tree_differences": len(differences),
        "audit_exit": audit.returncode,
        "publication_siblings_absent": True,
        "site_root_invoked_through_symlink": True,
    }


def probe_backup_recovery_foreign_stage(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "backup-recovery")
    backup = site / "dist.pubend-previous"
    backup.mkdir()
    (backup / "old.html").write_text("recovered-prior-output\n", encoding="utf-8")
    (backup / ".pubend-backup-owner").write_text(BACKUP_OWNER, encoding="utf-8")
    foreign_stage = site / "dist.pubend-stage"
    foreign_stage.mkdir()
    (foreign_stage / "sentinel.txt").write_text("foreign-stage\n", encoding="utf-8")
    foreign_before = snapshot_tree(foreign_stage)

    proc = run_pubend(wrapper, "build", site)
    require_diagnostic(proc, "backup recovery/foreign stage", 3, "output-stage-invalid")
    require((site / "dist" / "old.html").read_bytes() == b"recovered-prior-output\n",
            "owned backup was not restored")
    require(not os.path.lexists(site / "dist" / ".pubend-backup-owner"),
            "backup ownership marker remained in restored output")
    require(not os.path.lexists(backup), "backup path still exists after restoration")
    require_tree_unchanged(foreign_before, foreign_stage, "foreign stage")
    require_lock_absent(site, "backup recovery/foreign stage")
    return {
        "backup_restored": True,
        "foreign_stage_tree_exactly_preserved": True,
        "owned_lock_released": True,
    }


def probe_markerless_foreign_backup(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "foreign-backup")
    backup = site / "dist.pubend-previous"
    backup.mkdir()
    (backup / "sentinel.txt").write_text("foreign-backup\n", encoding="utf-8")
    backup_before = snapshot_tree(backup)
    proc = run_pubend(wrapper, "build", site)
    require_diagnostic(proc, "markerless foreign backup", 3, "output-backup-invalid")
    require_tree_unchanged(backup_before, backup, "foreign backup")
    require(not os.path.lexists(site / "dist"), "foreign backup was restored")
    require(not os.path.lexists(site / "dist.pubend-stage"), "foreign backup failure left a stage")
    require_lock_absent(site, "markerless foreign backup")
    return {
        "foreign_backup_tree_exactly_preserved": True,
        "restored": False,
        "owned_lock_released": True,
    }


def probe_symlinked_output(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "symlink-output")
    target = site / "target"
    target.mkdir()
    (target / "sentinel.txt").write_text("target\n", encoding="utf-8")
    (site / "dist").symlink_to(target, target_is_directory=True)
    symlink_before = snapshot_tree(site / "dist")
    target_before = snapshot_tree(target)
    proc = run_pubend(wrapper, "build", site)
    require_diagnostic(proc, "symlinked output", 3, "output-symlink")
    require_tree_unchanged(symlink_before, site / "dist", "symlinked output")
    require_tree_unchanged(target_before, target, "symlink target")
    require_lock_absent(site, "symlinked output")
    return {"symlink_exactly_preserved": True, "target_tree_exactly_preserved": True}


def probe_existing_lock(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "existing-lock")
    lock = site / "dist.pubend-lock"
    lock.mkdir()
    (lock / "sentinel.txt").write_text("lock-owner\n", encoding="utf-8")
    lock_before = snapshot_tree(lock)
    proc = run_pubend(wrapper, "build", site)
    require_diagnostic(proc, "existing lock", 3, "output-lock-exists")
    require_tree_unchanged(lock_before, lock, "existing lock")
    require(not os.path.lexists(site / "dist"), "output was created despite existing lock")
    require(not os.path.lexists(site / "dist.pubend-stage"), "existing-lock failure left a stage")
    return {"lock_tree_exactly_preserved": True, "output_created": False}


def probe_backup_conflict(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "backup-conflict")
    dist = site / "dist"
    backup = site / "dist.pubend-previous"
    dist.mkdir()
    backup.mkdir()
    (dist / "current.txt").write_text("current-output\n", encoding="utf-8")
    (backup / "prior.txt").write_text("prior-output\n", encoding="utf-8")
    dist_before = snapshot_tree(dist)
    backup_before = snapshot_tree(backup)
    proc = run_pubend(wrapper, "build", site)
    require_diagnostic(proc, "output/backup conflict", 3, "output-backup-conflict")
    require_tree_unchanged(dist_before, dist, "conflicting output")
    require_tree_unchanged(backup_before, backup, "conflicting backup")
    require(not os.path.lexists(site / "dist.pubend-stage"), "backup conflict left a stage")
    require_lock_absent(site, "output/backup conflict")
    return {
        "output_tree_exactly_preserved": True,
        "backup_tree_exactly_preserved": True,
        "owned_lock_released": True,
    }


def probe_output_path_collision(root: Path, wrapper: Path) -> dict[str, Any]:
    site = root / "sites" / "output-collision"
    (site / "content" / "a.html").mkdir(parents=True)
    (site / "content" / "a.md").write_text("# A\n", encoding="utf-8")
    (site / "content" / "a.html" / "x.md").write_text("# X\n", encoding="utf-8")
    (site / "dist").mkdir()
    (site / "dist" / "prior.txt").write_text("prior-output\n", encoding="utf-8")
    dist_before = snapshot_tree(site / "dist")
    proc = run_pubend(wrapper, "build", site)
    require_diagnostic(proc, "output path collision", 3, "output-path-collision")
    require_tree_unchanged(dist_before, site / "dist", "prior output")
    require(not os.path.lexists(site / "dist.pubend-stage"), "collision left a stage")
    require(not os.path.lexists(site / "dist.pubend-previous"), "collision left a backup")
    require_lock_absent(site, "output path collision")
    return {"prior_output_tree_exactly_preserved": True, "stage_left": False, "backup_left": False}


def fixed_output_collision_probe(root: Path, wrapper: Path, name: str,
                                 collision_directory: str) -> dict[str, Any]:
    site = root / "sites" / name
    collision_root = site / "content" / collision_directory
    collision_root.mkdir(parents=True)
    (collision_root / "x.md").write_text("# X\n", encoding="utf-8")
    proc = run_pubend(wrapper, "build", site)
    require_diagnostic(proc, name, 3, "output-path-collision")
    remaining = [sibling for sibling in ("dist", *publication_sibling_names()) if os.path.lexists(site / sibling)]
    require(not remaining, f"{name}: collision left publication paths: {remaining!r}")
    return {"collision_directory": collision_directory, "publication_paths_created": False}


def probe_manifest_collision(root: Path, wrapper: Path) -> dict[str, Any]:
    return fixed_output_collision_probe(
        root, wrapper, "manifest-collision", "_pubend/manifest.json"
    )


def probe_stage_marker_collision(root: Path, wrapper: Path) -> dict[str, Any]:
    return fixed_output_collision_probe(
        root, wrapper, "stage-marker-collision", ".pubend-incomplete-stage"
    )


def probe_backup_marker_collision(root: Path, wrapper: Path) -> dict[str, Any]:
    return fixed_output_collision_probe(
        root, wrapper, "backup-marker-collision", ".pubend-backup-owner"
    )


def fixed_output_case_alias_probe(root: Path, wrapper: Path, name: str,
                                  collision_directory: str) -> dict[str, Any]:
    site = root / "sites" / name
    collision_root = site / "content" / collision_directory
    collision_root.mkdir(parents=True)
    (collision_root / "x.md").write_text("# X\n", encoding="utf-8")
    case_alias = ascii_case_alias_visible(site / "content")
    proc = run_pubend(wrapper, "build", site)
    if case_alias:
        require_diagnostic(proc, name, 3, "output-path-collision")
        require(not os.path.lexists(site / "dist"), f"{name}: case-alias collision created output")
    else:
        require_success(proc, name)
        require((site / "dist" / collision_directory / "x.html").is_file(),
                f"{name}: distinct-case output page is missing")
    require_publication_siblings_absent(site, name)
    return {
        "collision_directory": collision_directory,
        "case_alias_visible_on_filesystem": case_alias,
        "refused_as_collision": case_alias,
        "distinct_case_output_built": not case_alias,
    }


def probe_manifest_case_alias(root: Path, wrapper: Path) -> dict[str, Any]:
    return fixed_output_case_alias_probe(
        root, wrapper, "manifest-case-alias", "_PUBEND/MANIFEST.JSON"
    )


def probe_stage_marker_case_alias(root: Path, wrapper: Path) -> dict[str, Any]:
    return fixed_output_case_alias_probe(
        root, wrapper, "stage-marker-case-alias", ".PUBEND-INCOMPLETE-STAGE"
    )


def probe_backup_marker_case_alias(root: Path, wrapper: Path) -> dict[str, Any]:
    return fixed_output_case_alias_probe(
        root, wrapper, "backup-marker-case-alias", ".PUBEND-BACKUP-OWNER"
    )


def probe_fixed_directory_case_alias(root: Path, wrapper: Path) -> dict[str, Any]:
    site = root / "sites" / "fixed-directory-case-alias"
    page_dir = site / "content" / "_PUBEND"
    page_dir.mkdir(parents=True)
    (page_dir / "x.md").write_text("# X\n", encoding="utf-8")
    case_alias = ascii_case_alias_visible(site / "content")
    proc = run_pubend(wrapper, "build", site)
    if case_alias:
        require_diagnostic(proc, "fixed directory case alias", 3, "output-path-collision")
        require(not os.path.lexists(site / "dist"), "directory case-alias collision created output")
    else:
        require_success(proc, "fixed directory case alias")
        require((site / "dist" / "_PUBEND" / "x.html").is_file(),
                "case-distinct _PUBEND output page is missing")
        require((site / "dist" / "_pubend" / "manifest.json").is_file(),
                "case-distinct lowercase manifest is missing")
    require_publication_siblings_absent(site, "fixed directory case alias")
    return {
        "case_alias_visible_on_filesystem": case_alias,
        "refused_as_collision": case_alias,
        "distinct_case_output_built": not case_alias,
    }


def probe_marker_owned_stage_cleanup(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "owned-stage")
    stage = site / "dist.pubend-stage"
    stage.mkdir()
    (stage / "stale.txt").write_text("stale\n", encoding="utf-8")
    (stage / ".pubend-incomplete-stage").write_text(STAGE_OWNER, encoding="utf-8")
    proc = run_pubend(wrapper, "build", site)
    require_success(proc, "marker-owned stage recovery")
    require(not os.path.lexists(stage), "marker-owned stale stage remained")
    require((site / "dist" / "index.html").is_file(), "output after stage cleanup is missing index.html")
    require(not os.path.lexists(site / "dist.pubend-lock"), "successful stage cleanup left a lock")
    require(not os.path.lexists(site / "dist.pubend-previous"), "successful stage cleanup left a backup")
    return {"stage_removed": True, "output_exists": True, "publication_siblings_absent": True}


def probe_content_symlink_alias(root: Path, wrapper: Path) -> dict[str, Any]:
    site = make_site(root, "content-symlink-alias")
    content_before = snapshot_tree(site / "content")
    (site / "content-alias").symlink_to(site / "content", target_is_directory=True)
    alias_before = snapshot_tree(site / "content-alias")
    proc = run_pubend(wrapper, "build", site, "--out", "content-alias/new")
    require_diagnostic(proc, "content symlink alias", 2, "output-forbidden")
    require_tree_unchanged(content_before, site / "content", "content symlink alias")
    require_tree_unchanged(alias_before, site / "content-alias", "content alias symlink")
    return {"content_tree_exactly_preserved": True, "alias_symlink_exactly_preserved": True}


def probe_symlinked_wrapper_usage(root: Path, wrapper: Path) -> dict[str, Any]:
    proc = run_pubend(wrapper)
    diagnostic = require_diagnostic(proc, "symlinked wrapper usage", 2, "usage-error")
    return {"diagnostic": diagnostic["class"], "wrapper_chain": "relative->absolute"}


ProbeFunction = Callable[[Path, Path], dict[str, Any]]

PROBES: tuple[tuple[str, ProbeFunction], ...] = (
    ("case-alias-and-reserved-output-names", probe_case_alias_and_reserved),
    ("canonical-outside-symlink-refused", probe_canonical_outside_symlink),
    ("positive-wrapper-determinism", probe_positive_wrapper_determinism),
    ("backup-recovery-then-foreign-stage-refused", probe_backup_recovery_foreign_stage),
    ("markerless-foreign-backup-preserved", probe_markerless_foreign_backup),
    ("symlinked-output-refused", probe_symlinked_output),
    ("existing-lock-preserved", probe_existing_lock),
    ("output-backup-conflict-preserved", probe_backup_conflict),
    ("output-path-collision-refused", probe_output_path_collision),
    ("fixed-manifest-collision-refused", probe_manifest_collision),
    ("fixed-stage-marker-collision-refused", probe_stage_marker_collision),
    ("fixed-backup-marker-collision-refused", probe_backup_marker_collision),
    ("fixed-manifest-case-alias", probe_manifest_case_alias),
    ("fixed-stage-marker-case-alias", probe_stage_marker_case_alias),
    ("fixed-backup-marker-case-alias", probe_backup_marker_case_alias),
    ("fixed-directory-case-alias", probe_fixed_directory_case_alias),
    ("marker-owned-stage-cleanup", probe_marker_owned_stage_cleanup),
    ("content-symlink-alias-refused", probe_content_symlink_alias),
    ("symlinked-wrapper-structured-cli", probe_symlinked_wrapper_usage),
)


def execute_probe(name: str, function: ProbeFunction, root: Path, wrapper: Path) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        details = function(root, wrapper)
        return {
            "type": "boundary-probe",
            "probe": name,
            "ok": True,
            "details": details,
            "errors": [],
            "runtime_ms": round((time.perf_counter() - started) * 1000),
        }
    except Exception as error:
        return {
            "type": "boundary-probe",
            "probe": name,
            "ok": False,
            "details": {},
            "errors": [str(error)],
            "runtime_ms": round((time.perf_counter() - started) * 1000),
        }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="run pubend CLI filesystem-boundary regression probes")
    parser.add_argument("--jobs", type=int, default=4, help="parallel probe workers (default 4)")
    parser.add_argument("--workspace-root", default="/tmp",
                        help="parent directory for the temporary workspace (default /tmp)")
    parser.add_argument("--keep-tmp", action="store_true", help="retain the temporary workspace")
    args = parser.parse_args(argv)
    if args.jobs < 1:
        print("error: --jobs must be at least 1", file=sys.stderr)
        return 2

    workspace = Path(tempfile.mkdtemp(prefix="pubend-cli-boundary-", dir=args.workspace_root))
    wrapper_dir = workspace / "bin"
    wrapper_dir.mkdir()
    try:
        wrapper_absolute = wrapper_dir / "pubend-absolute"
        wrapper_absolute.symlink_to(CLI)
        wrapper = wrapper_dir / "pubend"
        wrapper.symlink_to(wrapper_absolute.name)
    except BaseException:
        shutil.rmtree(workspace)
        raise

    started = time.perf_counter()
    rows: dict[str, dict[str, Any]] = {}
    harness_error = None
    try:
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=args.jobs,
            thread_name_prefix="pubend-cli-boundary",
        ) as pool:
            futures = {
                pool.submit(execute_probe, name, function, workspace, wrapper): name
                for name, function in PROBES
            }
            for future in concurrent.futures.as_completed(futures):
                rows[futures[future]] = future.result()
    except BaseException as error:
        harness_error = f"harness execution failed: {error}"

    ordered_rows = []
    for name, _function in PROBES:
        ordered_rows.append(rows.get(name, {
            "type": "boundary-probe",
            "probe": name,
            "ok": False,
            "details": {},
            "errors": ["probe did not produce a result"],
            "runtime_ms": 0,
        }))
    for row in ordered_rows:
        print(json.dumps(row, ensure_ascii=True, separators=(",", ":")))
    passed = sum(1 for row in ordered_rows if row["ok"])
    if harness_error is not None:
        passed = 0

    cleanup_error = None
    if not args.keep_tmp:
        try:
            shutil.rmtree(workspace)
        except Exception as error:
            cleanup_error = f"workspace cleanup failed: {error}"
        if cleanup_error is None and os.path.lexists(workspace):
            cleanup_error = "workspace cleanup left entries behind"

    ok = passed == len(ordered_rows) and cleanup_error is None and harness_error is None
    summary = {
        "type": "summary",
        "ok": ok,
        "passed": passed,
        "total": len(ordered_rows),
        "jobs": args.jobs,
        "runtime_ms": round((time.perf_counter() - started) * 1000),
        "workspace_retained": str(workspace) if args.keep_tmp or cleanup_error is not None else None,
        "cleanup_error": cleanup_error,
        "harness_error": harness_error,
    }
    print(json.dumps(summary, ensure_ascii=True, separators=(",", ":")))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
