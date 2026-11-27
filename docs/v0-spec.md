# pubend v0 specification

Status: locked unless marked **(open)**. This document is the unambiguous target for implementation.
Anything not specified here is out of scope, not implied.

## 1. Input tree

```text
DIR/
  content/          # the content root; all pages live under here
    index.md
    guides.md
    guides/getting-started.md
    ...
```

- A page is any regular file under `content/` ending in `.md`. Nested directories are allowed.
- No other file types are read in v0. Non-`.md` files under `content/` are an error: reject the input tree,
  fail-loud.
- Symlinked entries under `content/` are input-tree errors. The compiler neither follows nor silently skips
  them. This applies equally to symlinks naming files, symlinks naming directories, and dangling symlinks.
- Nothing outside `content/` is read. There is no configuration file in v0.
- Maximum input size per page: 1 MiB. Over-limit is a content error, not a crash. The ceiling is part of the
  proof-integrated boundary pattern inherited from bendown.
- Page bytes must be valid UTF-8. Invalid UTF-8 is a content error; lossy replacement characters must not be
  introduced by the input boundary.
- Discovery order is deterministic: within each directory, host entry names are ordered by Unicode code point;
  regular files are processed before child directories, then child directories are traversed in that same order.
  This depth-first discovery order is the input page order and, after successful validation, the emitted-page
  order. Compilation preserves that order rather than reordering pages.

## 2. Page identity — path-derived, no aliasing

- A page's **id** is its path relative to `content/`, without the `.md` extension, using forward slashes:
  `content/guides/getting-started.md` → id `guides/getting-started`.
- Ids are exact and case-sensitive. Two files whose ids differ only by ASCII letter case are a duplicate-id
  error (portable correctness on case-insensitive filesystems).
- Unicode portability is explicitly narrower in v0: Bend 2.0.40's `String.to_lower` is ASCII-only, so the
  case-collision check is ASCII-only. Non-ASCII ids are legal input, but case-equivalent non-ASCII ids are
  distinct in v0 and are not guaranteed portable across case-insensitive or normalizing filesystems.
- There is no `id` frontmatter key and no aliasing. Ever. The id is the path.
- Output mapping: page id `P` emits `P.html` in the output tree (`index` → `index.html`). No pretty-URL
  directory rewriting in v0.

## 3. Frontmatter — minimal closed grammar

- Optional. If present, it is the very first thing in the file: a line exactly `---`, then zero or more
  `key: value` lines, then a closing line exactly `---`.
- Keys: lowercase ASCII letters and hyphens only. Values: the remainder of the line after `key:`, trimmed of
  leading/trailing whitespace. No quoting, no nesting, no multi-line values, no interpolation.
- **Closed key set** — any other key is an error, not a warning:

| key | meaning | constraints |
|---|---|---|
| `title` | page title for layout/nav | any non-empty string |
| `parent` | id of the parent page | must resolve to an existing page id; must not create a cycle |
| `status` | `published` or `draft` | `draft` pages render but are excluded from nav listings |

- Duplicate keys are an error. Malformed delimiter structure is an error. Unknown keys are an error.
  (Fail-loud, spanned diagnostics: file, line, column.)
- `title` is optional; when absent, the layout uses the first H1 if present, else the id. `parent` absent →
  root page. `status` absent → `published`.

## 4. Graph construction and validation — the center of the pipeline

pubend is **graph-native**: the validated graph is the central artifact of compilation, not
a check bolted onto a batch of pages. Everything downstream — link resolution, nav
derivation, layout rendering — consumes the validated graph and nothing else. In the
implementation this is a type-level fact: downstream stages accept `ValidatedGraph`, which
only the validator produces, so "compile without validating" is unrepresentable rather than
merely discouraged. There is no mode, flag, test path, or internal helper that bypasses
validation — not in v0, not ever.

The graph design itself is deliberately **not** frozen — parent semantics, multi-root
policy, and nav derivation may evolve. What is not negotiable is centrality: changes to
graph semantics are changes to the core artifact and land together with their proof surface.

The validator produces **evidence, not verdicts**. The certificate of forest shape is a
depth assignment: roots at depth 0, every other node exactly one deeper than its parent.
Such an assignment exists if and only if the parent structure is an acyclic forest, so an
artifact carrying coherent depths has no cycles, no self-parents, and no dangling parents —
by construction, not by traversal. Checking the certificate is structural recursion with no
mark bits and no fuel. (This is the leading formulation, not stone: if a better certificate
shape emerges, this paragraph changes — but the validator will always produce some
checkable certificate rather than a bare verdict.) The depth certificate already exists as
working verified code in `src/graph.bend` (`certificate_check`).

Order of checks, all errors aggregated before failing:

1. duplicate ids (including case-insensitive collisions);
2. parent references resolve to existing ids;
3. no parent cycles; no self-parent;
4. the result is a forest of rooted trees. Multiple roots are legal.

Validation is **sequential by design**. It is the join phase of a fork/join pipeline: per-page batch work is the
parallel stage; graph validation is a small sequential reduction over its results. Parallelizing this phase is
explicitly out of scope for v0 and is not a debt item.

## 5. Links — the flagship theorem's exact boundary

### 5.1 Classification

After the engine parses a page body, each link target found in the document is classified:

- **external**: has an RFC3986-style scheme — an ASCII letter followed by zero or more ASCII letters, digits,
  `+`, `-`, or `.`, then `:` — passed through untouched, outside all guarantees. This includes `mailto:`,
  `https:`, `tel:`, `data:`, and every other scheme; no scheme receives special publication semantics in v0;
- **internal page link**: has no scheme, ends in `.md` (before any `#fragment`), and is a relative reference;
- everything else (anchors-only `#x`, absolute `/` paths, non-md file references): passed through unchecked in
  v0, documented as unverified.

Target-bearing inline references produced by the engine — inline links, autolinks, and image sources — are all
classified by the same rules. Image assets are otherwise outside the v0 assets pipeline; classifying their
targets here prevents `.md` references from becoming unchecked publication links merely because they appear in
image syntax.

### 5.2 Resolution

An internal page link written in page `F` with engine-normalized AST target `T` resolves as pure path algebra:

1. split literal `#fragment` and `?query` delimiters before decoding — **fragments are passed through
   unvalidated in v0** (heading existence is not part of the theorem; see §8), and a query suffix on an internal
   page link is a content error;
2. percent-decode the remaining path portion exactly once as UTF-8. `%` therefore introduces a required
   two-hex-digit byte encoding in internal link paths; malformed percent sequences and percent-encoded bytes
   that do not form valid UTF-8 are content errors. Authors must write `%25` for a literal percent sign in a
   page-id path segment. Encoded delimiters such as `%23` and `%3F` decode into path text and are not treated
   as fragment/query delimiters;
3. join the decoded path against the directory of `F`'s id;
4. normalize dot segments (`.`, `..`) lexically after decoding, never touching the filesystem; encoded dot
   segments such as `%2E%2E` therefore have the same traversal meaning as literal `..`;
5. escaping above the content root (`..` past the root) is a content error;
6. the result must equal the id of an existing page plus `.md`.

### 5.3 Emission

Each emitted page carries, as part of the compile artifact model, the list of resolved internal target ids.
Rendered output rewrites internal `.md` targets to relative `.html` paths from the emitting page to the
resolved target page, preserving any `#fragment` suffix byte-for-byte as represented in the engine-normalized AST target.
The relative path is lexical and contains no leading `./`. Before HTML-attribute escaping, the generated path
(but not the author-supplied fragment suffix) is percent-encoded for URL output: structural `/` separators and
unreserved ASCII letters/digits/`-._~` remain literal, and every other character (including `%`, space, `?`,
`#`, and non-ASCII text) is encoded as uppercase hexadecimal UTF-8 `%XX` bytes. Output filenames themselves
remain the literal page-id filenames:

- `deep/page` linking `index.md` emits `../index.html`;
- `index` linking `deep/page.md#x` emits `deep/page.html#x`;
- sibling `deep/a` linking `b.md` emits `b.html`.

External and passthrough targets are emitted untouched. The emitted link list is what the flagship theorem
quantifies over. The HTML correspondence is established implementationally by rendering through the same
resolved-target rewrite function, and is tested end-to-end; unless and until the proof surface is extended to
the HTML serialization itself, artifact-level HTML correspondence is not claimed as a theorem.

### 5.4 The flagship law

> For every content tree and configuration, if compilation succeeds and emits publication `P`, then every
> resolved internal link carried by every emitted page of `P` names a page id emitted in `P`.

Broken internal links in a successful build are impossible **by theorem over the pure compile pipeline** — not
by a per-build audit. The filesystem, IO, and anything the user writes outside the markdown link grammar are
outside the boundary, as always.

## 6. Compile pipeline semantics

```text
discover (IO) → read+parse batch (parallel pure map over pages)
  → join: graph construction + validation (sequential; produces ValidatedGraph with depth certificate)
  → everything downstream consumes ValidatedGraph and nothing else:
    resolve links (pure) → render batch (parallel pure map) → write output tree (IO)
```

- Every compile — including the smallest smoke test in the repo — goes through the validator
  from day one. There is no pipeline shape in which pages reach rendering unvalidated.
- Parallel and sequential execution are the same function's two evaluation strategies; their equivalence is a
  proof obligation, not a test hope. `--seq` exists to measure and to cross-check.
- Determinism: same input bytes → same output bytes. No timestamps, no absolute paths, no environment leakage in
  output. Proven, not tested.
- On any content error: nonzero exit, structured diagnostics on stderr, and no partial output tree. Output is
  written completely to a fixed temporary sibling tree first. The host then uses a same-parent backup swap:
  move any existing output to a fixed sibling backup name, move the staged tree into place, and remove the
  backup. Build failure before the swap leaves the prior output tree untouched. A crash inside the swap may
  leave the backup for recovery; this is atomic-ish whole-tree publication, not a claim of strict atomic
  replacement of a non-empty directory. Temporary-tree cleanup is best-effort host IO and must not hide the
  original diagnostic.

## 7. Output

- `pubend build DIR` writes `DIR/dist/` by default. The build workspace is the canonical resolved `DIR` site
  root. A relative `--out` resolves against `DIR`; an absolute `--out` is accepted only when its canonical form
  remains inside the canonical site root. The host canonicalizes the longest existing prefix of the output path
  before making containment decisions, so case-only aliases and symlinked ancestors cannot make `content` or an
  outside directory look distinct. The output directory must not be the site root, `DIR/content`, or any
  descendant of `DIR/content`.
- The final path component of `OUT` must not end with `.pubend-lock`, `.pubend-stage`, or `.pubend-previous`,
  in any ASCII letter case. These names are reserved publication namespace. A violation is an exit-2
  `output-forbidden` path refusal.
- Page id `P` emits `P.html`. This mapping can be unrepresentable on every filesystem. For example, pages `a`
  and `a.html/x` require `a.html` to be both a file and a directory. The same failure applies when a page output
  requires a fixed host publication file such as `_pubend/manifest.json` or an ownership-marker path to be a
  directory. The host detects these shapes before writing and fails with exit 3 and an
  `output-path-collision` diagnostic. v0 does not define an alternate output mapping for these inputs.
- One layout shell for all pages. In order, the shell is `<!doctype html>`, an `<html lang="en">` element, a
  head containing exactly `<meta charset="utf-8">` and `<title>`, and a body containing one
  `<nav class="pubend-nav">` followed by `<main>` around the rendered fragment. The nav contains a parent link
  when the page has a parent, then a `<ul class="pubend-children">` child list. Child entries are li elements
  in emitted-page order restricted to that page's published children. Text and attribute values derived from
  titles, ids, and hrefs are HTML-escaped; raw HTML inside the markdown fragment remains engine-owned behavior.
  No theme system, no slots, no per-page layout selection in v0.
- The `<title>` is the frontmatter `title` when present, otherwise the text of the first level-1 heading when
  present, otherwise the page id.
- Parent/children navigation uses validated forest edges only. Draft pages render and may be linked to from
  content, but draft pages are excluded from all generated nav links: they appear neither in child listings nor
  as parent links.
- A thin per-build manifest `_pubend/manifest.json` inside the output tree. Its schema is deterministic JSON
  with exact key order and two-space indentation, ending in one newline: top-level `version`, then `pages`;
  each page entry contains `id`, `path`, then `sha256` in that order. `pages` is in emitted-page order, and
  `sha256` is the lowercase hex SHA-256 digest of the exact emitted HTML file bytes. `path` is the
  output-tree-relative HTML path (for example `deep/page.html`), not the source markdown path. JSON strings are
  UTF-8; only JSON-required escaping is applied. The manifest contains no timestamps or absolute paths. SHA-256 is
  trusted host glue in v0, not proof-covered Bend code. This records contingent facts only. Invariants are
  theorems and appear nowhere in runtime evidence.

### 7.1 CLI contract

- Exit codes are exact: `0` success; `1` input-tree or content validation failure; `2` command-line/path usage
  refusal; `3` host IO, environment, compiler-artifact, or output-publication failure.
- Successful builds write nothing to stdout or stderr. Failures write one UTF-8 JSON object to stderr followed
  by one newline: top-level keys `version`, `status`, then `diagnostics`, in that order. `version` is `1` and
  `status` is `error`. Each diagnostic object uses the stable key order `class`, `path`, `page`, `line`,
  `column`, `target`, `span`, `message`; unavailable scalar fields are `null` rather than omitted. `span`, when
  present, is an object with `start` and `end` engine-normalized UTF-8 offsets. Diagnostic classes align with
  the oracle taxonomy where the same condition exists.
- The fixed publication sibling names are `OUT.pubend-lock`, `OUT.pubend-stage`, and `OUT.pubend-previous`.
  These fixed names are implementation boundary details and never appear inside output content. An existing lock
  is a host failure and is never silently removed. A symlinked pre-existing output path is a host failure.
- Backup recovery belongs to publication attempts after input scanning and compilation succeed. It is not a
  standalone repair mode. The stage ownership marker is a regular file named `.pubend-incomplete-stage` whose
  exact bytes are `pubend incomplete stage owner v1` plus one newline. The backup ownership marker is a regular
  file named `.pubend-backup-owner` whose exact bytes are `pubend backup owner v1` plus one newline. After the
  lock is acquired, a pre-existing stage is removable only when it is a plain directory carrying the exact stage
  ownership marker. Otherwise the build fails with exit 3 and preserves that path. If output is absent and a
  backup exists, the host restores the backup only when it is a plain directory carrying the exact backup
  ownership marker. The host removes the backup marker before moving the backup back to `OUT`. A missing or
  invalid marker is an exit-3 failure and the path is preserved. If output and backup both exist, the build
  fails rather than choosing between them.
- The host writes the incomplete-stage marker immediately after creating the stage and removes it only after
  the stage is complete. Before swapping the stage into place, the host recursively validates the completed
  stage without following symlinks. Validation requires regular files and directories only, the exact expected
  directory and file sets, and exact bytes for every HTML file and the manifest. Neither ownership marker
  remains in a successfully published output tree.
- When moving an existing output to the fixed backup, the host renames it and then writes the backup ownership
  marker without overwriting an existing entry. A crash in that window can leave an unmarked backup. Later
  builds refuse to restore or remove that backup. This conservative outcome is required: refusing recovery is
  acceptable, deleting or overwriting foreign data is not.
- Input and output trees are required to be stable during a build. Portable Node cannot provide immunity to
  adversarial concurrent mutation. Post-stage validation is a mitigation that can reject an already-corrupted
  stage before publication; it is not a proof of race freedom.

## 8. Explicit non-goals for v0

fragment validation, watch/serve, editor, deploy targets, search, themes, multiple layouts, assets/images
pipeline, RSS/sitemap, RAG exports, Textile, Cooklang (fast-follow candidate, not v0), pretty URLs, frontmatter
beyond the closed key set, parallel graph validation, incremental compilation, alternate output path mappings
for file/directory collisions, adversarial concurrent-mutation immunity.

## 9. Failure behavior summary

Everything fail-loud with structured diagnostics: unknown/duplicate frontmatter keys, malformed frontmatter,
duplicate ids, dangling parent, parent cycle, link escaping content root, link to nonexistent page, malformed
percent triplets in internal links, invalid UTF-8 percent bytes in internal links, oversized input, invalid UTF-8,
symlinked entries, non-`.md` files in content. Diagnostics always carry a stable class
and, when available, content path/page id. Frontmatter diagnostics carry original-file line and column. Graph
diagnostics carry the involved page ids but have no source span in v0. Link diagnostics carry source page and
the engine-normalized AST target (not necessarily the author-written spelling) and, when exposed by the
engine, the engine-normalized markdown span offsets; those offsets are
best-available provenance, not guaranteed original-file line/column after reference stripping or newline
normalization. Input-tree diagnostics have paths but no line/column. Nothing fails silently; nothing is
best-effort.
