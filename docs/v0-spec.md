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
- Nothing outside `content/` is read. There is no configuration file in v0.
- Maximum input size per page: 1 MiB. Over-limit is a content error, not a crash. The ceiling is part of the
  proof-integrated boundary pattern inherited from bendown.

## 2. Page identity — path-derived, no aliasing

- A page's **id** is its path relative to `content/`, without the `.md` extension, using forward slashes:
  `content/guides/getting-started.md` → id `guides/getting-started`.
- Ids are exact and case-sensitive. Two files whose ids differ only by case are a duplicate-id error (portable
  correctness on case-insensitive filesystems).
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

- **external**: contains `://`, or starts with `mailto:` — passed through untouched, outside all guarantees;
- **internal page link**: ends in `.md` (before any `#fragment`), is a relative reference;
- everything else (anchors-only `#x`, absolute `/` paths, non-md file references): passed through unchecked in
  v0, documented as unverified.

### 5.2 Resolution

An internal page link written in page `F` with raw target `T` resolves as pure path algebra:

1. strip any `#fragment` suffix — **fragments are passed through unvalidated in v0** (heading existence is not
   part of the theorem; see §8);
2. if the target contains a query suffix `?...`, reject it as a content error; queries on static pages are
   meaningless in v0;
3. join `T` against the directory of `F`'s id;
4. normalize dot segments (`.`, `..`) lexically, never touching the filesystem;
5. escaping above the content root (`..` past the root) is a content error;
6. the result must equal the id of an existing page plus `.md`.

### 5.3 Emission

Each emitted page carries, as part of the compile artifact model, the list of resolved internal target ids.
Rendered output rewrites internal `.md` hrefs to the corresponding `.html` output paths. The emitted link list
is what the flagship theorem quantifies over.

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
- On any content error: nonzero exit, spanned diagnostics on stderr, and no partial output tree (write to temp +
  atomic-ish rename, or refuse to write at all on failure — **(open)**).

## 7. Output

- `pubend build DIR` writes `DIR/dist/` by default; `--out` overrides but must stay inside the workspace.
- One layout shell for all pages: `<title>`, rendered fragment, simple parent/children nav derived from the
  validated forest. No theme system, no slots, no per-page layout selection in v0.
- A thin per-build manifest `dist/_pubend/manifest.json`: emitted page ids and digests. This records contingent
  facts only. Invariants are theorems and appear nowhere in runtime evidence.

## 8. Explicit non-goals for v0

fragment validation, watch/serve, editor, deploy targets, search, themes, multiple layouts, assets/images
pipeline, RSS/sitemap, RAG exports, Textile, Cooklang (fast-follow candidate, not v0), pretty URLs, frontmatter
beyond the closed key set, parallel graph validation, incremental compilation.

## 9. Failure behavior summary

Everything fail-loud with spanned diagnostics: unknown/duplicate frontmatter keys, malformed frontmatter,
duplicate ids, dangling parent, parent cycle, link escaping content root, link to nonexistent page, oversized
input, non-`.md` files in content. Nothing fails silently; nothing is best-effort.
