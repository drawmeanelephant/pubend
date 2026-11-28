#!/usr/bin/env python3
"""Differential native-host/reference-oracle parity verification for pubend.

The product host is the native Bend binary reached through ./pubend.  The
JavaScript implementation in tools/pubend.mjs is retained only as the reference
oracle.  This lane runs both over copied positive corpus sites, copied negative
fixtures, and the CLI boundary probe matrix at the same paths, resetting each
fixture between hosts so path-dependent stderr bytes are comparable.  All
writable trees live under a temporary /tmp workspace.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import hashlib
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

import verify_cli_boundary  # noqa: E402
import verify_end_to_end  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
NATIVE_CLI = ROOT / "pubend"
ORACLE_CLI = ROOT / "tools" / "pubend.mjs"
DIRECT_TIMEOUT_SECONDS = 180
RECORDER_TIMEOUT_SECONDS = 170


class ParityHarnessError(RuntimeError):
    pass


class Host:
    def __init__(self, name: str, command: tuple[str, ...]):
        self.name = name
        self.command = command


class Invocation:
    def __init__(
        self,
        exit_code: int | None,
        stdout: bytes,
        stderr: bytes,
        runtime_ms: int,
        error: str | None = None,
    ):
        self.exit_code = exit_code
        self.stdout = stdout
        self.stderr = stderr
        self.runtime_ms = runtime_ms
        self.error = error


def json_line(obj: dict[str, Any]) -> None:
    print(json.dumps(obj, ensure_ascii=True, separators=(",", ":")))


def compact_bytes(data: bytes, limit: int = 240) -> str:
    text = data.decode("utf-8", errors="replace")
    if len(text) <= limit:
        return text
    return f"{text[:limit]}...<truncated; {len(text)} characters total>"


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_environment() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("PUBEND_COMPILE_MJS", None)
    env["BEND_NO_TELEMETRY"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def oracle_host() -> Host:
    configured = os.environ.get("PUBEND_ORACLE_NODE")
    node = configured if configured else shutil.which("node")
    if not node:
        raise ParityHarnessError(
            "JavaScript reference oracle requires a node executable; "
            "set PUBEND_ORACLE_NODE or install Node.js for the migration harness"
        )
    return Host("oracle", (node, str(ORACLE_CLI)))


def hosts() -> tuple[Host, Host]:
    return Host("native", (str(NATIVE_CLI),)), oracle_host()


def normalize_timeout_output(value: bytes | str | None) -> bytes:
    if value is None:
        return b""
    if isinstance(value, bytes):
        return value
    return value.encode("utf-8", errors="replace")


def run_direct(host: Host, argv: list[str]) -> Invocation:
    started = time.perf_counter()
    try:
        completed = subprocess.run(
            [*host.command, *argv],
            cwd=ROOT,
            env=build_environment(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=DIRECT_TIMEOUT_SECONDS,
            check=False,
        )
        return Invocation(
            completed.returncode,
            completed.stdout,
            completed.stderr,
            round((time.perf_counter() - started) * 1000),
        )
    except subprocess.TimeoutExpired as error:
        return Invocation(
            None,
            normalize_timeout_output(error.stdout),
            normalize_timeout_output(error.stderr),
            round((time.perf_counter() - started) * 1000),
            f"timed out after {DIRECT_TIMEOUT_SECONDS} seconds",
        )
    except OSError as error:
        return Invocation(
            None,
            b"",
            b"",
            round((time.perf_counter() - started) * 1000),
            f"could not invoke host: {error}",
        )


def reset_copy(source: Path, destination: Path) -> None:
    if os.path.lexists(destination):
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)


def invocation_summary(invocation: Invocation) -> dict[str, Any]:
    return {
        "exit": invocation.exit_code,
        "stdout_bytes": len(invocation.stdout),
        "stdout_sha256": sha256_hex(invocation.stdout),
        "stderr_bytes": len(invocation.stderr),
        "stderr_sha256": sha256_hex(invocation.stderr),
        "runtime_ms": invocation.runtime_ms,
        "error": invocation.error,
    }


def byte_difference(label: str, native: bytes, oracle: bytes) -> str:
    shared = min(len(native), len(oracle))
    first = next((index for index in range(shared) if native[index] != oracle[index]), shared)
    return (
        f"{label} differ at byte {first}: "
        f"native len={len(native)} sha256={sha256_hex(native)} prefix={native[:160]!r}; "
        f"oracle len={len(oracle)} sha256={sha256_hex(oracle)} prefix={oracle[:160]!r}"
    )


def compare_invocations(native: Invocation, oracle: Invocation) -> list[str]:
    errors: list[str] = []
    if native.error != oracle.error:
        errors.append(f"invocation transport errors differ: native={native.error!r}, oracle={oracle.error!r}")
    if native.exit_code != oracle.exit_code:
        errors.append(f"exit codes differ: native={native.exit_code!r}, oracle={oracle.exit_code!r}")
    if native.stdout != oracle.stdout:
        errors.append(byte_difference("stdout bytes", native.stdout, oracle.stdout))
    if native.stderr != oracle.stderr:
        errors.append(byte_difference("stderr bytes", native.stderr, oracle.stderr))
    return errors


def compare_trees(native_tree: verify_cli_boundary.TreeSnapshot | None,
                  oracle_tree: verify_cli_boundary.TreeSnapshot | None) -> list[str]:
    if native_tree == oracle_tree:
        return []
    return [
        "post-invocation trees differ: "
        + verify_cli_boundary.first_tree_difference(native_tree, oracle_tree)
    ]


def execute_direct_case(
    host: Host,
    source: Path,
    site: Path,
    out_name: str | None,
) -> tuple[Invocation, verify_cli_boundary.TreeSnapshot | None]:
    reset_copy(source, site)
    argv = ["build", str(site)]
    if out_name is not None:
        argv.extend(["--out", out_name])
    invocation = run_direct(host, argv)
    tree = verify_cli_boundary.snapshot_tree(site)
    return invocation, tree


def exception_row(row_type: str, label: str, error: Exception) -> dict[str, Any]:
    return {
        "type": row_type,
        "case": label,
        "ok": False,
        "errors": [f"parity harness case failed: {error}"],
    }


def compare_direct_case(
    row_type: str,
    label: str,
    source: Path,
    workspace: Path,
    out_name: str | None,
    expect_success: bool,
) -> dict[str, Any]:
    native, oracle = hosts()
    safe_label = label.replace("/", "__")
    site = workspace / "direct" / row_type / safe_label / "site"
    errors: list[str] = []

    native_invocation, native_tree = execute_direct_case(native, source, site, out_name)
    oracle_invocation, oracle_tree = execute_direct_case(oracle, source, site, out_name)

    errors.extend(compare_invocations(native_invocation, oracle_invocation))
    errors.extend(compare_trees(native_tree, oracle_tree))

    if expect_success:
        for host_name, invocation in (("native", native_invocation), ("oracle", oracle_invocation)):
            if invocation.error is not None or invocation.exit_code != 0:
                errors.append(
                    f"{host_name} positive case did not succeed: exit={invocation.exit_code!r}, "
                    f"error={invocation.error!r}, stderr={compact_bytes(invocation.stderr)!r}"
                )
    else:
        for host_name, invocation in (("native", native_invocation), ("oracle", oracle_invocation)):
            if invocation.error is not None or invocation.exit_code in (None, 0):
                errors.append(
                    f"{host_name} negative case did not fail as a build failure: "
                    f"exit={invocation.exit_code!r}, error={invocation.error!r}"
                )

    entry_count = len(native_tree or {})
    return {
        "type": row_type,
        "case": label,
        "ok": not errors,
        "comparison": "same input path; reset fixture; exact exit/stdout/stderr bytes plus exact post-run tree",
        "native": invocation_summary(native_invocation),
        "oracle": invocation_summary(oracle_invocation),
        "post_run_tree_entries": entry_count,
        "errors": errors,
    }


RECORDER_TEMPLATE = r'''#!/usr/bin/env python3
import base64
import json
import os
import subprocess
import sys
import time

TARGET = __TARGET__
LOGDIR = __LOGDIR__
TIMEOUT = __TIMEOUT__

os.makedirs(LOGDIR, exist_ok=True)
argv = sys.argv[1:]
exit_code = None
stdout = b""
stderr = b""
transport_error = None
started_ns = time.time_ns()
try:
    proc = subprocess.run(
        TARGET + argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=TIMEOUT,
        check=False,
    )
    exit_code = proc.returncode
    stdout = proc.stdout
    stderr = proc.stderr
except subprocess.TimeoutExpired as error:
    transport_error = f"timed out after {TIMEOUT} seconds"
    stdout = error.stdout if isinstance(error.stdout, bytes) else b""
    stderr = error.stderr if isinstance(error.stderr, bytes) else b""
except OSError as error:
    transport_error = str(error)

sys.stdout.buffer.write(stdout)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(stderr)
sys.stderr.buffer.flush()

record = {
    "argv": argv,
    "exit": exit_code,
    "stdout": base64.b64encode(stdout).decode("ascii"),
    "stderr": base64.b64encode(stderr).decode("ascii"),
    "error": transport_error,
}
name = f"{started_ns:020d}-{os.getpid()}.json"
temporary = os.path.join(LOGDIR, "." + name + ".tmp")
final = os.path.join(LOGDIR, name)
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, final)
sys.exit(exit_code if exit_code is not None else 3)
'''


def write_recorder(path: Path, host: Host, logdir: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    script = RECORDER_TEMPLATE.replace("__TARGET__", json.dumps(list(host.command)))
    script = script.replace("__LOGDIR__", json.dumps(str(logdir)))
    script = script.replace("__TIMEOUT__", str(RECORDER_TIMEOUT_SECONDS))
    path.write_text(script, encoding="utf-8")
    path.chmod(0o755)


def read_records(logdir: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    paths = sorted(
        (path for path in logdir.glob("*.json") if path.is_file()),
        key=lambda path: int(path.name.split("-", 1)[0]),
    )
    for path in paths:
        raw = json.loads(path.read_text(encoding="utf-8"))
        records.append({
            "argv": raw["argv"],
            "exit": raw["exit"],
            "stdout": base64.b64decode(raw["stdout"]),
            "stderr": base64.b64decode(raw["stderr"]),
            "error": raw["error"],
        })
    return records


def records_summary(records: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "invocations": len(records),
        "exits": [record["exit"] for record in records],
        "stdout_sha256": [sha256_hex(record["stdout"]) for record in records],
        "stderr_sha256": [sha256_hex(record["stderr"]) for record in records],
    }


def compare_record_bytes(label: str, native: bytes, oracle: bytes) -> str | None:
    if native == oracle:
        return None
    return byte_difference(label, native, oracle)


def compare_records(native_records: list[dict[str, Any]],
                    oracle_records: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    if len(native_records) != len(oracle_records):
        errors.append(
            f"boundary invocation counts differ: native={len(native_records)}, oracle={len(oracle_records)}"
        )
    for index, (native, oracle) in enumerate(zip(native_records, oracle_records)):
        if native["argv"] != oracle["argv"]:
            errors.append(f"invocation {index} argv differ: native={native['argv']!r}, oracle={oracle['argv']!r}")
        if native["exit"] != oracle["exit"]:
            errors.append(f"invocation {index} exits differ: native={native['exit']!r}, oracle={oracle['exit']!r}")
        if native["error"] != oracle["error"]:
            errors.append(
                f"invocation {index} transport errors differ: "
                f"native={native['error']!r}, oracle={oracle['error']!r}"
            )
        for stream in ("stdout", "stderr"):
            mismatch = compare_record_bytes(
                f"invocation {index} {stream} bytes", native[stream], oracle[stream]
            )
            if mismatch is not None:
                errors.append(mismatch)
    return errors


def execute_boundary_host(
    host: Host,
    function: verify_cli_boundary.ProbeFunction,
    root: Path,
    recorder_base: Path,
) -> dict[str, Any]:
    if os.path.lexists(root):
        shutil.rmtree(root)
    root.mkdir(parents=True)

    host_base = recorder_base / host.name
    if os.path.lexists(host_base):
        shutil.rmtree(host_base)
    logdir = host_base / "records"
    recorder = host_base / "pubend-recorder"
    write_recorder(recorder, host, logdir)

    probe_error = None
    details: dict[str, Any] = {}
    started = time.perf_counter()
    try:
        details = function(root, recorder)
    except Exception as error:  # probe failure is evidence, not a harness crash
        probe_error = str(error)
    runtime_ms = round((time.perf_counter() - started) * 1000)

    return {
        "probe_ok": probe_error is None,
        "probe_error": probe_error,
        "details": details,
        "records": read_records(logdir),
        "tree": verify_cli_boundary.snapshot_tree(root),
        "runtime_ms": runtime_ms,
    }


def compare_boundary_probe(
    name: str,
    function: verify_cli_boundary.ProbeFunction,
    workspace: Path,
) -> dict[str, Any]:
    native, oracle = hosts()
    probe_base = workspace / "boundary" / name
    root = probe_base / "work"
    recorder_base = probe_base / "recorders"
    errors: list[str] = []

    native_result = execute_boundary_host(native, function, root, recorder_base)
    oracle_result = execute_boundary_host(oracle, function, root, recorder_base)

    for host_name, result in (("native", native_result), ("oracle", oracle_result)):
        if not result["probe_ok"]:
            errors.append(f"{host_name} boundary probe failed: {result['probe_error']}")

    errors.extend(compare_records(native_result["records"], oracle_result["records"]))
    errors.extend(compare_trees(native_result["tree"], oracle_result["tree"]))
    if native_result["details"] != oracle_result["details"]:
        errors.append(
            "boundary probe detail objects differ: "
            f"native={native_result['details']!r}, oracle={oracle_result['details']!r}"
        )

    return {
        "type": "boundary-parity",
        "case": name,
        "ok": not errors,
        "comparison": (
            "same probe path; reset workspace; exact ordered exit/stdout/stderr bytes "
            "plus exact post-probe tree"
        ),
        "native": {
            "probe_ok": native_result["probe_ok"],
            "probe_error": native_result["probe_error"],
            "runtime_ms": native_result["runtime_ms"],
            "records": records_summary(native_result["records"]),
        },
        "oracle": {
            "probe_ok": oracle_result["probe_ok"],
            "probe_error": oracle_result["probe_error"],
            "runtime_ms": oracle_result["runtime_ms"],
            "records": records_summary(oracle_result["records"]),
        },
        "errors": errors,
    }


def run_parallel_rows(
    descriptions: list[tuple[str, Callable[[], dict[str, Any]]]],
    jobs: int,
) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}

    def guarded(label: str, function: Callable[[], dict[str, Any]]) -> dict[str, Any]:
        try:
            return function()
        except Exception as error:
            return exception_row("harness-case", label, error)

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=jobs,
        thread_name_prefix="pubend-host-parity",
    ) as pool:
        futures = {
            pool.submit(guarded, label, function): label
            for label, function in descriptions
        }
        for future in concurrent.futures.as_completed(futures):
            rows[futures[future]] = future.result()
    return rows


def positive_and_negative_rows(workspace: Path, jobs: int) -> list[dict[str, Any]]:
    positive_sites = verify_end_to_end.positive_catalog()
    negative_fixtures, negative_selection = verify_end_to_end.negative_catalog()
    descriptions: list[tuple[str, Callable[[], dict[str, Any]]]] = []

    for site in positive_sites:
        label = f"positive:{site.label}"
        descriptions.append((
            label,
            lambda site=site: compare_direct_case(
                "positive-parity", site.label, site.source, workspace, "out", True
            ),
        ))
    for fixture in negative_fixtures:
        label = f"negative:{fixture.name}"
        descriptions.append((
            label,
            lambda fixture=fixture: compare_direct_case(
                "negative-parity", fixture.name, fixture.source, workspace, None, False
            ),
        ))

    unordered = run_parallel_rows(descriptions, jobs)
    rows = []
    for label, _function in descriptions:
        rows.append(unordered.get(label, {
            "type": "harness-case",
            "case": label,
            "ok": False,
            "errors": ["case did not produce a result"],
        }))
    return rows


def boundary_rows(workspace: Path, jobs: int) -> list[dict[str, Any]]:
    descriptions: list[tuple[str, Callable[[], dict[str, Any]]]] = [
        (
            name,
            lambda name=name, function=function: compare_boundary_probe(name, function, workspace),
        )
        for name, function in verify_cli_boundary.PROBES
    ]
    unordered = run_parallel_rows(descriptions, jobs)
    return [
        unordered.get(name, {
            "type": "boundary-parity",
            "case": name,
            "ok": False,
            "errors": ["boundary probe did not produce a result"],
        })
        for name, _function in verify_cli_boundary.PROBES
    ]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="compare native pubend host behavior byte-for-byte with the JavaScript reference oracle",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=min(4, os.cpu_count() or 1),
        help="maximum concurrent host-pair cases (default: min(4, cpu count))",
    )
    parser.add_argument("--keep-tmp", action="store_true", help="retain the temporary workspace")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.jobs < 1:
        print("error: --jobs must be at least 1", file=sys.stderr)
        return 2

    total_started = time.perf_counter()
    workspace = Path(tempfile.mkdtemp(prefix="pubend-host-parity-", dir="/tmp"))
    workspace_retained = args.keep_tmp
    rows: list[dict[str, Any]] = []

    try:
        positive_sites = verify_end_to_end.positive_catalog()
        negative_fixtures, negative_selection = verify_end_to_end.negative_catalog()
        json_line({
            "type": "start",
            "positive_cases": len(positive_sites),
            "negative_cases": len(negative_fixtures),
            "negative_selection": negative_selection,
            "boundary_cases": len(verify_cli_boundary.PROBES),
            "jobs": args.jobs,
            "workspace": str(workspace),
        })

        direct_started = time.perf_counter()
        direct_rows = positive_and_negative_rows(workspace, args.jobs)
        direct_runtime_ms = round((time.perf_counter() - direct_started) * 1000)
        for row in direct_rows:
            rows.append(row)
            json_line(row)

        boundary_started = time.perf_counter()
        probes = boundary_rows(workspace, args.jobs)
        boundary_runtime_ms = round((time.perf_counter() - boundary_started) * 1000)
        for row in probes:
            rows.append(row)
            json_line(row)

        direct_passed = sum(1 for row in direct_rows if row["ok"])
        boundary_passed = sum(1 for row in probes if row["ok"])
        ok = all(row["ok"] for row in rows)
        json_line({
            "type": "summary",
            "ok": ok,
            "direct_cases_total": len(direct_rows),
            "direct_cases_passed": direct_passed,
            "positive_cases_total": len(positive_sites),
            "negative_cases_total": len(negative_fixtures),
            "boundary_cases_total": len(probes),
            "boundary_cases_passed": boundary_passed,
            "jobs": args.jobs,
            "direct_runtime_ms": direct_runtime_ms,
            "boundary_runtime_ms": boundary_runtime_ms,
            "runtime_ms": round((time.perf_counter() - total_started) * 1000),
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
