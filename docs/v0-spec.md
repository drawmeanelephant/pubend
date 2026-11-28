# pubend v0 specification

Status: locked unless marked **(open)**. This document is the unambiguous target for implementation.
Anything not specified here is out of scope, not implied.

## 1. Input tree

```text
DIR/
  content/          # the content root; all pages and assets live under here
    index.md
    guides.md
    guides/getting-started.md
    guides/cover.png
    ...
```

- A page candidate is a regular file under `content/` whose name ends in the exact lowercase suffix `.md`.
  Nested directories are allowed.
- An asset candidate is a regular file anywhere under `content/` whose final extension is in this allowlist:
  `.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.svg`, `.ico`, `.css`, `.woff`, `.woff2`. Asset extension matching
  is ASCII-case-insensitive, so `photo.JPG` is an asset candidate. Matching never changes the filename spelling.
- The final extension is the suffix of the final path component that starts at its last dot. A name with no dot
  has no extension. For a name such as `archive.tar.png`, the final extension is `.png`.
- Regular files whose final extension is `.js` or `.html`, compared ASCII-case-insensitively, are forbidden.
  Regular non-`.md` files with any other extension, with no extension, or with a trailing dot are unknown
  content files. Both forms are input-tree errors. They are never copied.
- A hidden entry is any file, directory, symlink, or other entry whose final path component begins with `.`.
  Hidden entries are input-tree errors. A hidden directory is not traversed after its own diagnostic.
- Symlinked entries under `content/` are input-tree errors. The compiler neither follows nor silently skips
  them. This applies equally to symlinks naming files, symlinks naming directories, and dangling symlinks.
- Entries that are neither regular files nor directories nor symlinks are input-tree errors.
- A regular file is executable when any owner, group, or other execute bit is set in its filesystem mode.
  Executable regular files are input-tree errors, whether they name pages, assets, or unknown content files.
  This is a mode-bit rule only. The compiler does not sniff file contents for executability.
- Every entry name under `content/` must be valid UTF-8. An invalid UTF-8 name is an input-tree error. The
  compiler does not read a file with an invalid name and does not traverse a directory with an invalid name.
- Input entry validation produces at most one inventory diagnostic for each entry. The first matching class in
  this order wins: `invalid-utf8-name`, `hidden-entry`, `symlinked-entry`, `unsupported-entry-type`,
  `executable-content-file`, `forbidden-asset-extension`, `unknown-asset-extension`. Page and asset size or
  content diagnostics come after this classification. For a page candidate, the size check precedes UTF-8
  decoding, so an oversized page produces only `oversized-page`. For an asset candidate, the size check produces
  only `oversized-asset`.
- Nothing outside `content/` is read. There is no configuration file in v0.
- Maximum input size per page: 1 MiB, exactly 1,048,576 bytes. A page of exactly 1 MiB is accepted. Over-limit
  is a content error, not a crash. The ceiling is part of the proof-integrated boundary pattern inherited from
  bendown.
- Maximum input size per asset: 1 MiB, exactly 1,048,576 bytes. An asset of exactly 1 MiB is accepted. An
  over-limit asset is not copied.
- Maximum combined asset input size: 16 MiB, exactly 16,777,216 bytes. The total is the sum of the sizes of all
  asset candidates that pass the per-entry rules and the per-asset size ceiling. Pages do not count toward this
  total. Oversized assets do not count toward this total because they are not accepted asset candidates. A total
  of exactly 16 MiB is accepted. Exceeding the total is one inventory-wide input error.
- Page bytes must be valid UTF-8. Invalid UTF-8 is a content error; lossy replacement characters must not be
  introduced by the input boundary.
- Asset bytes are opaque. They are not UTF-8-validated, parsed as CSS or SVG, content-type-checked, or otherwise
  interpreted. The extension allowlist is an inventory policy, not a claim about the asset's contents.
- Discovery order is deterministic: within each directory, host entry names are ordered byte-wise. For valid
  UTF-8 names this order agrees with Unicode code-point order. Non-directory entries are processed before child
  directories, then child directories are traversed in that same order. This depth-first discovery order is the
  input page order and, after successful validation, the emitted-page order. The same traversal filtered to
  accepted assets is the input asset order. Compilation preserves both orders rather than reordering entries.

## 2. Page and asset identity — path-derived, no aliasing

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
- An asset's identity is its path relative to `content/`, including the filename and extension, using forward
  slashes: `content/guides/cover.png` has asset path `guides/cover.png`. Asset paths are exact and
  case-sensitive. ASCII-case-insensitive extension recognition does not normalize the path.
- Assets are not graph nodes. They have no frontmatter, parent, status, title, or nav entry.
- Output mapping: asset path `A` emits `A` unchanged in the output tree. The output preserves the exact path
  spelling. No content-addressed rewriting, fingerprinting, bundling, or asset-directory prefix exists in v0.

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

## 5. Links and asset references — the flagship theorem's exact boundary

### 5.1 Typed target inventory and classification

After the engine parses a page body, pubend classifies target-bearing values exposed through bendown's typed
`DocumentLink` API. The covered target fields are exactly `ILink.href`, `IAutolink.href`, and `IImage.src`.
Inline links, autolinks, and image sources therefore use the same classification rules. Pubend must not scan
markdown source, raw HTML, rendered HTML, or asset bytes with regular expressions or a parallel parser.

The **path portion** of a target is the longest prefix before the first literal `#` or `?`. Classification uses
this literal spelling before percent decoding. Each target is classified as follows:

- **external**: has an RFC3986-style scheme — an ASCII letter followed by zero or more ASCII letters, digits,
  `+`, `-`, or `.`, then `:` — passed through untouched, outside all guarantees. This includes `mailto:`,
  `https:`, `tel:`, `data:`, and every other scheme; no scheme receives special publication semantics in v0;
- **internal page target**: has no scheme, does not start with `/`, and has a path portion ending in the exact
  lowercase suffix `.md`;
- **internal asset target**: has no scheme, does not start with `/`, and has a path portion whose final
  extension is in the asset allowlist, using the same ASCII-case-insensitive extension comparison as input
  inventory;
- **passthrough**: everything else, including anchor-only `#x` targets, absolute `/` paths, empty targets,
  non-`.md` references whose final extension is outside the asset allowlist, and references whose extension
  appears only after percent decoding. For example, `image%2epng` is passthrough because its literal path
  portion does not end in `.png`.

### 5.2 Resolution

An internal page or asset target written in page `F` with engine-normalized AST target `T` resolves as pure
path algebra. The first failing step produces the target's only resolution diagnostic:

1. split literal `#fragment` and `?query` delimiters before decoding. The first literal `#` starts the fragment.
   A literal `?` before that `#` is a query. A literal `?` after that `#` is fragment text. **Fragments are
   passed through unvalidated in v0** (heading existence is not part of the theorem; see §9). A query on any
   checked internal target is a `link-query` content error;
2. percent-decode the remaining path portion exactly once as UTF-8. `%` therefore introduces a required
   two-hex-digit byte encoding in internal target paths; malformed percent sequences produce
   `link-malformed-percent`, and percent-encoded bytes that do not form valid UTF-8 produce
   `link-invalid-percent-utf8`. Authors must write `%25` for a literal percent sign in a content path segment.
   Encoded delimiters such as `%23` and `%3F` decode into path text and are not treated as fragment/query
   delimiters;
3. join the decoded path against the directory of `F`'s id;
4. normalize dot segments (`.`, `..`) lexically after decoding, never touching the filesystem; encoded dot
   segments such as `%2E%2E` therefore have the same traversal meaning as literal `..`;
5. escaping above the content root (`..` past the root) is a `link-root-escape` content error;
6. for an internal page target, the result must equal the id of an existing page plus `.md`; otherwise the
   diagnostic is `link-nonexistent-page`. For an internal asset target, the result must exactly equal the asset
   path of an emitted asset; otherwise the diagnostic is `link-nonexistent-asset`. Asset path membership is
   exact and case-sensitive even though extension classification is ASCII-case-insensitive.

All accepted assets are emitted assets. There is no reference-only asset selection in v0.

### 5.3 Emission

Each emitted page carries, as part of the compile artifact model, the list of resolved internal targets. The
model distinguishes resolved page ids from resolved asset paths.

Rendered output rewrites internal `.md` targets to relative `.html` paths from the emitting page to the
resolved target page. Rendered output rewrites internal asset targets to relative asset paths from the emitting
page to the resolved asset output. Both rewrites preserve any `#fragment` suffix byte-for-byte as represented in
the engine-normalized AST target.

The relative path is lexical and contains no leading `./`. Before HTML-attribute escaping, the generated path
(but not the author-supplied fragment suffix) is percent-encoded for URL output: structural `/` separators and
unreserved ASCII letters/digits/`-._~` remain literal, and every other character (including `%`, space, `?`,
`#`, and non-ASCII text) is encoded as uppercase hexadecimal UTF-8 `%XX` bytes. Output filenames themselves
remain the literal page-id or asset-path filenames:

- `deep/page` linking `index.md` emits `../index.html`;
- `index` linking `deep/page.md#x` emits `deep/page.html#x`;
- sibling `deep/a` linking `b.md` emits `b.html`;
- `deep/page` linking `image.png` emits `image.png`;
- `deep/page` linking `./image.png` emits `image.png`;
- `deep/page` linking `../shared/logo.png#mark` emits `../shared/logo.png#mark`;
- `index` linking `deep/image.png` emits `deep/image.png`.

External, passthrough, and raw HTML targets are emitted untouched. The emitted target list is what the flagship
theorem quantifies over. The HTML correspondence is established implementationally by rendering through the
same resolved-target rewrite function, and is tested end-to-end; unless and until the proof surface is extended
to the HTML serialization itself, artifact-level HTML correspondence is not claimed as a theorem.

### 5.4 The extended flagship law

> For every content tree and configuration, if compilation succeeds and emits publication `P`, then every
> resolved internal target carried by every emitted page of `P` is either a page target whose page id is emitted
> in `P` or an asset target whose asset path is emitted in `P`.

Broken internal page links and broken checked asset references in a successful build are impossible **by
theorem over the pure compile pipeline** — not by a per-build audit. The filesystem, IO, and anything the user
writes outside the typed markdown target boundary are outside the boundary, as always.

### 5.5 Boundary exclusions

The extended law does not quantify over:

- external targets with schemes, absolute `/` paths, anchor-only targets, empty targets, or passthrough
  references whose extensions are outside the asset allowlist;
- references whose asset extension appears only after percent decoding;
- raw HTML nodes, raw passthrough blocks, or HTML-looking text that bendown does not expose as `ILink.href`,
  `IAutolink.href`, or `IImage.src`;
- attributes attached to spans, blocks, tables, or other typed AST nodes;
- references inside asset bytes, including CSS `url()` references or SVG references;
- fragment existence or fragment semantics;
- rendered HTML serialization as a theorem. End-to-end artifact audits establish the implementation-level HTML
  correspondence instead;
- filesystem behavior after emission, web-server behavior, URL decoding by a server or browser, or later
  mutation of the output tree.

## 6. Compile pipeline semantics

```text
discover + validate input inventory + read pages/assets (IO)
  → parse page batch (parallel pure map over pages)
  → join: graph construction + validation (sequential; produces ValidatedGraph with depth certificate)
  → everything downstream consumes ValidatedGraph and nothing else:
    resolve typed targets (pure) → render page batch (parallel pure map) + form asset copy requirements (pure)
    → write output tree and copy asset bytes (IO)
```

- Every compile — including the smallest smoke test in the repo — goes through the validator
  from day one. There is no pipeline shape in which pages reach rendering unvalidated.
- Parallel and sequential execution are the same function's two evaluation strategies; their equivalence is a
  proof obligation, not a test hope. `--seq` exists to measure and to cross-check.
- Assets do not participate in graph validation. Asset paths participate in typed target resolution only after
  the graph validates.
- Reading pages and assets, writing pages, copying assets, and computing output digests are host IO or trusted
  host glue. The pure compile core works only over values already supplied by the host and never touches the
  filesystem.
- Asset copying is byte-for-byte. The compiler does not transcode, minify, optimize, bundle, concatenate,
  rewrite, validate, or metadata-normalize asset bytes. Every accepted asset is copied, even when no markdown
  target references it.
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
  outside directory look distinct. Whether a differently cased spelling is such an alias is filesystem-dependent:
  on a case-sensitive tree it is a distinct output name, while exact `DIR/content` remains forbidden everywhere.
  The output directory must not be the site root, `DIR/content`, or any
  descendant of `DIR/content`.
- The final path component of `OUT` must not end with `.pubend-lock`, `.pubend-stage`, or `.pubend-previous`,
  in any ASCII letter case. These names are reserved publication namespace. A violation is an exit-2
  `output-forbidden` path refusal.
- Page id `P` emits `P.html`. Asset path `A` emits `A`. Fixed publication files also occupy output paths.
  For collision preflight, the output requirement set contains one regular-file requirement for every emitted
  page, one regular-file requirement for every emitted asset, and one regular-file requirement for each fixed
  host path `_pubend/manifest.json`, `.pubend-incomplete-stage`, and `.pubend-backup-owner`. Every file
  requirement also requires each proper directory prefix of its output-relative path.
- An output path collision occurs when any of these shapes is present:

  1. two file requirements own the same output-relative path;
  2. a file requirement path equals a proper directory prefix required by another file requirement;
  3. two distinct directory spellings required by file requirements differ only by ASCII letter case and alias
     on the output filesystem.

  Comparisons use exact path bytes on a case-sensitive output filesystem. On a filesystem where ASCII case-only
  names alias, comparisons also fold ASCII letter case. For example, page `a` emits the file `a.html`, while an
  asset `a.html/logo.png` requires `a.html` to be a directory. An asset `_pubend/manifest.json/logo.png`
  requires the fixed file `_pubend/manifest.json` to be a directory. The host detects these shapes before
  writing and fails with exit 3 and an `output-path-collision` diagnostic. On a case-sensitive tree differently
  cased output names remain distinct. v0 does not define an alternate output mapping for these inputs.
- Copied asset output bytes are exactly the input asset bytes. Output file metadata is not part of the
  publication artifact contract: copying does not promise preservation of permission bits, ownership, or
  timestamps. Output asset files are regular files in the stage and final output trees.
- One layout shell for all pages. In order, the shell is `<!doctype html>`, an `<html lang="en">` element, a
  head containing exactly `<meta charset="utf-8">` and `<title>`, and a body containing one
  `<nav class="pubend-nav">` followed by `<main>` around the rendered fragment. The nav contains a parent link
  when the page has a parent, then a `<ul class="pubend-children">` child list. Child entries are li elements
  in emitted-page order restricted to that page's published children. Text and attribute values derived from
  titles, ids, and hrefs are HTML-escaped; raw HTML inside the markdown fragment remains engine-owned behavior.
  No theme system, no slots, no per-page layout selection, and no automatic stylesheet injection in v0.
- The `<title>` is the frontmatter `title` when present, otherwise the text of the first level-1 heading when
  present, otherwise the page id.
- Parent/children navigation uses validated forest edges only. Draft pages render and may be linked to from
  content, but draft pages are excluded from all generated nav links: they appear neither in child listings nor
  as parent links.
- A thin per-build manifest `_pubend/manifest.json` inside the output tree. Its schema is deterministic JSON
  with exact key order and two-space indentation, ending in one newline: top-level `version`, then `pages`,
  then `assets`. The schema version is integer `2`. Each page entry contains `id`, `path`, then `sha256` in
  that order. `pages` is in emitted-page order, and page `sha256` is the lowercase hex SHA-256 digest of the
  exact emitted HTML file bytes. Page `path` is the output-tree-relative HTML path (for example
  `deep/page.html`), not the source markdown path. Each asset entry contains `path`, then `sha256` in that
  order. `assets` is in input asset order, is always present even when empty, and asset `sha256` is the
  lowercase hex SHA-256 digest of the exact copied asset file bytes. Asset `path` is the output-tree-relative
  asset path, which equals the content-relative asset path in v0. Empty `pages` and `assets` arrays serialize
  as `[]` on one line. JSON strings are UTF-8; only JSON-required escaping is applied. The manifest contains no
  timestamps or absolute paths. SHA-256 is trusted host glue in
  v0, not proof-covered Bend code. This records contingent facts only. Invariants are theorems and appear
  nowhere in runtime evidence.

### 7.1 CLI contract

- Exit codes are exact: `0` success; `1` input-tree or content validation failure; `2` command-line/path usage
  refusal; `3` host IO, environment, host bootstrap/build, compiler-artifact, or output-publication failure.
- Successful builds write nothing to stdout or stderr. Once the publication host has started, failures write
  one UTF-8 JSON object to stderr followed by one newline: top-level keys `version`, `status`, then
  `diagnostics`, in that order. `version` is `1` and
  `status` is `error`. Launcher bootstrap failures before a host binary exists — for example a missing pinned
  Bend toolchain or a failed native host build — cannot satisfy this JSON envelope and instead fail loudly in
  plain stderr with exit 3. For structured host failures, each diagnostic object uses the stable key order
  `class`, `path`, `page`, `line`,
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
  directory and file sets, and exact bytes for every HTML file, copied asset, and manifest. Neither ownership
  marker remains in a successfully published output tree.
- When moving an existing output to the fixed backup, the host renames it and then writes the backup ownership
  marker without overwriting an existing entry. A crash in that window can leave an unmarked backup. Later
  builds refuse to restore or remove that backup. This conservative outcome is required: refusing recovery is
  acceptable, deleting or overwriting foreign data is not.
- Input and output trees are required to be stable during a build. A portable user-space host cannot provide
  immunity to adversarial concurrent mutation. Post-stage validation is a mitigation that can reject an
  already-corrupted stage before publication; it is not a proof of race freedom.

## 8. Required fixture matrix

The implementation must add positive and negative fixtures with these names and evidence. Large binary,
non-UTF-8-name, FIFO, and some collision fixtures may be synthetic harness inputs when a physical checked-in
fixture would be oversized or unrepresentable. Positive fixtures must prove exact copied bytes, canonical href
emission, manifest order, manifest digests, and repeated-build determinism. Negative fixtures must prove the
required exit code, diagnostic class, and absence of a partial output tree.

### 8.1 Positive fixtures

| fixture | required evidence |
|---|---|
| `valid-asset-root-basic` | a root `.png` asset referenced from `index.md` is copied byte-for-byte, its href is canonical, and its manifest entry is correct |
| `valid-asset-nested-relative` | sibling, `./`, and `../` asset references from nested pages resolve lexically and emit correct relative paths with no leading `./` |
| `valid-asset-all-extensions` | one file for every allowlisted extension is accepted and copied byte-for-byte |
| `valid-asset-case-extension` | an uppercase or mixed-case allowlisted extension is accepted, the filename spelling is preserved, and the exact-case reference resolves |
| `valid-asset-unreferenced` | an accepted asset with no markdown reference is still copied and appears in the manifest |
| `valid-asset-opaque-contents` | binary bytes that are not valid UTF-8 and CSS or SVG text containing unchecked internal references are copied exactly without diagnostics |
| `valid-asset-unicode-percent` | asset names containing spaces, non-ASCII text, and literal `%` round-trip through strict percent-decoded input links and canonical uppercase `%XX` output hrefs |
| `valid-asset-fragment` | a fragment on a checked asset reference is preserved byte-for-byte, including a literal `?` after `#` |
| `valid-asset-order-manifest` | assets in nested directories appear in manifest `assets` order exactly as defined by input asset order |
| `valid-asset-passthrough-boundary` | external-scheme, absolute-path, anchor-only, unknown-extension, empty, and percent-encoded-extension targets remain untouched and do not fail; percent-encoded-extension cases cover both missing and present decoded asset paths |
| `valid-asset-raw-html-exclusion` | asset-like targets in raw HTML remain untouched and do not fail even when their apparent files are absent |
| `valid-asset-ceiling-boundary` | an empty asset, an exactly 1 MiB asset, and a synthetic exactly 16 MiB accepted-asset total are accepted |

### 8.2 Negative fixtures

| fixture | required class and exit |
|---|---|
| `asset-hidden-file` | `hidden-entry`, exit 1 |
| `page-hidden` | `hidden-entry`, exit 1 |
| `asset-hidden-directory` | `hidden-entry`, exit 1, with the hidden directory pruned after its own diagnostic |
| `asset-symlink-file` | `symlinked-entry`, exit 1 |
| `asset-symlink-directory` | `symlinked-entry`, exit 1 |
| `asset-symlink-dangling` | `symlinked-entry`, exit 1 |
| `asset-invalid-utf8-name` | `invalid-utf8-name`, exit 1 |
| `asset-unsupported-entry-type` | `unsupported-entry-type`, exit 1 |
| `asset-executable` | `executable-content-file`, exit 1 |
| `page-executable` | `executable-content-file`, exit 1 |
| `asset-js` | `forbidden-asset-extension`, exit 1 |
| `asset-html` | `forbidden-asset-extension`, exit 1 |
| `asset-forbidden-uppercase` | `forbidden-asset-extension`, exit 1 for `.JS` or `.HTML` spelling |
| `asset-unknown-extension` | `unknown-asset-extension`, exit 1 |
| `asset-no-extension` | `unknown-asset-extension`, exit 1 |
| `asset-trailing-dot` | `unknown-asset-extension`, exit 1 |
| `asset-oversized` | `oversized-asset`, exit 1 for a 1,048,577-byte asset |
| `asset-total-oversized` | `oversized-asset-total`, exit 1 for a synthetic total above 16 MiB with no individual asset above 1 MiB |
| `link-nonexistent-asset` | `link-nonexistent-asset`, exit 1 |
| `link-asset-query` | `link-query`, exit 1 |
| `link-asset-root-escape` | `link-root-escape`, exit 1 |
| `link-asset-malformed-percent` | `link-malformed-percent`, exit 1 |
| `link-asset-invalid-percent-utf8` | `link-invalid-percent-utf8`, exit 1 |
| `asset-page-file-directory-collision` | `output-path-collision`, exit 3 for page `a.md` plus asset `a.html/logo.png` |
| `asset-fixed-file-directory-collision` | `output-path-collision`, exit 3 for asset `_pubend/manifest.json/logo.png` |
| `asset-output-case-alias-collision` | `output-path-collision`, exit 3 for page `A.md` plus asset `a.html/logo.png` on an ASCII-case-insensitive output filesystem; case-sensitive hosts must treat the same shape as a distinct-output control |

## 9. Explicit non-goals for v0

fragment validation, watch/serve, editor, deploy targets, search, themes, multiple layouts, RSS/sitemap, RAG
exports, Textile, Cooklang (fast-follow candidate, not v0), pretty URLs, frontmatter beyond the closed key set,
parallel graph validation, incremental compilation, alternate output path mappings for file/directory
collisions, adversarial concurrent-mutation immunity, asset transformation or optimization, asset minification,
asset bundling or concatenation, cache-busting fingerprints, content-addressed asset paths, responsive image
generation, image `srcset` inference, automatic stylesheet injection, parsing or rewriting inside CSS/SVG/font
files, MIME sniffing, media-type validation, security sanitization, executable preservation, asset metadata
preservation, reference counting or elision of unreferenced assets, configurable asset allowlists, assets outside
`content/`, JavaScript or HTML assets, validation of external or absolute targets, validation or rewriting of raw
HTML targets.

## 10. Failure behavior summary

Everything fail-loud with structured diagnostics: unknown/duplicate frontmatter keys, malformed frontmatter,
duplicate ids, dangling parent, parent cycle, link escaping content root, link to nonexistent page or asset,
malformed percent triplets in internal targets, invalid UTF-8 percent bytes in internal targets, oversized input,
invalid UTF-8 page bytes, invalid UTF-8 entry names, hidden entries, symlinked entries, unsupported entry types,
executable content files, forbidden asset extensions, unknown content files, and output path collisions.
Diagnostics always carry a stable class and, when available, content path/page id. Frontmatter diagnostics carry
original-file line and column. Graph diagnostics carry the involved page ids but have no source span in v0.
Link diagnostics carry source page and the engine-normalized AST target (not necessarily the author-written
spelling) and, when exposed by the engine, the engine-normalized markdown span offsets; those offsets are
best-available provenance, not guaranteed original-file line/column after reference stripping or newline
normalization. Per-entry input-tree diagnostics have paths but no line/column. Inventory-wide input-tree
diagnostics may have a `null` path. Nothing fails silently; nothing is best-effort.

The asset-related diagnostic classes and required field population are exact:

| class | exit | required fields |
|---|---|---|
| `invalid-utf8-name` | 1 | `path` is the content-relative diagnostic display path; `page`, `line`, `column`, `target`, and `span` are `null` |
| `hidden-entry` | 1 | `path` is the exact content-relative path; `page`, `line`, `column`, `target`, and `span` are `null` |
| `unsupported-entry-type` | 1 | same field shape as `hidden-entry` |
| `executable-content-file` | 1 | same field shape as `hidden-entry` |
| `forbidden-asset-extension` | 1 | same field shape as `hidden-entry` |
| `unknown-asset-extension` | 1 | same field shape as `hidden-entry` |
| `oversized-asset` | 1 | same field shape as `hidden-entry` |
| `oversized-asset-total` | 1 | `path`, `page`, `line`, `column`, `target`, and `span` are `null`; the message carries the byte total and ceiling |
| `link-nonexistent-asset` | 1 | `path` is the source page's content-relative markdown path, `page` is the source page id, `target` is the engine-normalized AST target, `line` and `column` are `null`, and `span` is the engine-normalized span when exposed, otherwise `null` |
| `link-query` | 1 | same field shape as `link-nonexistent-asset` |
| `link-root-escape` | 1 | same field shape as `link-nonexistent-asset` |
| `link-malformed-percent` | 1 | same field shape as `link-nonexistent-asset` |
| `link-invalid-percent-utf8` | 1 | same field shape as `link-nonexistent-asset` |
| `output-path-collision` | 3 | `path` is the output-root-joined first colliding path; `page` is the descendant page id when that owner is a page, otherwise `null`; `target` is the ancestor page id when that owner is a page, otherwise `null`; `line`, `column`, and `span` are `null`; the message names both output requirements and their owner kinds |

For `invalid-utf8-name`, the diagnostic display path is byte-wise lossy: ASCII bytes are preserved as ASCII
characters and every non-ASCII byte is replaced by U+FFFD when the complete content-relative path is not valid
UTF-8. This display path is diagnostic provenance, not a reversible filename.

Input diagnostics follow the deterministic scan order of the entries that produce them. The
`oversized-asset-total` diagnostic, when present, follows the per-entry inventory diagnostics. Compile-stage
diagnostics keep the existing stage order: frontmatter, then graph validation, then typed target resolution.

The former `non-md-file` class is not part of the amended asset contract. Regular files that are neither pages
nor accepted assets are classified as forbidden, executable, unknown, hidden, invalidly named, or unsupported
according to the rules above.
