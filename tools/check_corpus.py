#!/usr/bin/env python3
"""check_corpus.py — v0 conformance oracle for pubend site trees.

Scratch test tooling, not product code. Zero-dependency Python 3. Nothing in
src/ imports this. Its job is to cross-check the real compiler's verdicts.

Usage:
    python3 tools/check_corpus.py SITE_ROOT
        Validate the site rooted at SITE_ROOT (its content/ subtree).
        Exit 0 + one-line summary when valid; nonzero + every violation when not.

    python3 tools/check_corpus.py --self-test [FIXTURES_DIR]
        Run every fixture directory under FIXTURES_DIR (default ./corpus-negative),
        compare the set of emitted diagnostic classes with the set named in each
        fixture's EXPECTED file, print the matrix, exit nonzero on any mismatch.

Diagnostic classes (stable strings, compared by fixtures):
    duplicate-id               two pages with the same path-derived id
    duplicate-id-case          ids differing only by letter case
    dangling-parent            parent key names no existing page id
    self-parent                parent == own id
    parent-cycle               page sits on a parent cycle (len >= 2)
    unknown-frontmatter-key    well-formed key outside {title,parent,status}
    duplicate-frontmatter-key  same key twice in one frontmatter block
    malformed-frontmatter      bad delimiter structure, bad key syntax, or a
                               value violating its closed-grammar constraint
                               (empty title/parent, status not published|draft)
    link-root-escape           internal .md link normalizes above content root
    link-nonexistent-page      internal .md link resolves to no page id
    link-query                 internal .md link carrying a ?query suffix
    non-md-file                regular file under content/ not ending in .md
    invalid-utf8               page bytes are not valid UTF-8
    symlinked-entry            symlinked entry under content/ (file, directory,
                               or dangling); symlinks are never followed
    valid                      no violations (EXPECTED-file pseudo class)

Extra classes with no corpus-negative fixture (spec-mandated, rarely triggered):
    missing-content-dir        site root has no content/ directory
    oversized-page             page body exceeds the 1 MiB input ceiling

Synthetic fixtures:
    A fixture may carry FIXTURE.synthetic.json at its root for violations a real
    filesystem cannot physically express (exact duplicate ids; case-only id
    collisions on this host's case-insensitive filesystem). The file is read
    ONLY by --self-test; normal site validation never looks at it, so positive
    corpus validation is never contaminated. Schema:
        {"_note": "...", "pages": [{"id": "...", "parent": "..."|null}, ...]}
    --self-test additionally asserts the physical tree of a synthetic fixture
    validates as 'valid' without injection.

Markdown link extraction is only a scratch approximation of the engine's
grammar, not a Markdown parser and not evidence about full CommonMark behavior:
fenced and indented code blocks, inline code spans and HTML comments are
stripped; inline links [t](d), images, and reference-style definitions/usages
([t][l], [t][], [l]) are found; footnote definitions/usages ([^n]) are ignored.
Autolinks, backslash escapes, raw-HTML <a href>, entity handling, and the full
reference-label matching grammar are not recognized. Corpus fixtures should
exercise only this documented subset unless the oracle is deliberately extended.
Symlinked entries under content/ are diagnosed and never followed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass

MAX_PAGE_BYTES = 1024 * 1024
CLOSED_KEYS = {"title", "parent", "status"}
STATUS_VALUES = {"published", "draft"}
RFC3986_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")

SYNTHETIC_FILE = "FIXTURE.synthetic.json"
EXPECTED_FILE = "EXPECTED"


@dataclass
class Diag:
    cls: str
    path: str
    line: int
    col: int
    msg: str

    def __str__(self):
        loc = f"{self.path}:{self.line}:{self.col}" if self.line else self.path
        return f"{self.cls} {loc} — {self.msg}"


@dataclass
class Page:
    id: str
    path: str  # display path; "<synthetic>" for injected records
    parent: str | None
    parent_line: int
    links: list  # [(line, col, raw_dest)]
    synthetic: bool = False


# ---------------------------------------------------------------------------
# frontmatter


def parse_frontmatter(page, lines):
    """lines: file split into lines, newline-free. Returns (parent_value,
    parent_line, body_start_index, diags)."""
    diags = []
    if not lines or lines[0] != "---":
        return None, 0, 0, diags
    seen = {}
    i = 1
    closed = False
    while i < len(lines):
        line = lines[i]
        if line == "---":
            closed = True
            i += 1
            break
        m = re.match(r"^([a-z-]+):(.*)$", line)
        if not m:
            diags.append(Diag("malformed-frontmatter", page.path, i + 1, 1,
                              f"frontmatter line is not 'key: value': {line!r}"))
        else:
            key, val = m.group(1), m.group(2).strip()
            if key in seen:
                diags.append(Diag("duplicate-frontmatter-key", page.path, i + 1, 1,
                                  f"key {key!r} already defined at line {seen[key][1]}"))
            elif key not in CLOSED_KEYS:
                diags.append(Diag("unknown-frontmatter-key", page.path, i + 1, 1,
                                  f"key {key!r} outside closed set title/parent/status"))
            else:
                seen[key] = (val, i + 1)
                if val == "":
                    diags.append(Diag("malformed-frontmatter", page.path, i + 1, 1,
                                      f"key {key!r} has empty value"))
                elif key == "status" and val not in STATUS_VALUES:
                    diags.append(Diag("malformed-frontmatter", page.path, i + 1, 1,
                                      f"status {val!r} not in {{published, draft}}"))
        i += 1
    if not closed:
        diags.append(Diag("malformed-frontmatter", page.path, 1, 1,
                          "opening '---' has no closing '---'"))
    pval, pline = seen.get("parent", (None, 0))
    return pval, pline, i, diags


# ---------------------------------------------------------------------------
# body hygiene: strip regions where bracket text is not a markdown link


def strip_nonlink_regions(body_lines):
    out = []
    fence_ch = None
    fence_len = 0
    for line in body_lines:
        m = re.match(r"^[ ]{0,3}(`{3,}|~{3,})", line)
        if fence_ch is None:
            if m:
                fence_ch, fence_len = m.group(1)[0], len(m.group(1))
                out.append("")
                continue
        else:
            out.append("")
            if m and m.group(1)[0] == fence_ch and len(m.group(1)) >= fence_len:
                fence_ch = None
            continue
        out.append(line)
    # HTML comments: blank non-newline chars, preserving line numbering
    text = "\n".join(out)
    text = re.sub(r"<!--.*?-->",
                  lambda m: "".join(c if c == "\n" else " " for c in m.group(0)),
                  text, flags=re.S)
    out = text.split("\n")
    res = []
    for line in out:
        if line.startswith("    ") or line.startswith("\t"):
            res.append("")  # indented code block
            continue
        prev = None
        while prev != line:  # inline code spans (same-length backtick runs)
            prev = line
            line = re.sub(r"(`+)(.*?)\1", lambda m: " " * len(m.group(0)), line)
        res.append(line)
    return res


# ---------------------------------------------------------------------------
# link extraction


DEF_RE = re.compile(r"^[ ]{0,3}\[([^\]]+)\]:[ \t]*(.*)$")


def norm_label(label):
    return " ".join(label.split()).lower()


def parse_dest(raw):
    s = raw.strip()
    if s.startswith("<"):
        end = s.find(">")
        return s[1:end] if end != -1 else s[1:]
    parts = s.split()
    return parts[0] if parts else ""


def match_bracket(s, start):
    """s[start] == '['. Return index of matching ']' (nesting-aware) or -1."""
    depth = 0
    j = start
    while j < len(s):
        if s[j] == "[":
            depth += 1
        elif s[j] == "]":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def scan_line(s, ln, defs, links):
    i = 0
    while i < len(s):
        if s[i] == "!" and i + 1 < len(s) and s[i + 1] == "[":
            bstart = i + 1
        elif s[i] == "[":
            bstart = i
        else:
            i += 1
            continue
        close = match_bracket(s, bstart)
        if close == -1:
            i += 1
            continue
        text_label = s[bstart + 1:close]
        after = close + 1
        if after < len(s) and s[after] == "(":
            depth = 0
            k = after
            while k < len(s):
                if s[k] == "(":
                    depth += 1
                elif s[k] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            if k < len(s):
                links.append((ln, i + 1, parse_dest(s[after + 1:k])))
                i = k + 1
            else:
                i = after
            continue
        if after < len(s) and s[after] == "[":
            c2 = match_bracket(s, after)
            if c2 != -1:
                lab = s[after + 1:c2]
                lab = text_label if lab.strip() == "" else lab
                hit = defs.get(norm_label(lab))
                if hit is not None:
                    links.append((ln, i + 1, hit))
                    i = c2 + 1
                    continue
                # CommonMark: unresolved second label falls back to shortcut
                hit = defs.get(norm_label(text_label))
                if hit is not None:
                    links.append((ln, i + 1, hit))
                i = c2 + 1
                continue
        hit = defs.get(norm_label(text_label))
        if hit is not None:
            links.append((ln, i + 1, hit))
        i = after
    return


def extract_links(page, body_lines, body_start):
    lines = strip_nonlink_regions(body_lines)
    defs = {}
    for off, line in enumerate(lines):
        m = DEF_RE.match(line)
        if m and not m.group(1).startswith("^"):
            key = norm_label(m.group(1))
            if key and key not in defs:
                defs[key] = parse_dest(m.group(2))
            lines[off] = ""  # definition lines render nothing; don't self-match
    links = []
    for off, line in enumerate(lines):
        if line:
            scan_line(line, body_start + off + 1, defs, links)
    return links


# ---------------------------------------------------------------------------
# page loading


def load_pages(content_dir):
    pages = []
    diags = []
    for dirpath, dirnames, filenames in os.walk(content_dir, followlinks=False):
        dirnames.sort()
        real_dirnames = []
        for dn in dirnames:
            full = os.path.join(dirpath, dn)
            rel = os.path.relpath(full, content_dir).replace(os.sep, "/")
            if os.path.islink(full):
                diags.append(Diag("symlinked-entry", rel, 0, 0,
                                  "symlinked entry under content/ is an input-tree error"))
            else:
                real_dirnames.append(dn)
        dirnames[:] = real_dirnames
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, content_dir).replace(os.sep, "/")
            if os.path.islink(full):
                diags.append(Diag("symlinked-entry", rel, 0, 0,
                                  "symlinked entry under content/ is an input-tree error"))
                continue
            if not fn.endswith(".md"):
                diags.append(Diag("non-md-file", rel, 0, 0,
                                  "regular file under content/ not ending in .md"))
                continue
            if not os.path.isfile(full):
                diags.append(Diag("non-md-file", rel, 0, 0,
                                  ".md-named entry is not a regular file"))
                continue
            size = os.path.getsize(full)
            if size > MAX_PAGE_BYTES:
                diags.append(Diag("oversized-page", rel, 0, 0,
                                  f"{size} bytes exceeds 1 MiB ceiling"))
                continue
            with open(full, "rb") as fh:
                raw = fh.read()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError as exc:
                prefix = raw[:exc.start].decode("utf-8")
                line = prefix.count("\n") + 1
                col = len(prefix.rsplit("\n", 1)[-1]) + 1
                diags.append(Diag("invalid-utf8", rel, line, col,
                                  f"invalid UTF-8 at byte offset {exc.start}: {exc.reason}"))
                continue
            lines = text.splitlines()
            page = Page(id=rel[:-3], path=rel, parent=None, parent_line=0,
                        links=[])
            parent, pline, body_start, fdiags = parse_frontmatter(page, lines)
            page.parent = parent if parent else None
            page.parent_line = pline
            diags.extend(fdiags)
            page.links = extract_links(page, lines[body_start:], body_start)
            pages.append(page)
    return pages, diags


# ---------------------------------------------------------------------------
# link classification + resolution (v0-spec §5)


def classify(dest):
    if RFC3986_SCHEME_RE.match(dest):
        return "external"
    if dest == "" or dest.startswith("#") or dest.startswith("/"):
        return "passthrough"
    base = dest.split("#", 1)[0]
    if "?" in base:
        return "query" if base.split("?", 1)[0].endswith(".md") else "passthrough"
    return "internal" if base.endswith(".md") else "passthrough"


def resolve(page_id, dest):
    """dest: internal .md target, fragment-stripped, no query. Returns
    normalized target id, or None if the path escapes the content root."""
    base = dest.split("#", 1)[0]
    d = page_id.rsplit("/", 1)[0] if "/" in page_id else ""
    joined = f"{d}/{base}" if d else base
    stack = []
    for seg in joined.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not stack:
                return None
            stack.pop()
        else:
            stack.append(seg)
    target = "/".join(stack)
    return target[:-3] if target.endswith(".md") else target


# ---------------------------------------------------------------------------
# graph checks (v0-spec §4)


def ascii_lower_ascii_only(s):
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in s)


def graph_checks(pages):
    diags = []
    by_id = {}
    for p in pages:
        by_id.setdefault(p.id, []).append(p)
    for pid, ps in by_id.items():
        if len(ps) > 1:
            for p in ps:
                diags.append(Diag("duplicate-id", p.path, 0, 0,
                                  f"id {pid!r} claimed by {len(ps)} pages"))
    lower = {}
    for p in pages:
        lower.setdefault(ascii_lower_ascii_only(p.id), set()).add(p.id)
    for lid, ids in lower.items():
        if len(ids) > 1:
            for p in pages:
                if p.id in ids:
                    diags.append(Diag("duplicate-id-case", p.path, 0, 0,
                                      f"id {p.id!r} collides case-insensitively: "
                                      f"{sorted(ids)}"))
    edges = {}
    for p in pages:
        if p.parent is None:
            continue
        if p.parent == p.id:
            diags.append(Diag("self-parent", p.path, p.parent_line, 1,
                              f"page {p.id!r} is its own parent"))
        elif p.parent not in by_id:
            diags.append(Diag("dangling-parent", p.path, p.parent_line, 1,
                              f"parent {p.parent!r} is not a page id"))
        else:
            edges[p.id] = p.parent
    done = set()
    in_cycle = set()
    for start in edges:
        if start in done:
            continue
        pos = {}
        path = []
        cur = start
        while cur in edges and cur not in done and cur not in pos:
            pos[cur] = len(path)
            path.append(cur)
            cur = edges[cur]
        if cur in pos:
            in_cycle.update(path[pos[cur]:])
        done.update(path)
    for p in pages:
        if p.id in in_cycle:
            diags.append(Diag("parent-cycle", p.path, p.parent_line, 1,
                              f"page {p.id!r} sits on a parent cycle"))
    return diags, by_id


def link_checks(pages, by_id):
    diags = []
    n_internal = 0
    for p in pages:
        for ln, col, dest in p.links:
            kind = classify(dest)
            if kind in ("external", "passthrough"):
                continue
            if kind == "query":
                diags.append(Diag("link-query", p.path, ln, col,
                                  f"internal link {dest!r} carries a ?query"))
                continue
            n_internal += 1
            target = resolve(p.id, dest)
            if target is None:
                diags.append(Diag("link-root-escape", p.path, ln, col,
                                  f"link {dest!r} escapes the content root"))
            elif target not in by_id:
                diags.append(Diag("link-nonexistent-page", p.path, ln, col,
                                  f"link {dest!r} resolves to {target!r}, no such page"))
    return diags, n_internal


# ---------------------------------------------------------------------------
# top level


def check_site(root, synthetic_pages=None):
    """Returns (diags, n_pages, n_internal_links)."""
    diags = []
    content_dir = os.path.join(root, "content")
    if not os.path.isdir(content_dir):
        diags.append(Diag("missing-content-dir", root, 0, 0,
                          "site root has no content/ directory"))
        return diags, 0, 0
    pages, diags = load_pages(content_dir)
    if synthetic_pages:
        pages = pages + synthetic_pages
    gdiags, by_id = graph_checks(pages)
    diags += gdiags
    ldiags, n_internal = link_checks(pages, by_id)
    diags += ldiags
    diags.sort(key=lambda d: (d.path, d.line, d.col, d.cls))
    return diags, len(pages), n_internal


def load_synthetic(fdir):
    path = os.path.join(fdir, SYNTHETIC_FILE)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    pages = []
    for rec in data.get("pages", []):
        pages.append(Page(id=rec["id"], path="<synthetic>",
                          parent=rec.get("parent"), parent_line=0,
                          links=[], synthetic=True))
    return pages


def self_test(fixtures_dir):
    rows = []
    all_ok = True
    for name in sorted(os.listdir(fixtures_dir)):
        fdir = os.path.join(fixtures_dir, name)
        exp_file = os.path.join(fdir, EXPECTED_FILE)
        if not os.path.isdir(fdir) or not os.path.isfile(exp_file):
            continue
        with open(exp_file, encoding="utf-8") as fh:
            expected = {l.strip() for l in fh if l.strip()}
        synthetic = load_synthetic(fdir)
        diags, npages, _ = check_site(fdir, synthetic_pages=synthetic)
        actual = {d.cls for d in diags} or {"valid"}
        ok = actual == expected
        note = ""
        if synthetic is not None:
            pdiags, _, _ = check_site(fdir, synthetic_pages=None)
            physical = {d.cls for d in pdiags} or {"valid"}
            if physical != {"valid"}:
                ok = False
                note = f" (dishonest fixture: physical tree yields {sorted(physical)} without injection)"
            else:
                note = " (synthetic injection; physical tree is valid)"
        all_ok = all_ok and ok
        rows.append((ok, name, expected, actual, note, diags))
    for ok, name, expected, actual, note, diags in rows:
        status = "PASS" if ok else "FAIL"
        print(f"{status} {name}: expected={{{','.join(sorted(expected))}}} "
              f"actual={{{','.join(sorted(actual))}}}{note}")
        if not ok:
            for d in diags:
                print(f"    {d}")
    n_pass = sum(1 for r in rows if r[0])
    print(f"self-test: {n_pass}/{len(rows)} fixtures match EXPECTED")
    return 0 if all_ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="pubend v0 site conformance oracle")
    ap.add_argument("site", nargs="?", help="site root containing content/")
    ap.add_argument("--self-test", nargs="?", const="corpus-negative",
                    metavar="FIXTURES_DIR",
                    help="run corpus-negative fixture matrix (default ./corpus-negative)")
    args = ap.parse_args(argv)
    if args.self_test is not None:
        return self_test(args.self_test)
    if not args.site:
        ap.error("site root required (or use --self-test)")
    diags, npages, nlinks = check_site(args.site)
    if diags:
        for d in diags:
            print(d)
        print(f"invalid: {args.site} — {len(diags)} violation(s), "
              f"{len({d.cls for d in diags})} class(es)")
        return 1
    print(f"valid: {args.site} — {npages} pages, {nlinks} internal links checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
