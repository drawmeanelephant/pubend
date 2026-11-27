# Boris × Bend/bendown architectural evaluation

> **Framing correction (2026-11-27):** this evaluation interpreted the proposal as integration into Boris.
> The actual project is a standalone Boris-adjacent compiler in Bend. The evidence and measurements here
> remain valid, but the recommendation framing is superseded by
> [pubend-standalone-evaluation.md](/Users/tbuddy/.t3/projects/pubend/_evaluation/pubend-standalone-evaluation.md).

Date: 2026-11-27. Reviews are pinned at Boris `76756a92d7fce1f997ab260233e535cf42653584`, bendown `30a68e645a4560b9a5128c95f19ce38f09ab3969`, Oliver `e0c5a4031b1dee514b7c8dab46a2dac640645f78`.

## Executive recommendation

**Recommendation: no production integration now.** If evidence is still desired, run a **small, external IR-auditing proof of concept** (option B) outside Boris's authority boundary. Do not emit Boris-branded IR from Bend, do not make Boris consume that artifact, and do not present the prototype as a second verification product.

Why:

1. **Boris already owns the source-authority pipeline.** Its validation contract says Boris compiler modules are the sole authorities for discovery/source parsing/graph validation/render validation and forbids reproducing those rules with a second parser, regexes, script policy, or subprocess build ([validation.md:19](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/validation.md:19)). A Bend source compiler or authority-bearing auditor would duplicate exactly that authority.
2. **bendown is not yet a dialect replacement.** In local measurements at the pinned revision it scored **623/652** on the CommonMark corpus, **60/60** on Cooklang fixed-point serialization, and **46/107** on Oliver's Textile fixture wall. Oliver's documented/current evidence is **652/652 CommonMark**, a fully green Textile fixture wall, and **60/60 Cooklang** ([CAPABILITIES.md:14](/Users/tbuddy/.t3/projects/pubend/_evaluation/oliver/docs/CAPABILITIES.md:14), [TESTS.md:397](/Users/tbuddy/.t3/projects/pubend/_evaluation/oliver/docs/TESTS.md:397)).
3. **Measured Boris HTML-build bottleneck is not Markdown parsing.** On a 5,000-page bounded-nav corpus, median total was **6.258 s** at `--jobs 1` and **5.621 s** at `--jobs 8` (1.11× total); render improved **0.923 s → 0.293 s** (3.15×), while `proof_pack` stayed **~3.14 s** and became **55.9%** of total. Parse was only **~0.114 s**. Therefore neither Bend CPU parallelism nor GPU execution is presently justified as a Boris bottleneck intervention.
4. **GPU fit is poor for this workload.** Bend's own guide says parallel branches must run in roughly equal time, tasks are assigned once and never moved, and divergent work stays faster on CPU ([GUIDE.md:147](/Users/tbuddy/.bend/guide/GUIDE.md:147), [GUIDE.md:155](/Users/tbuddy/.bend/guide/GUIDE.md:155), [GUIDE.md:164](/Users/tbuddy/.bend/guide/GUIDE.md:164)). Lexer/parser/graph workloads are branchy, data-dependent, and irregular.
5. **Option C is research, not integration.** A proof-carrying micro-SSG could prove implementation invariants of pure functions, but cannot by type checking prove that untrusted source bytes are valid, that files exist, that rendered HTML matches deployment state, or that a remote publication succeeded.

## Corrected architecture map

### Boris authority and pipeline

- CLI commands and stdout behavior are contractual. `--timings` is observation-only, emitted as JSON even on failed runs, and never a correctness authority ([cli.md:510](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/cli.md:510)).
- The normal compiler path loads/parses source through `loadAndPromote*`, freezes the graph, then renders and validates HTML in `compile.zig`; timing hooks identify scan/parse/graph/dependency/fingerprint/render/search/link/evidence phases ([compile.zig:1268](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/compile.zig:1268), [compile.zig:2475](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/compile.zig:2475), [compile.zig:3378](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/compile.zig:3378)).
- Graph construction is explicit and sequential: duplicate IDs are diagnosed before topology validation ([graph.zig:215](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/graph.zig:215)); freeze sorts nodes by ID, assigns indices, rebuilds parent indices and edges, and marks the graph frozen ([graph.zig:442](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/graph.zig:442)); nav requires sorted nodes and coherent `index == position` ([graph.zig:527](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/graph.zig:527)).
- `export_scope.zig` is explicitly a projection layer: the pipeline remains sole parser/validator ([export_scope.zig:1](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/export_scope.zig:1)).
- IR is an export artifact family. `build --out DIR` writes `manifest.json`, `graph.json`, `completion.json`, and `build-report.json` ([cli.md:395](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/cli.md:395)). Nodes carry identity/topology metadata and `bodyOffset`, not full bodies ([ir-schema.md:387](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/ir-schema.md:387)). `graph.json` deliberately omits compiler identity ([ir-schema.md:647](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/ir-schema.md:647)); deterministic emission is contractual, while cross-OS bit identity is not claimed ([ir-schema.md:247](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/ir-schema.md:247)).

### Oliver boundary

Oliver is a pure, deterministic, freestanding Zig markup library; Boris consumes it in-process, never as a subprocess ([oliver-renderer.md:18](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/oliver-renderer.md:18)). Oliver's own architecture excludes filesystem, templates, and site logic. Boris already uses this pinned native path and also has bounded Textile/Cooklang input modes.

### Validation/evidence surfaces

These are distinct:

- `validate`: zero-write prepublication validation through the shared HTML source/configuration/render boundary; it rejects `--jobs` and produces no artifacts except optional `--report` ([cli.md:106](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/cli.md:106), [cli.md:112](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/cli.md:112)).
- `check` / `impact`: read-only Documentation Intelligence over a valid frozen graph; they do not create product artifacts ([cli.md:106](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/cli.md:106)).
- publication evidence: artifacts/checks/claims/touches chain over emitted target bytes.
- Proof Pack: presentation/packaging over the four committed evidence files. It must not rerun checks, reread payloads, inspect deployment, infer source provenance, repair, or upgrade evidence status ([publication-proof-pack.md:29](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/publication-proof-pack.md:29)). It reads only exact committed artifacts/checks/claims/touches bytes ([publication-proof-pack.md:70](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/publication-proof-pack.md:70)).

### Embedding and Cloudflare Worker

`compileBundle` accepts in-memory source files and emits memory artifacts; the memory provider/sink do not scan a host directory ([embedding.md:81](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:81), [embedding.md:96](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:96)). HTML is sequential in this profile (`jobs` stays 1) ([embedding.md:118](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:118)). The Wasm unsupported list includes threads/jobs/watch/Textile/Cooklang/live deploy/proof-pack/WASI filesystem ([embedding.md:239](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:239), [embed_wasm.zig:242](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/embed_wasm.zig:242)).

The Cloudflare host is glue owning HTTP/request limits/R2 while the module owns compilation ([hosts/cloudflare-worker/README.md:7](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/hosts/cloudflare-worker/README.md:7)). There **is** live CPU evidence: 4 ms warm compile+upload CPU, 1 ms compile-only CPU, 39 ms cold CPU charged to startup, and ~1.2–1.4 s wall dominated by R2 writes ([README.md:115](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/hosts/cloudflare-worker/README.md:115)). There is **not** measured isolate peak memory evidence; the contract explicitly says peak memory is bounded by the 128 MiB cap but not measured below it ([embedding.md:260](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:260)).

### bendown architecture

- Single-document CLI requires explicit `--from markdown|textile|cooklang`; there is no mixed-dialect auto-normalization in one document ([main.bend:197](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/src/main.bend:197)).
- Batch mode selects independent per-file dialects by extension `.md`, `.textile`, `.cook`; unknown extensions become empty output rather than a mixed parse ([engine.bend:313](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/src/parallel/engine.bend:313), [engine.bend:345](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/src/parallel/engine.bend:345)).
- Batch parallelism is balanced tree fork/join with order-preserving append; the implementation itself warns that halving is sequential and that this demonstrates structure/determinism, not automatically performance ([engine.bend:75](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/src/parallel/engine.bend:75)). File reads are fibers, while the pure transformation is the multicore stage ([engine.bend:592](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/src/parallel/engine.bend:592)).
- Directory discovery shells out to POSIX `/usr/bin/find`, so that part is host integration rather than portable pure Bend ([engine.bend:640](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/src/parallel/engine.bend:640)).
- Batch is a separate executable because linking both command surfaces exceeds the current Bend compiler machine stack ([batch_cli.bend:4](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/src/batch_cli.bend:4)).

## Claim table

| Claim | Verdict | Evidence |
|---|---|---|
| 1. Boris IR is emitted output, not accepted input to `compileBundle` | **Confirmed** | `compileBundle` takes source files and emits memory artifacts; no IR ingestion path appears in the embedding contract ([embedding.md:81](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:81)). |
| 2. `compileBundle` parses/validates/freezes source and can emit IR, HTML, evidence | **Confirmed** | M3 IR, optional HTML, M6 evidence chain ([embedding.md:105](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:105), [embedding.md:118](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:118), [embed_evidence.zig:59](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/embed_evidence.zig:59)). |
| 3. Current IR omits full bodies, HTML, layouts, theme assets, RAG payloads/render inputs | **Confirmed** | graph nodes carry `bodyOffset` but no body; no HTML/layout/theme asset payload in IR artifact set ([ir-schema.md:387](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/ir-schema.md:387)). |
| 4. Embed Wasm is sequential, Markdown-only; unsupported features as listed | **Confirmed** | Feature/unsupported metadata ([embed_wasm.zig:242](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/embed_wasm.zig:242)); contract table ([embedding.md:239](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/embedding.md:239)). |
| 5. Cloudflare host is example glue with conservative limits; live/peak evidence exists | **Partly confirmed, partly refuted** | Glue/limits confirmed. Live CPU/wall evidence exists; measured isolate peak does not. |
| 6. validate/check/evidence/Proof Pack are distinct surfaces | **Confirmed** | Distinctions documented and implementation separated; see architecture map. |
| 7. Boris already uses pinned Zig Oliver and bounded Textile/Cooklang modes | **Confirmed** | Oliver native in-process seam ([oliver-renderer.md:18](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/docs/contracts/oliver-renderer.md:18)); Oliver capabilities/conformance ([CAPABILITIES.md:14](/Users/tbuddy/.t3/projects/pubend/_evaluation/oliver/docs/CAPABILITIES.md:14)). |
| 8. Boris phases have different computational shapes; measure before performance claims | **Confirmed** | Measured phase distribution below: IR core, validate, render, evidence presentation all differ. |
| bendown offers comparable or novel Markdown/Textile/Cooklang coverage | **Refuted at pinned revision** | bendown measured 623/652 CommonMark and 46/107 Textile fixtures vs Oliver 652/652 and fully green fixture wall. Cooklang fixed-point is strong at 60/60. |
| Bend parallelism implies Boris should parallelize more or use GPU | **Refuted as currently stated** | Only render parallelizes cleanly; proof_pack dominates and GPU is poor for divergent parser/graph work. |
| External Bend artifact may truthfully carry `compiler: "boris/x.y.z"` | **Refuted** | Unless bytes were produced by that Boris compiler pipeline, the field is false provenance. `graph.json` deliberately lacks compiler identity; other artifact producer fields must not be copied as a claim of Boris execution. |
| IR auditing can validate source correctness or deployment correctness | **Refuted** | IR lacks source bytes/render inputs/deployment state. It can check internal artifact coherence only. |

## Bend-provable vs non-provable facts

### Pure/proof-friendly after boundary decoding

Assuming a checked JSON decoder preserves exact ordering and duplicates where relevant, these can be modeled and checked/proved over `graph.json` plus sibling IR artifact bytes:

- schema version/facet coherence;
- object/key ordering and canonical byte round-trip where byte order is contractual;
- unique node IDs, including case-policy diagnostics where represented;
- node sort order by ID and `node.index == array position`;
- parent references resolve; parent forest shape is acyclic; role rules agree with root/parent state;
- `parent` ID ↔ `parentIndex` coherence;
- edge endpoint typing, endpoint resolution, edge uniqueness and canonical ordering;
- reverseIndex is an exact inversion of the edge multiset/set under the contract's semantics;
- nav derivation consistency, if nav semantics are formalized exactly;
- cross-artifact consistency among manifest/graph/completion/build-report fields when all exact bytes are supplied.

These are **implementation invariant checks over an artifact**, not validation of the source publication.

### Not provable from IR alone

- that source bytes parse to this graph;
- that `bodyOffset` points at particular source content;
- Markdown/Textile/Cooklang correctness or rendered HTML correctness;
- layout/theme/asset existence or byte correctness;
- wiki/include/link resolution against real source files;
- output tree completeness, deployment state, remote target state, or freshness;
- proof-pack claims about the real publication;
- authorship, compiler provenance, time of build, or absence of tampering;
- memory/CPU behavior of a host isolate;
- validation of untrusted input merely because data has a typed representation.

### False provenance and hypothetical IR ingestion

An external artifact labeled `compiler: "boris/x.y.z"` is false provenance unless that Boris compiler actually produced it: the label denotes producer identity and pipeline semantics, not merely schema shape. Copying schema bytes does not transfer authority. A credible external artifact must use a distinct producer identity and, at most, cite input artifact digests.

A hypothetical future IR-ingestion contract would need at least:

1. full source bytes or content-addressed source/body blobs;
2. input-format and dialect/facet declarations;
3. layouts, theme files, static/content-local assets, includes, profile/options, and target definitions;
4. exact provenance: producer identity/version, input digests, toolchain/pins, and a trust label distinguishing authoritative Boris output from unaudited external input;
5. schema versioning and migration/rejection rules;
6. strict boundary validation: size caps, UTF-8, path identity/canonicalization, duplicate/missing references, graph shape, resource limits, and deterministic error semantics;
7. a rule that indexes/proposed graph state are hints or evidence, never trusted substitutes for running Boris validation.

## Measurements performed

Artifacts: [boris-5000-benchmark.json](/Users/tbuddy/.t3/projects/pubend/_evaluation/bench/boris-5000-benchmark.json), [boris-5000-mode-benchmark.json](/Users/tbuddy/.t3/projects/pubend/_evaluation/bench/boris-5000-mode-benchmark.json), [bendown-commonmark.json](/Users/tbuddy/.t3/projects/pubend/_evaluation/bench/bendown-commonmark.json), [bendown-textile-fixtures.json](/Users/tbuddy/.t3/projects/pubend/_evaluation/bench/bendown-textile-fixtures.json), [bendown-cooklang-fixedpoint.json](/Users/tbuddy/.t3/projects/pubend/_evaluation/bench/bendown-cooklang-fixedpoint.json), [bendown-batch-benchmark.json](/Users/tbuddy/.t3/projects/pubend/_evaluation/bench/bendown-batch-benchmark.json).

### Boris 5,000-page synthetic corpus

Generator: `bounded-nav-v1`, seed 20260801; input tree ~22 MB, 5,004 content files; output tree 34,420,776 bytes in 5,009 files. Machine: macOS arm64, 10 logical CPUs, Zig 0.17.1 ReleaseSafe. Five alternating runs per side. All exit codes 0; output trees byte-identical across jobs.

| median phase | jobs 1 | jobs 8 | interpretation |
|---|---:|---:|---|
| total | 6.258 s | 5.621 s | 1.11× total |
| proof_pack | 3.134 s | 3.144 s | dominant, apparently sequential/outside render parallelization |
| render | 0.923 s | 0.293 s | 3.15× phase speedup |
| heading_harvest | 0.334 s | 0.332 s | unchanged |
| checks | 0.333 s | 0.334 s | unchanged |
| graph_validate | 0.266 s | 0.266 s | unchanged |
| dependency_resolve | 0.229 s | 0.230 s | unchanged |
| search | 0.149 s | 0.153 s | unchanged |
| parse | 0.114 s | 0.115 s | small share |
| fingerprint | 0.096 s | 0.095 s | small share |

Counters: `page_reads` 20,000, `link_resolutions` 29,581, `hash_bytes` 9,739,011 in both configurations. Ranges were narrow except one jobs-8 outlier; see JSON artifact.

Mode medians (3 runs each):

- IR-only `--out`: **0.498 s** total, dominated by graph validation 0.188 s, dependency resolution 0.147 s, parse 0.121 s.
- zero-write `validate`: **4.633 s** total, dominated by render 3.604 s; `validate` rejects `--jobs`, so this is intentionally sequential.

Caution: these measurements do not prove whether `proof_pack` is CPU-, allocation-, JSON-, or I/O-limited. They do prove that render parallelism is not the current whole-build limiter for this corpus. A further profile must name that limiter before optimizing.

### bendown conformance/performance

- CommonMark corpus: **623/652**. Weak sections included Tabs 3/11, Links 79/90, Block quotes 22/25, Images 20/22, Code spans 21/22, Setext headings 26/27, Link reference definitions 26/27, List items 46/48.
- Cooklang canonical fixed-point serialization: **60/60**.
- Oliver Textile fixture wall: **46/107**. This is not a normative Textile corpus; it measures coverage of Oliver's documented fixture families, many of which bendown has not implemented.
- Batch benchmark: 64 synthetic Markdown files / 803,648 input bytes; 5 alternating runs per mode; byte-identical outputs, zero errors; wall median sequential **1.044 s**, parallel **0.245 s**, speedup **4.27×**. This is real evidence for bendown's narrow batch transformation, not evidence that a Boris-like whole pipeline would speed up.

## Option evaluation

### A. Source-level interop — not recommended

A Bend normalization tool emitting canonical Boris-authorable source could be useful for migration, but current evidence does not show superiority over Oliver/Boris paths. Mixed-dialect normalization is especially hazardous: dialects have overlapping markup and incompatible escaping/attribute/raw HTML semantics. Lossless migration requires provenance sidecars or explicit per-file dialect boundaries; otherwise normalization loses the information needed to reconstruct original source or diagnose misparse. bendown's incomplete CommonMark/Textile coverage makes fidelity claims premature. Its Cooklang serialization evidence is the strongest slice, but Boris already has bounded Cooklang input through Oliver.

Smallest useful experiment here would be a dialect-specific migration fixture suite, not integration: choose 20–50 real legacy documents, run bendown normalization, compile originals and outputs through Boris, diff diagnostics/graph/rendered HTML, and record lossless-provenance cases. Do not ship as a compiler path.

### B. IR auditing — conditionally recommended as a proof of concept

This is the least harmful experiment because it consumes exported artifacts and does not mutate Boris authority. Its value is narrow: mechanically check artifact coherence and explore whether Bend's proof style can represent graph invariants. It must be labeled an external audit, not Boris validation.

A credible 1–2 week experiment:

1. write a boundary-checked streaming or bounded JSON decoder for the IR subset;
2. model nodes/endpoints/edges/reverseIndex/nav in Bend;
3. implement executable checks first;
4. prove one or two small pure lemmas, such as exact inversion for a constructor-level graph model or equivalence of sequential and parallel checking;
5. run against committed valid and intentionally corrupted IR fixtures;
6. report false positives/negatives and runtime, including input sizes;
7. never emit `compiler: boris/...`; use `producer: bendown-ir-audit/...` plus input artifact digests.

A type-only sketch is at [bend-ir-sketch.bend](/Users/tbuddy/.t3/projects/pubend/_evaluation/bend-ir-sketch.bend). It typechecks with `bend` and prints `ALL PROOFS CHECK`, but that is **vacuous** because the file declares no laws; `--verdict` was not run because Lean is not installed. It is a proof-of-concept data model, not a Boris-compatible ingest format.

### C. Standalone proof-carrying micro-SSG — research only

Inside the proof boundary could be pure transformations: document AST construction, escaping, canonical serialization, graph algebra, ordering, and perhaps render algebra for a deliberately tiny markup subset. Outside the boundary remain untrusted input bytes, filesystem discovery, symlinks/case behavior, layout/theme/asset bytes, process/network effects, deployment, and host resource use. Implementation correctness proofs do not validate external content. A malicious or merely invalid input still requires boundary validation, diagnostics, caps, and rejection paths.

This option would duplicate a large part of Boris if used as a real SSG. It is defensible only as a deliberately small research artifact with no Boris identity or migration promise.

## Measurement plan going forward

1. Use Boris's generator corpora, not ad hoc examples: bounded-nav and full-nav profiles; at least small (3–25 pages), medium (~1,000), and large (~5,000) trees.
2. For each corpus and mode (`html`, `validate`, IR `--out`, RAG/context if relevant), run at least 5 alternating repetitions per configuration after one warmup. Record median and min/max, exit codes, stderr, counters, output bytes/files, and tree digest.
3. Compare `--jobs 1` with a tuned `--jobs` value on the same host; do not default to CPU count blindly. Verify byte identity and count errors.
4. Name the limiter before optimizing. For `proof_pack`, separate CPU/allocations/serialization/file I/O using tracing/profiling and byte counts. Do not infer I/O merely because outputs are large.
5. Measure incremental cold/warm behavior separately; do not mix cache states.
6. For bendown comparisons, use identical input bytes and equivalent work. A batch Markdown-to-HTML benchmark is not equivalent to Boris's graph+layout+search+link-audit+evidence pipeline.
7. GPU claims require a uniform numeric kernel benchmark first. Parser/graph lexer-like workloads should be presumed CPU-side unless a prototype contradicts Bend's own divergence guidance.
8. Record machine, CPU count, load, Zig/Bend versions, optimization modes, exact corpora seeds, command lines, and output digests. Treat one-off wall-clock results as anecdotes.

## Bottom line

The strongest technically legitimate intersection is **external, read-only IR auditing as an experiment**. It may produce evidence about Bend's proof ergonomics and graph-invariant checking. It should not be confused with Boris validation, should not become a second authority, and currently has no measured performance or conformance justification for replacing any Boris/Oliver compiler component.
