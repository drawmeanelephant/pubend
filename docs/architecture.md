# pubend architecture — car and engine

Status: founding document, 2026-11-27. Working assumptions open to revision are marked **(decision)**.

## The doctrine

pubend is to bendown what Boris is to Oliver: **the car that harnesses the engine.**

| layer | Boris world | pubend world |
|---|---|---|
| engine | Oliver — pure Zig markup library: bytes → typed document → deterministic HTML. No filesystem, no templates, no site logic | **bendown** — pure Bend markup engine with machine-checked implementation laws |
| car | Boris — graph-native publication compiler: discovery, frontmatter, graph validation, layouts, output, evidence, CLI | **pubend** — proof-carrying publication compiler |

The doctrine's rules, adapted from the Oliver boundary:

1. The engine never touches the filesystem, the network, the clock, or the concept of a "site." It parses and
   renders documents and proves things about those pure transformations.
2. The car never reimplements markup parsing. If the engine can't express a construct, the engine grows; the car
   does not regex around it.
3. The boundary is a typed document model with source spans, so the car can produce real diagnostics without
   re-reading the engine's mind.
4. The engine is consumable without the car; the car is meaningless without the engine.

## The dependency mechanics (measured, not assumed)

Bend 2.0.40 import facts, verified by experiment:

- `import ./x.bend as M` — works for paths below the importing file.
- `import ../x.bend` — works for paths above the importing file in Bend 2.0.40; `src/compile.bend` imports
  `../engine/src/parser/markdown.bend` this way. The earlier note that upward-relative imports were rejected was
  wrong.
- Absolute filesystem paths are **rejected by the compiler**.
- `import 0x<hash>/main.bend as P` — content-hash package import from BendHub, checked against the hash. This is
  the analog of Oliver's hash pin in Boris's `build.zig.zon`.
- `import name@version/main.bend` — named hub package; publishing is **public and permanent**, and `--publish`
  bundles everything the entry file imports.

Consequence: during development, bendown must physically live inside pubend's tree. Options:

- **git submodule at `engine/`** — keeps bendown's own repo, history, and release identity; imports read
  `import ./engine/src/ast.bend as Ast`. Closest to the Boris/Oliver relationship. **(recommended)**
- vendored copy with manual sync — simpler, but invites drift exactly like a regex around the parser would.
- monorepo merge — abandons the engine as a separately consumable product, which contradicts the doctrine.

Current dependency pin: `engine/` is the bendown git submodule at commit
`49701b8b33ec40d404b159434c51f601161046b3`. Pubend deliberately uses bendown's public typed AST constructors
plus `document_links.bend` to perform publication-owned link target rewriting before rendering. Upstream's later
pure render-time rewrite hook (merged as bendown PR #10) remains optional; adopting it would be a separate pin
and integration decision rather than a requirement for the current design.

Release discipline, later: publish bendown to BendHub, pin pubend to `0x<hash>`. Not now — publishes are
permanent and public, and both sides are moving.

## The boundary allocation

### Engine (bendown) owns

- Markdown/Textile/Cooklang parsing into typed documents with spans (already: `src/parser/`, `src/ast.bend`)
- deterministic document-fragment HTML rendering (already: `src/render/html.bend`)
- Cooklang recipe model, canonical serialization, exact-rational scaling (already proven slice)
- input ceiling enforcement with proofs (already: `parse_*_bounded` laws)
- pure parallel combinators (`seq_map`/`par_map`, `par_tree_map`) **with their equivalence proofs** — generic
  library code the car will reuse
- the laws and proofs about all of the above

### Car (pubend) owns

- filesystem discovery, reading, output writing, containment of the output tree
- frontmatter parsing and author-facing metadata grammar — it is publication metadata, not document content
- page identity, the parent graph, topology validation, and diagnostics with file/line positions
- site-level link resolution: the engine exposes link targets with spans; the car resolves them against the page
  graph. (bendown's batch prototype already has this shape — `document_link_targets` in the engine,
  concatenation in the batch layer.)
- layout/page composition around engine-rendered fragments
- batch orchestration, CLI, machine-readable artifacts
- its own LAWS/PROOF files covering car-side invariants

### Host implementation boundary (current)

The product host is native Bend. `./pubend` is only a portable shell bootstrapper: it resolves the checkout,
verifies the pinned Bend 2.0.40 toolchain, selects a content-addressed binary under the gitignored
`.pubend-cache/`, transparently builds `host/hostmain.bend` when that content hash has no cached binary, and
then `exec`s the binary. The default product path uses shell/POSIX utilities at launch time, the Bend compiler
only when the selected host binary is missing, and the native binary afterwards. It does not use Node.js, Bun,
or another JavaScript runtime.

`host/` is the filesystem-facing car shell. `hostmain.bend` orchestrates CLI parsing, canonical path
resolution, input scanning, in-process `compile_report`, and publication. `HostFS.bend` isolates syscalls in
custom foreign effects whose ABI is pinned to Bend 2.0.40; `host_eff.c` backs the native binary and
`host_eff.js` remains paired with those declarations for non-product JavaScript/interpreter lanes. The pure
compile pipeline in `src/` remains pure over pre-loaded `SourcePage` values. Foreign effects and host
orchestration are outside the proof-imported dependency graph and must stay there.

`tools/pubend.mjs` is demoted to a temporary reference oracle and migration harness. It is not a product
scaffold and must not receive new product behavior except behavior-preserving oracle corrections. The
differential host-parity lane is the migration evidence: positive corpus sites, physical negative fixtures, and
CLI boundary probes run through both hosts at the same paths with fixtures reset between runs, comparing exit
codes, stdout bytes, stderr bytes, and post-run filesystem trees exactly. When the project deliberately retires
that oracle, removal must be a separate reviewed change rather than a hidden side effect of host work.

This is not a claim of perfect operating-system isolation. The host still requires stable input/output trees,
does not provide adversarial concurrent-mutation immunity, and has not exhaustively fault-injected every rare
errno path. Those limits are explicit residuals, not hidden proof obligations.

### Migration pressure inside bendown

`src/parallel/batch.bend` (pure combinators + proof) is engine library code — stays. `src/parallel/engine.bend`
(file discovery via `/usr/bin/find`, extension dispatch, batch application) is a car-shaped application living in
the engine repo — its pure parts should be harvested for pubend, and bendown's own CLI should shrink to a
document-tool surface. This is not urgent, but the direction matters: bendown-as-engine means its center of
gravity is the library, not the CLIs.

## Proof architecture

Bend proof obligations are compile-time checked only where they are actually imported and discharged. Pubend
therefore does **not** claim that compiling `src/compile.bend` automatically re-verifies every separate
`engine/PROOF.bend` obligation. The honest current meaning of proof-carrying is narrower: pubend's own
`LAWS.bend` obligations are discharged in pubend's `PROOF.bend` and report `ALL PROOFS CHECK` under Bend's
checker. BendTT/Lean kernel-level validity is explicitly not claimed unless `PROOF.bend --verdict` succeeds.

Product pattern, inherited from bendown:

- `LAWS.bend` states claims; humans write it, implementation agents do not touch it (bendown convention).
- `PROOF.bend` fills them; `bend PROOF.bend` must print `ALL PROOFS CHECK`; `--verdict` (independent Lean
  kernel) once Lean is installed.
- Runtime proof cost is zero — proof witnesses are erased.

The flagship pubend law, the one that justifies the product: **every internal link in a successfully compiled
publication resolves to an emitted page** — as a theorem over the pure compile pipeline, not a per-build runtime
check. (External links and the filesystem itself remain outside the proof boundary forever.)

## Dialect scope **(decision)**

Evidence-based proposal: **Markdown only at first.** bendown measured 623/652 CommonMark with gaps concentrated
in tabs/links/block quotes/lists — closing those is engine work that benefits both products. Cooklang is the
strongest second dialect (60/60 canonical fixed-point, proven scaling laws) and a real differentiator — candidate
for fast-follow. Textile (46/107 Oliver fixture families) is explicitly deferred; do not advertise it.

## v0 shape **(decision)**

The smallest thing that is genuinely a publication compiler and not a demo:

```text
pubend build DIR [--out OUT]
```

- input: `content/` tree of `.md` files with minimal frontmatter (`title`, optional `parent`, `status`)
- graph: unique ids, parent forest validation, fail-loud spanned diagnostics
- compile: pure batch over pages with sequential semantics in v0; parallel/sequential implementations and their
  byte-equivalence evidence are explicitly deferred
- output: deterministic HTML tree — engine fragments inside one layout shell; internal links resolved and
  rewritten; broken internal links are impossible **by proof**, not by audit
- artifacts: one thin per-build manifest (what was emitted, digests) — contingent facts only; invariants are
  theorems, not evidence
- explicitly out: watch/serve, editor, deploy targets, search, themes plural, RSS/sitemap/RAG, textile

## Open design questions

1. ~~Frontmatter format~~ **resolved**: minimal closed `key: value` grammar, see [v0-spec.md](v0-spec.md) §3.
2. ~~Page identity~~ **resolved**: path-derived ids, no aliasing — which makes link resolution pure path algebra
   and the flagship theorem much easier to state. See [v0-spec.md](v0-spec.md) §2.
3. Layout mechanism: single fixed shell in v0. The slot model is where complexity lives; resist it.
4. How much of bendown's batch engine to harvest vs. rewrite against pubend's graph model.
5. ~~Graph validation parallelism~~ **resolved**: sequential by design — but note what is and isn't being
   decided. Graph validation is **first-class and central from day one**: the validated graph is the core
   artifact of the whole compiler, downstream stages consume `ValidatedGraph` and nothing else, and the
   validator produces a checkable depth certificate rather than a bare verdict (working code already in
   [../src/graph.bend](../src/graph.bend), law in [../LAWS.bend](../LAWS.bend)). What is deferred — permanently,
   unless evidence demands otherwise — is only *parallelizing* the validation pass itself: it is the join
   phase of a fork/join pipeline, and per-page batch work is where the parallelism lives. The graph design
   (parent semantics, multi-root policy, nav derivation) is deliberately not frozen; the centrality is not
   negotiable. See [v0-spec.md](v0-spec.md) §4.

Current implementation state is maintained in [../README.md](../README.md) and [v0-spec.md](v0-spec.md); those
documents supersede early scaffold notes here when they differ.

## Evidence base

All measurements and citations backing this document: 
[_evaluation/pubend-standalone-evaluation.md](/Users/tbuddy/.t3/projects/pubend/_evaluation/pubend-standalone-evaluation.md)
and [_evaluation/bend-integration-evaluation.md](/Users/tbuddy/.t3/projects/pubend/_evaluation/bend-integration-evaluation.md).
Key numbers: Boris proof_pack ≈ 50% of a 5k-page build (the cost of runtime evidence); bendown batch parallel
speedup 4.27× verified byte-identical; bendown CommonMark 623/652; Cooklang 60/60; per-core throughput gap vs
Oliver is the kill-switch risk and the first thing to measure.
