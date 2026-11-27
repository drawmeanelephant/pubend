#!/usr/bin/env python3
"""check_output.py — dependency-free auditor for pubend output trees.

Usage:
    python3 tools/check_output.py TREE [--expect-order-json FILE | --expect-order-file FILE | --no-order-check] [--compare OTHER_TREE]

Exit codes:
    0  the audit and requested comparison passed
    1  one or more artifact/audit violations were found
    2  command-line usage error or host filesystem/encoding error

Diagnostics are written to stdout as compact JSON lines.  Each line has the
stable key order `class`, `path`, `line`, `column`, `target`, `message`;
unavailable scalar fields are JSON null.  `path` is output-tree-relative for
artifact findings.  Lines are sorted class-first, then by the remaining fields,
so output does not depend on host directory enumeration order.  A valid audit
writes nothing.  Usage and host errors are plain text on stderr.

Audit scope:
  * recursively scans TREE deterministically, without following symlinks;
  * rejects symlinked and non-regular entries inside the artifact tree;
  * rejects foreign regular files: in v0 only regular `*.html` files and the
    exact `_pubend/manifest.json` path are allowed.  Empty directories are not
    significant;
  * reads only emitted artifact bytes, never markdown sources;
  * requires every regular `*.html` file to be strict UTF-8, to start with the
    fixed byte prefix
    `<!doctype html>\\n<html lang="en">\\n<head><meta charset="utf-8"><title>`,
    and to use the fixed shell serialization shape: exact title/head closure
    followed by exact `<body>`, the generated `<nav class="pubend-nav">` first
    in body, that nav closed immediately before the generated `<main>`, and the
    exact final close `</main></body>\\n</html>\\n` at end of file;
  * uses `html.parser` to extract every `href` and `src` attribute, plus the
    generated nav's href/text hooks;
  * validates generated nav parent/child hrefs as canonical generated URL
    paths: relative lexical `.html` paths without a leading `./`, literal `?`
    or `#`, literal space/non-ASCII text, malformed or noncanonical percent
    triplets, or noncanonical dot/empty segments.  After strict percent
    decoding they must resolve to regular emitted `.html` files;
  * treats RFC3986 ASCII schemes as external; empty, anchor-only, absolute,
    non-`.md`, and non-`.html` targets are passthrough;
  * rejects relative `.md` targets as `artifact-internal-md-target`;
  * for relative `.html` targets, rejects a literal query, malformed or
    invalid-UTF8 percent encoding in the path portion, and normalized targets
    that do not name a regular emitted `.html` file.  Fragments are not
    validated;
  * audits `_pubend/manifest.json` as exact UTF-8 JSON: object key order,
    version, page entry schema/order, output-relative `.html` paths, lowercase
    SHA-256 digests of exact HTML bytes, duplicate/missing/extra page entries,
    canonical two-space JSON formatting with exactly one trailing newline, no
    additional keys such as timestamps, and no absolute paths;
  * emitted-page order cannot be inferred from an output tree alone.  A
    conformance audit therefore requires `--expect-order-json` or legacy
    `--expect-order-file`; without one it reports
    `artifact-manifest-order-unchecked` unless the caller explicitly waives
    order evidence with `--no-order-check`.  The waiver is not conformance
    evidence;
  * when `--expect-order-json` is supplied, reads strict JSON whose top-level
    value is an array and whose elements are all strings, then compares that
    sequence exactly with the manifest page id sequence;
  * when legacy `--expect-order-file` is supplied, compares newline-delimited
    ids in that file exactly with the manifest page id sequence;
  * when `--compare` is supplied, recursively compares the complete
    entry-path/entry-kind shape of both trees, including empty directories,
    plus exact bytes for every shared regular file.  All differing entries are
    reported in deterministic path order; byte differences report the first
    differing byte offset.

Stable diagnostic classes are `artifact-symlink`, `artifact-nonregular-file`,
`artifact-foreign-file`, `artifact-invalid-utf8`, `artifact-shell-prefix`,
`artifact-shell-structure`, `artifact-html-parse`, `artifact-nav-target`,
`artifact-internal-md-target`, `artifact-internal-query`,
`artifact-invalid-percent-target`, `artifact-unresolved-html-target`,
`artifact-manifest-missing`, `artifact-manifest-invalid-utf8`,
`artifact-manifest-invalid-json`, `artifact-manifest-duplicate-key`,
`artifact-manifest-format`, `artifact-manifest-schema`,
`artifact-manifest-key-order`, `artifact-manifest-version`,
`artifact-manifest-path`, `artifact-manifest-sha256`,
`artifact-manifest-id-path-mismatch`, `artifact-manifest-duplicate-entry`,
`artifact-manifest-missing-entry`, `artifact-manifest-extra-entry`,
`artifact-manifest-order-mismatch`, `artifact-manifest-order-unchecked`,
`artifact-compare-missing-file`, `artifact-compare-extra-file`,
`artifact-compare-missing-entry`, `artifact-compare-extra-entry`,
`artifact-compare-type-mismatch`, and `artifact-compare-bytes-differ`.

Reusable public functions include `scan_tree`, `parse_html`,
`extract_html_targets`, `extract_nav_hooks`, `classify_emitted_target`,
`audit_tree`, `compare_trees`, and `compare_scanned_trees`.

Documented limits:
  * `html.parser` is permissive; this is target/nav extraction, not validation
    of the entire HTML grammar.  The shell audit checks the fixed compiler
    serialization shape using exact structural boundary text plus a permissive
    direct-body-child sequence audit.  It is not an HTML5 parser proof of
    browser DOM semantics.  Well-formed markdown-produced fragment content
    inside `<main>` is tolerated, even when it uses the same tag spellings;
    because raw HTML is engine-owned and can imitate or prematurely close
    browser elements, the audit cannot prove how every malformed raw-HTML
    fragment is interpreted by a browser.  Complete removal, reordering, wrong
    body opening, wrong head closure, wrong final close, and extra direct body
    elements are caught.
  * Nav target validation applies to anchors extracted from the structurally
    identified generated nav.  The nav interior is not otherwise schema
    validated against the graph, because output bytes alone cannot prove which
    parent/children entries compilation should have produced.
  * Fragment existence/syntax is deliberately unchecked.  External and
    passthrough targets are deliberately unchecked.
  * Attribute line/column positions are the start position of the containing
    tag; `html.parser` does not expose per-attribute positions.
  * Artifact conformance itself does not treat empty directories as
    significant.  `--compare` is deliberately stricter exact-tree evidence: it
    compares entry paths and kinds, so empty-directory presence is significant
    there.  Symlink targets, permission bits, ownership, timestamps, and other
    metadata are not compared; symlinks are never followed.
  * A symlinked TREE or OTHER_TREE root is a host/usage refusal (exit 2);
    symlinks inside a tree are artifact violations (exit 1).
  * Legacy newline-delimited expected-id files cannot represent ids containing
    a literal U+000A newline.  Other bytes are not stripped or normalized.  Use
    `--expect-order-json` for unambiguous order evidence.
  * Manifest JSON nesting beyond the Python parser/auditor recursion limit is
    reported as a schema violation; the valid manifest schema is shallow.
  * The filesystem is not immutable during the audit.  Read/stat races and
    permission failures are host errors, not artifact findings.
"""

import argparse
import hashlib
import html.parser
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from typing import Any

SHELL_PREFIX = b'<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><title>'
SHELL_PREFIX_TEXT = SHELL_PREFIX.decode("ascii")
SHELL_HEAD_BODY = '</title></head>\n<body>'
SHELL_NAV_OPEN = '<nav class="pubend-nav">'
SHELL_NAV_MAIN_BOUNDARY = '</nav><main>'
SHELL_CLOSE = '</main></body>\n</html>\n'
MANIFEST_PATH = "_pubend/manifest.json"
RFC3986_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
LOWER_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
HEX_DIGITS = frozenset("0123456789abcdefABCDEF")
UPPER_HEX_DIGITS = frozenset("0123456789ABCDEF")
GENERATED_PATH_LITERAL_CHARS = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
)
VOID_ELEMENTS = frozenset({
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
})


# ---------------------------------------------------------------------------
# diagnostics and host errors


@dataclass(frozen=True)
class Diagnostic:
    cls: str
    path: str | None
    line: int | None
    column: int | None
    target: str | None
    message: str

    def sort_key(self) -> tuple[Any, ...]:
        return (
            self.cls,
            "" if self.path is None else self.path,
            -1 if self.line is None else self.line,
            -1 if self.column is None else self.column,
            "" if self.target is None else self.target,
            self.message,
        )

    def json_line(self) -> str:
        obj = {
            "class": self.cls,
            "path": self.path,
            "line": self.line,
            "column": self.column,
            "target": self.target,
            "message": self.message,
        }
        return json.dumps(obj, ensure_ascii=True, separators=(",", ":"))


def diag(cls: str, path: str | None = None, line: int | None = None,
         column: int | None = None, target: str | None = None,
         message: str = "") -> Diagnostic:
    return Diagnostic(cls, path, line, column, target, message)


def sort_diagnostics(diagnostics: list[Diagnostic] | tuple[Diagnostic, ...]) -> list[Diagnostic]:
    return sorted(diagnostics, key=lambda d: d.sort_key())


class HostError(Exception):
    """A usage/host failure: the audit boundary itself cannot be read."""

    def __init__(self, path: str, message: str):
        super().__init__(f"{path}: {message}")
        self.path = path
        self.message = message


def host_error(path: str, action: str, error: OSError) -> HostError:
    detail = error.strerror or str(error)
    return HostError(path, f"cannot {action}: {detail}")


# ---------------------------------------------------------------------------
# deterministic tree scan


@dataclass(frozen=True)
class TreeEntry:
    path: str       # output-tree-relative, using forward slashes
    full_path: str  # host path used only at the audit boundary
    kind: str       # file, directory, symlink, other


@dataclass(frozen=True)
class TreeScan:
    root: str
    entries: tuple[TreeEntry, ...]

    def entries_of_kind(self, kind: str) -> tuple[TreeEntry, ...]:
        return tuple(entry for entry in self.entries if entry.kind == kind)

    def files_by_path(self) -> dict[str, TreeEntry]:
        return {entry.path: entry for entry in self.entries if entry.kind == "file"}

    def kinds_by_path(self) -> dict[str, str]:
        return {entry.path: entry.kind for entry in self.entries}


def scan_tree(root: str) -> TreeScan:
    """Scan a tree deterministically without following symlinks.

    Entry names within each directory are sorted by Python's Unicode string
    ordering after host filesystem decoding.  Child directories are then
    traversed depth-first in the same order.  The root itself must be a real,
    non-symlinked directory; violations inside the tree are represented as
    entries so the caller can diagnose them.
    """
    root_path = os.path.normpath(os.fsdecode(os.fspath(root)))
    try:
        if os.path.islink(root_path):
            raise HostError(root_path, "artifact tree root is a symlink")
        root_stat = os.stat(root_path, follow_symlinks=False)
    except OSError as error:
        raise host_error(root_path, "inspect artifact tree root", error) from error
    if not stat.S_ISDIR(root_stat.st_mode):
        raise HostError(root_path, "artifact tree root is not a directory")

    records: list[TreeEntry] = []
    pending: list[tuple[str, str]] = [(root_path, "")]
    while pending:
        directory_full, directory_rel = pending.pop()
        try:
            with os.scandir(directory_full) as iterator:
                children = list(iterator)
        except OSError as error:
            raise host_error(directory_full, "scan directory", error) from error
        children.sort(key=lambda entry: entry.name)

        child_directories: list[tuple[str, str]] = []
        for child in children:
            child_rel = child.name if directory_rel == "" else f"{directory_rel}/{child.name}"
            child_full = os.path.join(directory_full, child.name)
            try:
                if child.is_symlink():
                    kind = "symlink"
                elif child.is_dir(follow_symlinks=False):
                    kind = "directory"
                elif child.is_file(follow_symlinks=False):
                    kind = "file"
                else:
                    kind = "other"
            except OSError as error:
                raise host_error(child_full, "inspect entry", error) from error
            records.append(TreeEntry(child_rel, child_full, kind))
            if kind == "directory":
                child_directories.append((child_full, child_rel))

        for child_directory in reversed(child_directories):
            pending.append(child_directory)

    return TreeScan(root_path, tuple(records))


def read_bytes(path: str) -> bytes:
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError as error:
        raise host_error(path, "read file", error) from error


# ---------------------------------------------------------------------------
# HTML extraction hooks


@dataclass(frozen=True)
class HtmlTarget:
    tag: str
    attribute: str
    value: str
    line: int
    column: int


@dataclass(frozen=True)
class NavLink:
    href: str | None
    text: str
    line: int
    column: int


@dataclass(frozen=True)
class NavHooks:
    parent: tuple[NavLink, ...]
    children: tuple[NavLink, ...]


@dataclass(frozen=True)
class _Frame:
    tag: str
    nav_root: bool = False
    child_root: bool = False


def _class_tokens(attrs: list[tuple[str, str | None]]) -> frozenset[str]:
    for name, value in attrs:
        if name == "class" and value is not None:
            return frozenset(part for part in re.split(r"[\t\n\f\r ]+", value) if part)
    return frozenset()


class ArtifactHTMLParser(html.parser.HTMLParser):
    """Permissive HTML target and pubend-nav extractor.

    The parser records every href/src attribute in document order.  In each
    `nav` element carrying class `pubend-nav`, anchors outside the
    `ul.pubend-children` subtree are exposed as parent hooks and anchors inside
    it as child hooks.  Anchor text is concatenated character data exactly as
    decoded by html.parser; no whitespace normalization is applied.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.targets: list[HtmlTarget] = []
        self.parent_links: list[NavLink] = []
        self.child_links: list[NavLink] = []
        self._frames: list[_Frame] = []
        self._active_anchor: dict[str, Any] | None = None

    def _in_nav(self) -> bool:
        return any(frame.nav_root for frame in self._frames)

    def _in_child_list(self) -> bool:
        return any(frame.child_root for frame in self._frames)

    def _record_targets(self, tag: str, attrs: list[tuple[str, str | None]],
                        line: int, column: int) -> None:
        for name, value in attrs:
            if name in ("href", "src"):
                self.targets.append(HtmlTarget(
                    tag=tag,
                    attribute=name,
                    value="" if value is None else value,
                    line=line,
                    column=column,
                ))

    def _begin_anchor(self, attrs: list[tuple[str, str | None]], in_children: bool,
                      line: int, column: int) -> None:
        if self._active_anchor is not None:
            return
        href: str | None = None
        for name, value in attrs:
            if name == "href":
                href = "" if value is None else value
                break
        self._active_anchor = {
            "href": href,
            "text": [],
            "line": line,
            "column": column,
            "in_children": in_children,
        }

    def _finish_anchor(self) -> None:
        active = self._active_anchor
        if active is None:
            return
        link = NavLink(
            href=active["href"],
            text="".join(active["text"]),
            line=active["line"],
            column=active["column"],
        )
        if active["in_children"]:
            self.child_links.append(link)
        else:
            self.parent_links.append(link)
        self._active_anchor = None

    def _handle_start(self, tag: str, attrs: list[tuple[str, str | None]],
                      self_closing: bool) -> None:
        line, zero_column = self.getpos()
        column = zero_column + 1
        self._record_targets(tag, attrs, line, column)

        in_nav = self._in_nav()
        in_children = self._in_child_list()
        tokens = _class_tokens(attrs)
        nav_root = (
            tag == "nav"
            and not in_nav
            and "pubend-nav" in tokens
        )
        child_root = (
            tag == "ul"
            and in_nav
            and not in_children
            and "pubend-children" in tokens
        )
        if in_nav and tag == "a":
            self._begin_anchor(attrs, in_children, line, column)

        if not self_closing and tag not in VOID_ELEMENTS:
            self._frames.append(_Frame(tag, nav_root=nav_root, child_root=child_root))

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self._handle_start(tag, attrs, self_closing=False)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self._handle_start(tag, attrs, self_closing=True)
        if tag == "a":
            self._finish_anchor()

    def handle_endtag(self, tag: str) -> None:
        if tag == "a":
            self._finish_anchor()
        for index in range(len(self._frames) - 1, -1, -1):
            if self._frames[index].tag == tag:
                del self._frames[index:]
                return

    def handle_data(self, data: str) -> None:
        if self._active_anchor is not None:
            self._active_anchor["text"].append(data)

    def close(self) -> None:
        super().close()
        self._finish_anchor()

    def nav_hooks(self) -> NavHooks:
        return NavHooks(parent=tuple(self.parent_links), children=tuple(self.child_links))


def parse_html(text: str) -> tuple[tuple[HtmlTarget, ...], NavHooks]:
    """Parse HTML text once and return `(href_src_targets, nav_hooks)`.

    The returned nav hooks are fragment-local: they describe pubend-nav markup
    in the exact text supplied here.  Whole-document evidence callers should
    use `extract_nav_hooks`, which first selects the fixed generated shell nav
    region and therefore ignores nav-like markup inside `<main>`.
    """
    parser = ArtifactHTMLParser()
    parser.feed(text)
    parser.close()
    return tuple(parser.targets), parser.nav_hooks()


def extract_html_targets(text: str) -> tuple[HtmlTarget, ...]:
    """Extract every href/src attribute from HTML text in document order."""
    targets, _ = parse_html(text)
    return targets


def extract_nav_hooks(text: str) -> NavHooks:
    """Extract parent/child hooks only from the fixed generated shell nav.

    Nav-like markup in `<main>` is engine-owned content, not generated-nav
    evidence.  If the fixed shell nav region cannot be identified, there are
    no extractable generated-nav hooks.
    """
    _shell_diagnostics, structure = audit_shell_structure("<extract-nav-hooks>", text)
    if structure is None:
        return NavHooks(parent=(), children=())
    return parse_html(structure.nav_text)[1]


# ---------------------------------------------------------------------------
# emitted-target classification and resolution


def split_target_delimiters(target: str) -> tuple[str, bool]:
    """Return (path portion, has literal query) after literal fragment split.

    The first literal `#` starts the unvalidated fragment.  A literal `?` in
    the remaining pre-fragment text is a query delimiter.  Encoded delimiters
    are not special at this stage because percent decoding happens later.
    """
    before_fragment = target.split("#", 1)[0]
    if "?" in before_fragment:
        return before_fragment.split("?", 1)[0], True
    return before_fragment, False


def classify_emitted_target(target: str) -> str:
    """Classify an emitted HTML target as external/passthrough/internal-md/internal-html."""
    if RFC3986_SCHEME_RE.match(target):
        return "external"
    if target == "" or target.startswith("#") or target.startswith("/"):
        return "passthrough"
    path, _ = split_target_delimiters(target)
    if path.endswith(".md"):
        return "internal-md"
    if path.endswith(".html"):
        return "internal-html"
    return "passthrough"


def percent_decode_path(path: str) -> tuple[str | None, str | None]:
    """Percent-decode a path portion exactly once as strict UTF-8.

    Non-percent characters contribute their UTF-8 bytes.  Returns
    `(decoded, None)`, `(None, 'malformed')`, or `(None, 'invalid-utf8')`.
    """
    raw = bytearray()
    index = 0
    while index < len(path):
        char = path[index]
        if char == "%":
            if index + 2 >= len(path):
                return None, "malformed"
            digits = path[index + 1:index + 3]
            if len(digits) != 2 or any(digit not in HEX_DIGITS for digit in digits):
                return None, "malformed"
            raw.append(int(digits, 16))
            index += 3
            continue
        try:
            raw.extend(char.encode("utf-8"))
        except UnicodeEncodeError:
            return None, "invalid-utf8"
        index += 1
    try:
        return raw.decode("utf-8", errors="strict"), None
    except UnicodeDecodeError:
        return None, "invalid-utf8"


def normalize_dot_segments(path: str) -> str | None:
    """Normalize empty/dot segments lexically; None means escape above root."""
    stack: list[str] = []
    for segment in path.split("/"):
        if segment == "" or segment == ".":
            continue
        if segment == "..":
            if not stack:
                return None
            stack.pop()
        else:
            stack.append(segment)
    return "/".join(stack)


def resolve_output_html_path(containing_file: str, decoded_path: str) -> str | None:
    containing_directory = (
        containing_file.rsplit("/", 1)[0] if "/" in containing_file else ""
    )
    joined = f"{containing_directory}/{decoded_path}" if containing_directory else decoded_path
    return normalize_dot_segments(joined)


def audit_emitted_target(containing_file: str, target: HtmlTarget,
                         html_files: frozenset[str]) -> list[Diagnostic]:
    classification = classify_emitted_target(target.value)
    if classification in ("external", "passthrough"):
        return []

    location = {
        "path": containing_file,
        "line": target.line,
        "column": target.column,
        "target": target.value,
    }
    bearing = f"<{target.tag} {target.attribute}>"

    if classification == "internal-md":
        return [diag(
            "artifact-internal-md-target",
            **location,
            message=f"relative .md target remains in emitted HTML ({bearing})",
        )]

    path, has_query = split_target_delimiters(target.value)
    if has_query:
        return [diag(
            "artifact-internal-query",
            **location,
            message=f"relative .html target carries a literal query ({bearing})",
        )]

    decoded, percent_error = percent_decode_path(path)
    if percent_error is not None:
        detail = (
            "has a malformed percent triplet"
            if percent_error == "malformed"
            else "has percent-encoded bytes that are not valid UTF-8"
        )
        return [diag(
            "artifact-invalid-percent-target",
            **location,
            message=f"relative .html target {detail} ({bearing})",
        )]

    assert decoded is not None
    normalized = resolve_output_html_path(containing_file, decoded)
    if normalized is None:
        message = f"relative .html target normalizes above the output root ({bearing})"
    elif normalized not in html_files:
        message = (
            f"relative .html target normalizes to {normalized!r}, "
            f"which is not an emitted regular .html file ({bearing})"
        )
    else:
        return []
    return [diag("artifact-unresolved-html-target", **location, message=message)]


@dataclass(frozen=True)
class ShellStructure:
    nav_start: int
    nav_end: int
    nav_text: str


def line_column_at_index(text: str, index: int) -> tuple[int, int]:
    """Return 1-based line/column for a character index, clamped to the text."""
    clamped = max(0, min(index, len(text)))
    before = text[:clamped]
    line = before.count("\n") + 1
    last_newline = before.rfind("\n")
    column = clamped + 1 if last_newline < 0 else clamped - last_newline
    return line, column


def audit_shell_structure(relative_path: str,
                          text: str) -> tuple[list[Diagnostic], ShellStructure | None]:
    """Audit the fixed v0 shell serialization shape.

    The compiler shell is deliberately fixed, so exact boundary text is a
    stronger check than counting tags in the permissive HTML parser.  Variable
    title, nav, and markdown-fragment bytes live between those boundaries.
    """
    diagnostics: list[Diagnostic] = []
    if not text.startswith(SHELL_PREFIX_TEXT):
        return diagnostics, None

    head_body_index = text.find(SHELL_HEAD_BODY, len(SHELL_PREFIX_TEXT))
    if head_body_index < 0:
        line, column = line_column_at_index(text, len(text))
        diagnostics.append(diag(
            "artifact-shell-structure",
            path=relative_path,
            line=line,
            column=column,
            message=(
                "head does not close as exactly </title></head> followed by "
                "a newline and exact <body> opening"
            ),
        ))
        return diagnostics, None

    body_start = head_body_index + len(SHELL_HEAD_BODY)
    if not text.startswith(SHELL_NAV_OPEN, body_start):
        line, column = line_column_at_index(text, body_start)
        diagnostics.append(diag(
            "artifact-shell-structure",
            path=relative_path,
            line=line,
            column=column,
            message=(
                "body does not immediately open the required generated "
                '<nav class="pubend-nav">'
            ),
        ))
        return diagnostics, None

    nav_start = body_start
    nav_inner_start = nav_start + len(SHELL_NAV_OPEN)
    boundary_index = text.find(SHELL_NAV_MAIN_BOUNDARY, nav_inner_start)
    if boundary_index < 0:
        line, column = line_column_at_index(text, nav_start)
        diagnostics.append(diag(
            "artifact-shell-structure",
            path=relative_path,
            line=line,
            column=column,
            message=(
                "generated nav is not closed immediately before the required "
                "generated <main> opening"
            ),
        ))
        return diagnostics, None

    nav_inner = text[nav_inner_start:boundary_index]
    if any(token in nav_inner for token in ("<nav", "</nav", "<main", "</main")):
        line, column = line_column_at_index(text, nav_inner_start)
        diagnostics.append(diag(
            "artifact-shell-structure",
            path=relative_path,
            line=line,
            column=column,
            message="generated nav interior contains nested shell or main structure",
        ))

    nav_end = boundary_index + len("</nav>")
    structure = ShellStructure(
        nav_start=nav_start,
        nav_end=nav_end,
        nav_text=text[nav_start:nav_end],
    )

    main_inner_start = boundary_index + len(SHELL_NAV_MAIN_BOUNDARY)
    close_start = len(text) - len(SHELL_CLOSE)
    if not text.endswith(SHELL_CLOSE) or close_start < main_inner_start:
        line, column = line_column_at_index(text, len(text))
        diagnostics.append(diag(
            "artifact-shell-structure",
            path=relative_path,
            line=line,
            column=column,
            message=(
                "HTML bytes do not end with the exact shell close "
                "</main></body>\n</html>\n"
            ),
        ))
    return diagnostics, structure


@dataclass(frozen=True)
class BodyChildElement:
    tag: str
    line: int
    column: int


class BodyShellParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.body_children: list[BodyChildElement] = []
        self._frames: list[str] = []

    def _handle_start(self, tag: str, self_closing: bool) -> None:
        line, zero_column = self.getpos()
        if self._frames and self._frames[-1] == "body":
            self.body_children.append(BodyChildElement(tag, line, zero_column + 1))
        if not self_closing and tag not in VOID_ELEMENTS:
            self._frames.append(tag)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self._handle_start(tag, self_closing=False)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self._handle_start(tag, self_closing=True)

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self._frames) - 1, -1, -1):
            if self._frames[index] == tag:
                del self._frames[index:]
                return


def body_child_elements(text: str) -> tuple[BodyChildElement, ...]:
    parser = BodyShellParser()
    parser.feed(text)
    parser.close()
    return tuple(parser.body_children)


def audit_body_child_sequence(relative_path: str, text: str) -> list[Diagnostic]:
    children = body_child_elements(text)
    if [child.tag for child in children] == ["nav", "main"]:
        return []

    if not children:
        line, column = line_column_at_index(text, len(text))
    elif children[0].tag != "nav":
        line, column = children[0].line, children[0].column
    elif len(children) == 1:
        line, column = line_column_at_index(text, len(text))
    elif children[1].tag != "main":
        line, column = children[1].line, children[1].column
    else:
        line, column = children[2].line, children[2].column
    actual = " ".join(child.tag for child in children) if children else "none"
    return [diag(
        "artifact-shell-structure",
        path=relative_path,
        line=line,
        column=column,
        message=(
            f"body direct element sequence is {actual}, expected exactly "
            "nav followed by main"
        ),
    )]


def generated_nav_form_problem(href: str) -> str | None:
    """Return the first canonical generated-path form violation, if any."""
    if href == "":
        return "is empty"
    if href.startswith("./"):
        return "has a leading ./"
    if href.startswith("/"):
        return "is absolute rather than output-relative"

    index = 0
    while index < len(href):
        char = href[index]
        if char == "%":
            if index + 2 >= len(href):
                return "has a malformed percent triplet"
            digits = href[index + 1:index + 3]
            if len(digits) != 2 or any(digit not in UPPER_HEX_DIGITS for digit in digits):
                return "has a malformed or non-uppercase percent triplet"
            byte = int(digits, 16)
            if byte < 128 and chr(byte) in GENERATED_PATH_LITERAL_CHARS:
                return "percent-encodes a character canonical generated output leaves literal"
            index += 3
            continue
        if char in GENERATED_PATH_LITERAL_CHARS:
            index += 1
            continue
        if char in "?#":
            return "contains a literal query or fragment delimiter"
        if char == " ":
            return "contains a literal space"
        if ord(char) > 127:
            return "contains literal non-ASCII text"
        return "contains a character canonical generated output percent-encodes"
    return None


def generated_nav_shape_problem(href: str) -> str | None:
    """Return a lexical dot/empty-segment violation in a generated nav path."""
    segments = href.split("/")
    if any(segment == "" for segment in segments):
        return "contains an empty path segment"
    seen_name = False
    for segment in segments:
        if segment == "..":
            if seen_name:
                return "contains a non-leading .. segment"
        elif segment == ".":
            return "contains a . path segment"
        else:
            seen_name = True
    return None


def audit_nav_target(containing_file: str, href: str | None, line: int, column: int,
                     html_files: frozenset[str]) -> list[Diagnostic]:
    """Audit one generated nav parent/child href as canonical output URL text."""
    location = {
        "path": containing_file,
        "line": line,
        "column": column,
        "target": href,
    }
    if href is None:
        return [diag(
            "artifact-nav-target",
            **location,
            message="generated nav anchor has no href attribute",
        )]

    problem = generated_nav_form_problem(href)
    if problem is None:
        problem = generated_nav_shape_problem(href)
    if problem is not None:
        return [diag(
            "artifact-nav-target",
            **location,
            message=f"generated nav target {problem}",
        )]

    decoded, percent_error = percent_decode_path(href)
    if percent_error is not None:
        detail = (
            "has a malformed percent triplet"
            if percent_error == "malformed"
            else "has percent-encoded bytes that are not valid UTF-8"
        )
        return [diag(
            "artifact-nav-target",
            **location,
            message=f"generated nav target {detail}",
        )]

    assert decoded is not None
    normalized = resolve_output_html_path(containing_file, decoded)
    if normalized is None:
        message = "generated nav target normalizes above the output root"
    elif normalized not in html_files:
        message = (
            f"generated nav target normalizes to {normalized!r}, "
            "which is not an emitted regular .html file"
        )
    else:
        return []
    return [diag("artifact-nav-target", **location, message=message)]


def audit_generated_nav(relative_path: str, text: str, structure: ShellStructure,
                        hooks: NavHooks, html_files: frozenset[str]) -> list[Diagnostic]:
    """Audit parent/child href hooks extracted from the generated nav slice."""
    base_line, base_column = line_column_at_index(text, structure.nav_start)
    diagnostics: list[Diagnostic] = []
    for link in (*hooks.parent, *hooks.children):
        line = base_line + link.line - 1
        column = base_column + link.column - 1 if link.line == 1 else link.column
        diagnostics.extend(audit_nav_target(
            relative_path,
            link.href,
            line,
            column,
            html_files,
        ))
    return diagnostics


def audit_html_bytes(relative_path: str, data: bytes,
                     html_files: frozenset[str]) -> tuple[list[Diagnostic], str]:
    """Audit one HTML byte string.  Returns (diagnostics, sha256_hex)."""
    digest = hashlib.sha256(data).hexdigest()
    diagnostics: list[Diagnostic] = []

    if not data.startswith(SHELL_PREFIX):
        diagnostics.append(diag(
            "artifact-shell-prefix",
            path=relative_path,
            message="HTML bytes do not start with the fixed v0 shell prefix",
        ))

    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        diagnostics.append(diag(
            "artifact-invalid-utf8",
            path=relative_path,
            message=f"HTML bytes are not strict UTF-8 at byte offset {error.start}",
        ))
        return diagnostics, digest

    shell_diagnostics, shell_structure = audit_shell_structure(relative_path, text)
    diagnostics.extend(shell_diagnostics)
    if shell_structure is not None:
        try:
            diagnostics.extend(audit_body_child_sequence(relative_path, text))
        except Exception as error:
            diagnostics.append(diag(
                "artifact-html-parse",
                path=relative_path,
                message=f"html.parser body structure extraction failed: {error}",
            ))

    try:
        targets, _nav_hooks = parse_html(text)
        generated_nav_hooks = (
            parse_html(shell_structure.nav_text)[1]
            if shell_structure is not None
            else None
        )
    except Exception as error:  # html.parser is permissive, but never let extraction crash the audit.
        diagnostics.append(diag(
            "artifact-html-parse",
            path=relative_path,
            message=f"html.parser extraction failed: {error}",
        ))
        return diagnostics, digest

    for target in targets:
        diagnostics.extend(audit_emitted_target(relative_path, target, html_files))
    if shell_structure is not None and generated_nav_hooks is not None:
        diagnostics.extend(audit_generated_nav(
            relative_path,
            text,
            shell_structure,
            generated_nav_hooks,
            html_files,
        ))
    return diagnostics, digest


# ---------------------------------------------------------------------------
# manifest JSON auditing


@dataclass(frozen=True)
class JsonObject:
    pairs: tuple[tuple[str, Any], ...]


def _json_object(pairs: list[tuple[str, Any]]) -> JsonObject:
    return JsonObject(tuple(pairs))


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-standard JSON constant {value}")


def json_keys(obj: JsonObject) -> list[str]:
    return [key for key, _value in obj.pairs]


def json_first(obj: JsonObject, key: str) -> Any:
    for candidate, value in obj.pairs:
        if candidate == key:
            return value
    return None


def duplicate_json_keys(value: Any, location: str = "$") -> list[tuple[str, str]]:
    """Return (location, duplicate-key) pairs in deterministic traversal order."""
    found: list[tuple[str, str]] = []
    if isinstance(value, JsonObject):
        counts: dict[str, int] = {}
        for key, _ in value.pairs:
            counts[key] = counts.get(key, 0) + 1
        for key, count in counts.items():
            if count > 1:
                found.append((location, key))
        for key, child in value.pairs:
            child_location = f"{location}.{key}"
            found.extend(duplicate_json_keys(child, child_location))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(duplicate_json_keys(child, f"{location}[{index}]"))
    return found


def json_has_surrogate(value: Any) -> bool:
    if isinstance(value, str):
        return any(0xD800 <= ord(char) <= 0xDFFF for char in value)
    if isinstance(value, JsonObject):
        return any(
            json_has_surrogate(key) or json_has_surrogate(child)
            for key, child in value.pairs
        )
    if isinstance(value, list):
        return any(json_has_surrogate(child) for child in value)
    return False


def canonical_json_text(value: Any, level: int = 0) -> str:
    """Serialize parsed JSON in the same two-space shape as json.dumps(indent=2).

    Object pairs are serialized in input order, including duplicate keys, so
    whitespace/escaping can be audited independently from key-order and
    duplicate-key schema violations.  The returned text has no trailing newline.
    """
    if isinstance(value, JsonObject):
        if not value.pairs:
            return "{}"
        child_indent = "  " * (level + 1)
        closing_indent = "  " * level
        members = [
            child_indent
            + json.dumps(key, ensure_ascii=False)
            + ": "
            + canonical_json_text(child, level + 1)
            for key, child in value.pairs
        ]
        return "{\n" + ",\n".join(members) + "\n" + closing_indent + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        child_indent = "  " * (level + 1)
        closing_indent = "  " * level
        items = [
            child_indent + canonical_json_text(child, level + 1)
            for child in value
        ]
        return "[\n" + ",\n".join(items) + "\n" + closing_indent + "]"
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def validate_exact_keys(obj: JsonObject, expected: list[str], context: str,
                        diagnostics: list[Diagnostic]) -> None:
    keys = json_keys(obj)
    missing = [key for key in expected if key not in keys]
    extra = [key for key in keys if key not in expected]
    if missing or extra:
        pieces = []
        if missing:
            pieces.append("missing " + ",".join(missing))
        if extra:
            pieces.append("extra " + ",".join(extra))
        diagnostics.append(diag(
            "artifact-manifest-schema",
            path=MANIFEST_PATH,
            message=f"{context} key set differs from schema ({'; '.join(pieces)})",
        ))
    elif keys != expected:
        diagnostics.append(diag(
            "artifact-manifest-key-order",
            path=MANIFEST_PATH,
            message=f"{context} keys are {keys!r}, expected {expected!r}",
        ))


def manifest_path_problem(path: str) -> str | None:
    if path == "":
        return "path is empty"
    if "\0" in path:
        return "path contains NUL"
    if path.startswith("/") or path.startswith("\\"):
        return "path is absolute"
    if re.match(r"^[A-Za-z]:[/\\]", path):
        return "path is a Windows drive-absolute path"
    if not path.endswith(".html"):
        return "path does not end in lowercase .html"
    segments = path.split("/")
    if any(segment in ("", ".", "..") for segment in segments):
        return "path is not a canonical output-relative path"
    return None


def duplicate_values(values: list[str]) -> list[str]:
    counts: dict[str, int] = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    return sorted(value for value, count in counts.items() if count > 1)


@dataclass(frozen=True)
class ManifestAudit:
    diagnostics: tuple[Diagnostic, ...]
    ids: tuple[str, ...] | None


def audit_manifest(scan: TreeScan, html_digests: dict[str, str]) -> ManifestAudit:
    diagnostics: list[Diagnostic] = []
    files = scan.files_by_path()
    entry = files.get(MANIFEST_PATH)
    if entry is None:
        diagnostics.append(diag(
            "artifact-manifest-missing",
            path=MANIFEST_PATH,
            message="manifest is not a regular file in the output tree",
        ))
        return ManifestAudit(tuple(diagnostics), None)

    data = read_bytes(entry.full_path)
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        diagnostics.append(diag(
            "artifact-manifest-invalid-utf8",
            path=MANIFEST_PATH,
            message=f"manifest bytes are not strict UTF-8 at byte offset {error.start}",
        ))
        return ManifestAudit(tuple(diagnostics), None)

    try:
        parsed = json.loads(
            text,
            object_pairs_hook=_json_object,
            parse_constant=_reject_json_constant,
        )
    except json.JSONDecodeError as error:
        diagnostics.append(diag(
            "artifact-manifest-invalid-json",
            path=MANIFEST_PATH,
            line=error.lineno,
            column=error.colno,
            message=f"manifest is not valid JSON: {error.msg}",
        ))
        return ManifestAudit(tuple(diagnostics), None)
    except ValueError as error:
        diagnostics.append(diag(
            "artifact-manifest-invalid-json",
            path=MANIFEST_PATH,
            message=f"manifest is not valid JSON: {error}",
        ))
        return ManifestAudit(tuple(diagnostics), None)
    except RecursionError:
        diagnostics.append(diag(
            "artifact-manifest-schema",
            path=MANIFEST_PATH,
            message="manifest JSON nesting exceeds the auditor recursion limit",
        ))
        return ManifestAudit(tuple(diagnostics), None)

    try:
        duplicate_keys = duplicate_json_keys(parsed)
        has_surrogate = json_has_surrogate(parsed)
    except RecursionError:
        diagnostics.append(diag(
            "artifact-manifest-schema",
            path=MANIFEST_PATH,
            message="manifest JSON nesting exceeds the auditor recursion limit",
        ))
        return ManifestAudit(tuple(diagnostics), None)

    for location, key in duplicate_keys:
        diagnostics.append(diag(
            "artifact-manifest-duplicate-key",
            path=MANIFEST_PATH,
            target=key,
            message=f"duplicate JSON object key at {location}",
        ))

    if has_surrogate:
        diagnostics.append(diag(
            "artifact-manifest-invalid-json",
            path=MANIFEST_PATH,
            message="manifest JSON contains an unpaired surrogate escape",
        ))
    else:
        try:
            canonical = (canonical_json_text(parsed) + "\n").encode("utf-8")
        except (TypeError, ValueError) as error:
            diagnostics.append(diag(
                "artifact-manifest-invalid-json",
                path=MANIFEST_PATH,
                message=f"manifest JSON cannot be canonically represented: {error}",
            ))
        except RecursionError:
            diagnostics.append(diag(
                "artifact-manifest-schema",
                path=MANIFEST_PATH,
                message="manifest JSON nesting exceeds the auditor recursion limit",
            ))
        else:
            if canonical != data:
                diagnostics.append(diag(
                    "artifact-manifest-format",
                    path=MANIFEST_PATH,
                    message="manifest is not exact two-space canonical JSON with one trailing newline",
                ))

    ids: list[str] = []
    ids_complete = True
    manifest_paths: list[str] = []

    if not isinstance(parsed, JsonObject):
        diagnostics.append(diag(
            "artifact-manifest-schema",
            path=MANIFEST_PATH,
            message="manifest top level is not a JSON object",
        ))
        return ManifestAudit(tuple(diagnostics), None)

    validate_exact_keys(parsed, ["version", "pages"], "top-level object", diagnostics)

    version = json_first(parsed, "version")
    if type(version) is not int or version != 1:
        diagnostics.append(diag(
            "artifact-manifest-version",
            path=MANIFEST_PATH,
            message=f"manifest version is {version!r}, expected integer 1",
        ))

    pages = json_first(parsed, "pages")
    if type(pages) is not list:
        diagnostics.append(diag(
            "artifact-manifest-schema",
            path=MANIFEST_PATH,
            message="manifest pages is not a JSON array",
        ))
        return ManifestAudit(tuple(diagnostics), None)

    for index, page in enumerate(pages):
        context = f"pages[{index}]"
        if not isinstance(page, JsonObject):
            diagnostics.append(diag(
                "artifact-manifest-schema",
                path=MANIFEST_PATH,
                message=f"{context} is not a JSON object",
            ))
            ids_complete = False
            continue

        validate_exact_keys(page, ["id", "path", "sha256"], context, diagnostics)
        page_id = json_first(page, "id")
        page_path = json_first(page, "path")
        page_sha = json_first(page, "sha256")

        if type(page_id) is not str:
            diagnostics.append(diag(
                "artifact-manifest-schema",
                path=MANIFEST_PATH,
                message=f"{context}.id is not a string",
            ))
            ids_complete = False
        else:
            ids.append(page_id)

        if type(page_path) is not str:
            diagnostics.append(diag(
                "artifact-manifest-schema",
                path=MANIFEST_PATH,
                message=f"{context}.path is not a string",
            ))
        else:
            manifest_paths.append(page_path)
            problem = manifest_path_problem(page_path)
            if problem is not None:
                diagnostics.append(diag(
                    "artifact-manifest-path",
                    path=MANIFEST_PATH,
                    target=page_path,
                    message=f"{context}.path {problem}",
                ))

        if type(page_sha) is not str:
            diagnostics.append(diag(
                "artifact-manifest-schema",
                path=MANIFEST_PATH,
                message=f"{context}.sha256 is not a string",
            ))
        elif LOWER_SHA256_RE.fullmatch(page_sha) is None:
            diagnostics.append(diag(
                "artifact-manifest-sha256",
                path=MANIFEST_PATH,
                target=page_sha,
                message=f"{context}.sha256 is not exactly 64 lowercase hexadecimal characters",
            ))
        elif type(page_path) is str and page_path in html_digests:
            actual = html_digests[page_path]
            if page_sha != actual:
                diagnostics.append(diag(
                    "artifact-manifest-sha256",
                    path=MANIFEST_PATH,
                    target=page_path,
                    message=f"{context}.sha256 does not match the exact emitted file bytes",
                ))

        if type(page_id) is str and type(page_path) is str:
            expected_path = f"{page_id}.html"
            if page_path != expected_path:
                diagnostics.append(diag(
                    "artifact-manifest-id-path-mismatch",
                    path=MANIFEST_PATH,
                    target=page_path,
                    message=f"{context} id {page_id!r} requires path {expected_path!r}",
                ))

    for duplicate_id in duplicate_values(ids):
        diagnostics.append(diag(
            "artifact-manifest-duplicate-entry",
            path=MANIFEST_PATH,
            target=duplicate_id,
            message="duplicate manifest page id",
        ))
    for duplicate_path in duplicate_values(manifest_paths):
        diagnostics.append(diag(
            "artifact-manifest-duplicate-entry",
            path=MANIFEST_PATH,
            target=duplicate_path,
            message="duplicate manifest page path",
        ))

    actual_paths = set(html_digests)
    manifest_path_set = set(manifest_paths)
    for missing_path in sorted(actual_paths - manifest_path_set):
        diagnostics.append(diag(
            "artifact-manifest-missing-entry",
            path=MANIFEST_PATH,
            target=missing_path,
            message="emitted .html file has no manifest page entry",
        ))
    for extra_path in sorted(manifest_path_set - actual_paths):
        diagnostics.append(diag(
            "artifact-manifest-extra-entry",
            path=MANIFEST_PATH,
            target=extra_path,
            message="manifest page path has no emitted regular .html file",
        ))

    return ManifestAudit(tuple(diagnostics), tuple(ids) if ids_complete else None)


# ---------------------------------------------------------------------------
# expected order and whole-tree audit


def read_expect_order_file(path: str) -> tuple[str, ...]:
    """Read newline-delimited expected ids as strict UTF-8.

    Only U+000A is a delimiter.  One final delimiter is a terminator, not an
    additional empty id; interior empty lines are significant ids.
    """
    order_path = os.path.normpath(os.fsdecode(os.fspath(path)))
    try:
        if os.path.islink(order_path):
            raise HostError(order_path, "expect-order file is a symlink")
        info = os.stat(order_path, follow_symlinks=False)
    except OSError as error:
        raise host_error(order_path, "inspect expect-order file", error) from error
    if not stat.S_ISREG(info.st_mode):
        raise HostError(order_path, "expect-order file is not a regular file")
    data = read_bytes(order_path)
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise HostError(
            order_path,
            f"expect-order file is not strict UTF-8 at byte offset {error.start}",
        ) from error
    if text == "":
        return ()
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return tuple(lines)


def read_expect_order_json_file(path: str) -> tuple[str, ...]:
    """Read expected ids from a strict JSON array-of-strings file.

    JSON whitespace is insignificant, but the top-level type and every element
    type are exact.  Unpaired surrogate escapes are usage errors because they
    cannot denote a filesystem page id string unambiguously.
    """
    order_path = os.path.normpath(os.fsdecode(os.fspath(path)))
    try:
        if os.path.islink(order_path):
            raise HostError(order_path, "expect-order JSON file is a symlink")
        info = os.stat(order_path, follow_symlinks=False)
    except OSError as error:
        raise host_error(order_path, "inspect expect-order JSON file", error) from error
    if not stat.S_ISREG(info.st_mode):
        raise HostError(order_path, "expect-order JSON file is not a regular file")
    data = read_bytes(order_path)
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise HostError(
            order_path,
            f"expect-order JSON file is not strict UTF-8 at byte offset {error.start}",
        ) from error
    try:
        parsed = json.loads(text, parse_constant=_reject_json_constant)
    except json.JSONDecodeError as error:
        raise HostError(
            order_path,
            "expect-order JSON is not valid JSON at "
            f"line {error.lineno}, column {error.colno}: {error.msg}",
        ) from error
    except ValueError as error:
        raise HostError(order_path, f"expect-order JSON is not valid JSON: {error}") from error
    except RecursionError as error:
        raise HostError(
            order_path,
            "expect-order JSON nesting exceeds the parser recursion limit",
        ) from error

    if type(parsed) is not list:
        raise HostError(order_path, "expect-order JSON top level is not an array")
    for index, value in enumerate(parsed):
        if type(value) is not str:
            raise HostError(
                order_path,
                f"expect-order JSON element {index} is not a string",
            )
        if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
            raise HostError(
                order_path,
                f"expect-order JSON element {index} contains an unpaired surrogate",
            )
    return tuple(parsed)


def tree_shape_diagnostics(scan: TreeScan, tree_label: str) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    for entry in scan.entries:
        if entry.kind == "symlink":
            diagnostics.append(diag(
                "artifact-symlink",
                path=entry.path,
                message=f"symlinked entry in {tree_label}; symlinks are never followed",
            ))
        elif entry.kind == "other":
            diagnostics.append(diag(
                "artifact-nonregular-file",
                path=entry.path,
                message=f"non-regular, non-directory entry in {tree_label}",
            ))
    return diagnostics


@dataclass(frozen=True)
class AuditResult:
    scan: TreeScan
    diagnostics: tuple[Diagnostic, ...]
    html_digests: dict[str, str]
    manifest_ids: tuple[str, ...] | None


def audit_tree(root: str, expect_order_file: str | None = None,
               require_order_check: bool = True, *,
               expect_order_json: str | None = None) -> AuditResult:
    """Audit one output tree and return its scan plus sorted diagnostics."""
    if expect_order_file is not None and expect_order_json is not None:
        raise ValueError("expect_order_file and expect_order_json are mutually exclusive")
    if expect_order_json is not None:
        expected_ids = read_expect_order_json_file(expect_order_json)
    elif expect_order_file is not None:
        expected_ids = read_expect_order_file(expect_order_file)
    else:
        expected_ids = None
    scan = scan_tree(root)
    diagnostics = tree_shape_diagnostics(scan, "the audited tree")

    if require_order_check and expected_ids is None:
        diagnostics.append(diag(
            "artifact-manifest-order-unchecked",
            path=MANIFEST_PATH,
            message=(
                "manifest page order cannot be inferred from output bytes; "
                "pass --expect-order-json or legacy --expect-order-file, "
                "or explicitly waive with --no-order-check"
            ),
        ))

    file_entries = [entry for entry in scan.entries if entry.kind == "file"]
    for entry in file_entries:
        if entry.path != MANIFEST_PATH and not entry.path.endswith(".html"):
            diagnostics.append(diag(
                "artifact-foreign-file",
                path=entry.path,
                message=(
                    "foreign regular file in v0 output tree; only .html files "
                    "and exact _pubend/manifest.json are allowed"
                ),
            ))
    html_entries = [entry for entry in file_entries if entry.path.endswith(".html")]
    html_files = frozenset(entry.path for entry in html_entries)
    html_digests: dict[str, str] = {}

    for entry in html_entries:
        data = read_bytes(entry.full_path)
        file_diagnostics, digest = audit_html_bytes(entry.path, data, html_files)
        html_digests[entry.path] = digest
        diagnostics.extend(file_diagnostics)

    manifest = audit_manifest(scan, html_digests)
    diagnostics.extend(manifest.diagnostics)

    if expected_ids is not None and manifest.ids is not None:
        actual_ids = manifest.ids
        mismatch: str | None = None
        shared = min(len(expected_ids), len(actual_ids))
        for index in range(shared):
            if expected_ids[index] != actual_ids[index]:
                mismatch = (
                    f"first mismatch at index {index}: expected {expected_ids[index]!r}, "
                    f"manifest has {actual_ids[index]!r}"
                )
                break
        if mismatch is None and len(expected_ids) != len(actual_ids):
            mismatch = (
                f"id sequence length differs: expected {len(expected_ids)}, "
                f"manifest has {len(actual_ids)}"
            )
        if mismatch is not None:
            diagnostics.append(diag(
                "artifact-manifest-order-mismatch",
                path=MANIFEST_PATH,
                message=mismatch,
            ))

    return AuditResult(
        scan=scan,
        diagnostics=tuple(sort_diagnostics(diagnostics)),
        html_digests=html_digests,
        manifest_ids=manifest.ids,
    )


# ---------------------------------------------------------------------------
# tree comparison


@dataclass(frozen=True)
class TreeDifference:
    kind: str  # only-in-left, only-in-right, type-mismatch, bytes-differ
    path: str
    first_byte: int | None = None
    left_kind: str | None = None
    right_kind: str | None = None


def first_byte_difference(left_path: str, right_path: str) -> int | None:
    """Return the first differing byte offset, or None for byte-identical files."""
    try:
        with open(left_path, "rb") as left_file, open(right_path, "rb") as right_file:
            offset = 0
            while True:
                left_chunk = left_file.read(65536)
                right_chunk = right_file.read(65536)
                if not left_chunk and not right_chunk:
                    return None
                if left_chunk == right_chunk:
                    offset += len(left_chunk)
                    continue
                shared = min(len(left_chunk), len(right_chunk))
                for index in range(shared):
                    if left_chunk[index] != right_chunk[index]:
                        return offset + index
                return offset + shared
    except OSError as error:
        raise host_error(f"{left_path} / {right_path}", "compare file bytes", error) from error


def compare_scanned_trees(left: TreeScan, right: TreeScan) -> tuple[TreeDifference, ...]:
    """Compare full entry shape and regular-file bytes in path order.

    Entry shape is the exact mapping of tree-relative paths to scanned entry
    kinds.  Because directories are entries, empty-directory presence is
    significant to this comparison even though it is not significant to
    artifact conformance.  Symlinks are compared only as symlink-kind entries
    and are never followed.
    """
    left_files = left.files_by_path()
    right_files = right.files_by_path()
    left_kinds = left.kinds_by_path()
    right_kinds = right.kinds_by_path()
    differences: list[TreeDifference] = []

    for path in sorted(set(left_kinds) & set(right_kinds)):
        left_kind = left_kinds[path]
        right_kind = right_kinds[path]
        if left_kind != right_kind:
            differences.append(TreeDifference(
                kind="type-mismatch",
                path=path,
                left_kind=left_kind,
                right_kind=right_kind,
            ))

    for path in sorted(set(left_kinds) - set(right_kinds)):
        differences.append(TreeDifference(
            kind="only-in-left",
            path=path,
            left_kind=left_kinds[path],
        ))
    for path in sorted(set(right_kinds) - set(left_kinds)):
        differences.append(TreeDifference(
            kind="only-in-right",
            path=path,
            right_kind=right_kinds[path],
        ))

    for path in sorted(set(left_files) & set(right_files)):
        first_byte = first_byte_difference(left_files[path].full_path, right_files[path].full_path)
        if first_byte is not None:
            differences.append(TreeDifference(
                kind="bytes-differ",
                path=path,
                first_byte=first_byte,
                left_kind="file",
                right_kind="file",
            ))

    return tuple(sorted(differences, key=lambda difference: (difference.path, difference.kind)))


def compare_trees(left_root: str, right_root: str) -> tuple[TreeDifference, ...]:
    """Scan and compare two trees without following symlinks."""
    return compare_scanned_trees(scan_tree(left_root), scan_tree(right_root))


def comparison_diagnostic(difference: TreeDifference) -> Diagnostic:
    if difference.kind == "only-in-left":
        if difference.left_kind == "file":
            return diag(
                "artifact-compare-missing-file",
                path=difference.path,
                message="regular file is present in the left tree but missing from the right tree",
            )
        return diag(
            "artifact-compare-missing-entry",
            path=difference.path,
            message=(
                f"{difference.left_kind} entry is present in the left tree "
                "but missing from the right tree"
            ),
        )
    if difference.kind == "only-in-right":
        if difference.right_kind == "file":
            return diag(
                "artifact-compare-extra-file",
                path=difference.path,
                message="regular file is present in the right tree but missing from the left tree",
            )
        return diag(
            "artifact-compare-extra-entry",
            path=difference.path,
            message=(
                f"{difference.right_kind} entry is present in the right tree "
                "but missing from the left tree"
            ),
        )
    if difference.kind == "type-mismatch":
        return diag(
            "artifact-compare-type-mismatch",
            path=difference.path,
            message=(
                f"entry kinds differ: left is {difference.left_kind}, "
                f"right is {difference.right_kind}"
            ),
        )
    return diag(
        "artifact-compare-bytes-differ",
        path=difference.path,
        message=f"file bytes first differ at byte offset {difference.first_byte}",
    )


# ---------------------------------------------------------------------------
# CLI


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="audit a pubend output tree against the deterministic artifact contract",
    )
    parser.add_argument("tree", metavar="TREE", help="output tree to audit")
    order_group = parser.add_mutually_exclusive_group()
    order_group.add_argument(
        "--expect-order-json",
        metavar="FILE",
        help="strict JSON array-of-strings file whose ids must exactly match manifest page order",
    )
    order_group.add_argument(
        "--expect-order-file",
        metavar="FILE",
        help=(
            "legacy newline-delimited file whose ids must exactly match manifest page order "
            "(cannot represent an id containing U+000A)"
        ),
    )
    order_group.add_argument(
        "--no-order-check",
        action="store_true",
        help="explicitly waive manifest order evidence (not a conformance check)",
    )
    parser.add_argument(
        "--compare",
        metavar="OTHER_TREE",
        help=(
            "recursively compare exact entry path/kind shape, including empty directories, "
            "and regular-file bytes with another output tree"
        ),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    try:
        primary = audit_tree(
            args.tree,
            expect_order_file=args.expect_order_file,
            require_order_check=not args.no_order_check,
            expect_order_json=args.expect_order_json,
        )
        diagnostics = list(primary.diagnostics)

        if args.compare is not None:
            comparison_scan = scan_tree(args.compare)
            diagnostics.extend(tree_shape_diagnostics(comparison_scan, "the comparison tree"))
            differences = compare_scanned_trees(primary.scan, comparison_scan)
            diagnostics.extend(comparison_diagnostic(difference) for difference in differences)

        diagnostics = sort_diagnostics(diagnostics)
        for diagnostic in diagnostics:
            print(diagnostic.json_line())
        return 1 if diagnostics else 0
    except HostError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
