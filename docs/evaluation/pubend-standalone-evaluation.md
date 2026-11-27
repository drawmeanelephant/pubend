# Standalone Bend publication compiler — corrected evaluation

Date: 2026-11-27. **This document corrects and supersedes the recommendation framing of
[bend-integration-evaluation.md](/Users/tbuddy/.t3/projects/pubend/_evaluation/bend-integration-evaluation.md).**
The evidence gathered there (measurements, conformance scores, contract citations) stands; the framing does not.

## The correction

The first evaluation treated the proposal as *feeding into Boris* — integration, migration, or ingestion — and
therefore judged it against Boris's internal architecture policy (sole validation authority, no parallel
verification product). That was a misinterpretation.

The actual proposal: a **standalone, Boris-adjacent publication compiler written in Bend** — working name *pubend* —
that takes design inspiration from Boris's problem space (graph-native publications, deterministic output,
validation as a first-class surface) but is its own product with its own authority, its own dialect story, and a
different central bet: **machine-checked implementation invariants** instead of a runtime evidence chain.

Under this framing:

- Boris's "sole authority" policy is irrelevant as a constraint. It binds Boris's repo, not a separate product.
  The *engineering wisdom* behind it (don't let two implementations of the same rules drift) still applies at any
  future interop surface, but there is no authority conflict inside pubend: pubend is its own sole authority.
- "Not a clone" means the goal is not feature parity with Boris. The interesting question is what the same problem
  looks like when the foundation is a dependently-typed, proof-carrying, parallel-by-construction language — and
  which of Boris's hard-won design lessons transfer.
- The measured Boris evidence changes meaning: it is no longer a verdict on integration, it is **design input** —
  a map of where the costs and complexity in this problem space actually live.

## What the Boris measurements teach a new design

From the 5,000-page corpus measurements (details in the original evaluation):

1. **Per-build runtime evidence is the most expensive thing Boris does.** `proof_pack` was ~3.14 s of a 6.26 s
   build — half the total — and evidence-adjacent phases (`inventory`, `checks`, `claims`, `touches`) add more.
   This is the cost of establishing correctness claims *at runtime, per build, in an unverified implementation*.
   It is also a per-build tax every user pays forever. This is the single strongest evidence that pubend's
   differentiating bet has a real target: invariants proved once, at compile time of the *compiler*, do not
   re-cost every build.
   - Honest boundary: proofs cover **invariant** claims (true of every build). They cannot cover **contingent**
     per-build facts (which files existed, what bytes were emitted, whether this deployment succeeded). Boris's
     evidence chain mostly records contingent facts. So proofs do not eliminate artifact records — they eliminate
     the need for runtime re-checking of properties that are actually invariants. Part of the design work is
     sorting Boris's evidence taxonomy into those two buckets.
2. **Sequential pipeline phases dominate even when render parallelizes.** `--jobs 8` gave render 3.15× but total
   only 1.11×. A new design should be parallel-by-construction across the whole pipeline from day one, not
   retrofitted into one phase. bendown already proves `par_map == seq_map` for batch transformation
   ([LAWS.bend:38](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/LAWS.bend:38)) — that is the seed.
3. **Parsing is cheap in Boris (~2% of total).** But that is because Oliver is extremely fast Zig, not because
   parsing is inherently cheap. pubend cannot assume the same distribution; see the performance risk below.
4. **Graph validation is structurally sequential in Boris** (single-threaded DFS, [graph.zig:283](/Users/tbuddy/.t3/projects/pubend/_evaluation/boris/src/graph.zig:283))
   and costs 0.27 s at 5k pages — more than parse. Whether forest validation can be parallelized or need not be
   (see design questions) is a genuine open design point where pubend could differ.
5. **The Cloudflare embedding evidence** (compile CPU ~1 ms warm; wall dominated by R2 at ~1 s/object) says
   in-process compile speed is rarely the user-visible bottleneck for hosted publishing anyway — I/O is. Performance
   ambition should be scoped accordingly: pubend needs to be *fast enough*, not faster than Boris.

## What pubend should adopt from Boris (ideas, not code)

Boris's contracts are a compressed record of mistakes already made and fixed. Worth adopting deliberately:

- **Graph-native content model.** Some form of explicit parented page graph with validated topology, rather than
  a folder of unrelated pages. Whether Trunk/Satellite exactly, or a simpler forest, is a design choice — but the
  validated-graph-as-center idea is the core of the problem space.
- **Determinism as contract.** Canonical ordering, no timestamps, byte-identical repeated builds. In pubend this
  is not just a contract — determinism is *provable*, and bendown already proves it for parse and render
  ([LAWS.bend:22](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/LAWS.bend:22)).
- **Validation as a first-class, fail-loud surface** with structured diagnostics, rather than best-effort rendering.
- **Bounded input grammars.** Boris's Textile/Cooklang adapters show the value of explicit, documented, bounded
  dialect slices rather than "support everything."
- **Output containment and idempotent builds.** Boris's workspace-containment and artifact rules exist because
  compilers write trees; a new design should have the equivalent from the start.
- **The phase taxonomy as measurement infrastructure.** Boris's `--timings` exists because earlier optimization
  work was done blind. pubend should have timing/observability built in before it needs it.

## What pubend should deliberately not do (the not-a-clone line)

- No editor, watch server, deployment targets, publication profiles, RAG/context exports, Nostr/ATProto — those
  are Boris's product surface, and replicating any of them is clone-work with none of the leverage.
- No multi-dialect breadth ambition at the start. bendown's measured coverage (623/652 CommonMark, 46/107 Oliver
  Textile fixtures) says dialect depth is expensive. Pick the smallest honest dialect surface.
- No runtime evidence chain mimicking artifacts/checks/claims/touches/proof-pack. pubend's bet is that a large
  class of those claims becomes compile-time proof obligations. What remains is a thin per-build manifest.
- No aspirational feature surface beyond what the proof core covers. The product's identity is *small and proved*,
  not *broad*.

## The differentiating bet, precisely stated

**A publication compiler whose implementation invariants are machine-checked, where the interesting guarantees
are things Boris can only test or runtime-check:**

1. **Determinism** — already proven in bendown for parse/render.
2. **Parallel/sequential equivalence** — already proven for batch map; extend across the whole pipeline, so
   parallelism is not a performance flag but a semantics-preserving implementation detail.
3. **Output internal-link integrity** — the flagship candidate. If page emission, link extraction, and link
   resolution are all pure functions inside the proof boundary, then "a successfully compiled publication contains
   no broken internal links" is a *theorem*, not a test result. Boris runtime-checks this class of property per
   build; pubend could prove it once. External links are inherently outside.
4. **Graph shape preservation** — emitted nav/structure is a correct function of the validated parent forest:
   breadcrumb/children/sibling coherence by construction.
5. **Escaping/serialization safety** — output escaping is total: no raw injection path except explicit,
   type-marked passthrough.
6. **Bounded-resource behavior** — input ceilings and fuel-bounded recursion are already proof-integrated in
   bendown's style ([LAWS.bend:12](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/LAWS.bend:12)).

And the honest negative space, unchanged from the first evaluation: proofs do **not** validate external content.
A malformed input file, a missing asset, a filesystem race, a symlink attack, a non-UTF-8 byte stream — all of
these require boundary validation with good diagnostics regardless of how much of the implementation is proved.
Type checking does not eliminate input validation; it eliminates whole classes of *implementation* error.

## Central feasibility risks (honestly weighted)

### 1. Text throughput — the big one

Bend strings are linked lists of Unicode characters. That representation is allocation-heavy and cache-hostile,
and parsing/rendering is nothing but string work. Orders of magnitude, from measurements taken:

- bendown batch (parse + render + link extraction, sequential): ~803 KB input in ~1.04 s → order of **1 MB/s** per core.
- Boris/Oliver parse phase: ~0.11 s for the multi-MB parse workload of a 5,000-page corpus → tens of MB/s per core.

Even with perfect parallel scaling on 10 cores, a 10–100× per-core deficit is not erased by parallelism — and
Bend's fork/join scheduler has no work stealing, so real skew costs extra. bendown's measured 4.27× batch
speedup (64 files, byte-identical output, zero errors) proves the parallel structure works; it does not prove the
throughput is competitive.

**This is the make-or-break engineering question for pubend.** Possible mitigations: packed byte/text
representations inside hot loops (with proofs over a logical string model), fusion, avoiding string
concatenation in favor of output streaming, and parallelism. But if the language/runtime can't get within an
acceptable factor of "fast enough," the product fails regardless of proof quality — *unless* the product is
explicitly scoped to small-to-medium publications where absolute compile time is already a second-scale concern,
not a minute-scale one. Note the Cloudflare lesson: hosted publishing is I/O-dominated anyway.

**First experiment must measure this, not assume it.**

### 2. Bend compiler scaling

bendown already had to split its CLI into two binaries because linking both command surfaces exceeds the Bend
compiler's machine stack ([batch_cli.bend:4](/Users/tbuddy/.t3/projects/pubend/_evaluation/bendown/src/batch_cli.bend:4)).
A publication compiler is substantially larger than bendown today. Whether Bend 2.0.40 can compile a program of
that size in one binary — or whether the product ships as cooperating binaries — is an open constraint, not a
detail.

### 3. Proof ergonomics at scale

bendown's proofs exist but the AGENTS notes record real friction: no mutual recursion, fuel patterns, match
restrictions, affine-value plumbing, constructor inference failures. Scaling laws and batch equivalence were
provable; whole-compiler invariants are a larger surface. `--verdict` (the independent Lean kernel check) isn't
even wired up yet locally. The proof surface should grow incrementally with the implementation, never as a
big-bang retrofit.

### 4. Missing infrastructure

No JSON parser/serializer exists in bendown yet (confirmed: no JSON module in `src/`). Publication compilers
need machine-readable output. This is buildable but is real work, and JSON parsing is itself a boundary-validation
problem.

### 5. Dialect coverage

623/652 CommonMark with weaknesses concentrated in tabs, links, block quotes, lists — i.e., the hard core of the
spec, not the edges. Closing to full conformance is unglamorous work, but "proof-carrying compiler that misrenders
nested block quotes" is a bad product story: implementation proofs are only as valuable as the correctness of the
specification they implement. The good news: conformance work and proof work are independent and parallelizable
across time.

## Revised verdict on the three original options

- **A (source-level interop / migration into Boris):** out of scope for pubend as a product. Could exist someday
  as a utility, but it is not the product and not the interesting bet.
- **B (IR auditing of Boris artifacts):** reframed — not a product, but possibly a *useful early proof-exercise*
  and a source of invariant candidates. Boris's IR schema is a well-specified, externally documented graph
  contract, which makes it good practice material for exactly the graph-invariant proofs pubend wants
  (id uniqueness, sorting, reverseIndex inversion, nav coherence). Treat it as a training ground, not a feature.
- **C (standalone compiler):** this is the product direction, with the corrections above. The evaluation
  question is no longer "does this duplicate Boris's authority" — it is "is the proof-carrying bet worth the
  performance and maturity risks, and what is the smallest version that demonstrates it."

## The smallest experiment that produces real evidence (1–2 weeks)

Not "build the SSG." Three parallel tracks, each independently evaluable:

**Track 1 — Throughput ceiling (the kill-switch measurement).** Benchmark bendown parse+render throughput per
core on a realistic Markdown corpus vs Oliver on the same bytes. Then measure parallel scaling across file-count
and file-size skew distributions, including the scheduler-sensitivity case (one huge file among small ones — the
no-work-stealing worst case). Output: a number. If per-core throughput can't plausibly reach within ~10× of
"fast enough for target publication sizes," the product scope must shrink or the bet is dead. Apply the
benchmark-checklist discipline: alternate runs, medians/ranges, verify output correctness in timed runs, count
errors.

**Track 2 — The flagship proof.** Build the smallest vertical slice that demonstrates the differentiator: a pure
pipeline of parse → collect → validate graph → render, over a tiny page model (id, parent, body), with a
machine-checked proof that **emitted internal links all resolve**. Even on a toy grammar, this proof existing —
or failing to exist for deep reasons — is the evidence that decides whether the product's central claim is real.
This is a harder and more meaningful proof than anything in bendown today.

**Track 3 — Compiler scaling probe.** Link a binary that includes markdown parser + textile parser + cooklang +
batch engine + a JSON emitter + a stub graph module, and find where the Bend compiler falls over. Better to know
now.

The deliverable of week two is a go/no-go memo with three numbers/facts: throughput ratio, link-integrity proof
exists or not (and at what cost), and maximum compilable program size.

## Revised bottom line

As integration, this was a bad idea. As a standalone product, it is a coherent and genuinely differentiated bet:
**the publication compiler whose correctness properties are theorems rather than runtime evidence**. Boris itself
provides the strongest evidence the bet matters — half of Boris's large-corpus build time is spent generating
per-build runtime evidence, a cost structure a proof-carrying design attacks directly. The bet's enemies are
not architectural-policy conflicts but physics: linked-list string throughput, compiler scaling limits, and proof
ergonomics. The 1–2 week experiment is cheap and decisive: measure the throughput ceiling, attempt the
link-integrity proof on a vertical slice, probe the compiler size limit. Those three facts determine everything.
