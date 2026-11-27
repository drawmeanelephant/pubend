# pubend — next work set: compile pipeline core + realistic graph-varied corpus

You are the orchestrator for a multi-agent work session on **pubend**, a proof-carrying,
graph-native publication compiler written in Bend 2, in the repo at
`/Users/tbuddy/.t3/projects/pubend`. pubend is to bendown what Boris is to Oliver: the car
that harnesses the engine. bendown (the pure markup engine) lives in its own repo.

## Read first, before anything else

- `docs/architecture.md` — the car/engine doctrine, boundary allocation, dependency mechanics
- `docs/v0-spec.md` — the locked v0 target: path-derived ids, closed frontmatter grammar,
  link resolution algebra, graph validation as the center of the pipeline
- `LAWS.bend`, `PROOF.bend`, `src/model.bend`, `src/graph.bend`, `src/compile.bend` — the
  proof scaffold. `bend PROOF.bend` currently reports exactly 2 TODOs (`link_integrity`,
  `validate_sound`); that is the intended ratchet, not a broken build.

Verification environment:

- Bend 2.0.40 is at `~/.bend/bin/bend` (not on PATH). Always run with `BEND_NO_TELEMETRY=1`.
- Verify with: `BEND_NO_TELEMETRY=1 ~/.bend/bin/bend LAWS.bend` and
  `BEND_NO_TELEMETRY=1 ~/.bend/bin/bend PROOF.bend` from the repo root.
- Bend constraints that bite constantly: a `match` cannot scrutinize a computed value (route
  through a helper whose parameter is matched); defs are ordered, no mutual recursion;
  affine values are use-once (mark reusable `Data` params with `+`); constructors inside
  complex expressions often fail inference — route construction through tiny explicitly
  typed factory helpers; Strings are linked lists of Unicode chars; recursive functions may
  need explicit `Nat` fuel.
- No Docker/VM/container anything on this machine, ever.

## Orchestration shape

Spawn independent subagents for the content sites below — they share no files and may run
fully in parallel. The implementation track (Track A) touches `src/` and should be either
one agent or carefully file-partitioned; do not let two agents write the same module.
Every agent works in `/Users/tbuddy/.t3/projects/pubend` directly (no worktrees needed if
file ownership is disjoint; use your judgment). Each agent's final report must list: files
created/modified, verification commands run with exact output, and any spec deviations or
judgment calls made.

## Track A — implementation (not parallelized with itself)

Ordered, each step verifiable before the next:

1. **Engine wiring.** bendown must be consumable via downward-relative imports. Add it as a
   git submodule at `engine/` (upstream: `https://github.com/drawmeanelephant/bendown`).
   Verify `import ./engine/src/ast.bend as Ast` typechecks from a scratch file in the repo
   root, then delete the scratch file. Record the pinned commit in `docs/architecture.md`.
2. **Frontmatter parser** (`src/frontmatter.bend`): the closed grammar of v0-spec §3 —
   `---` delimiters, `key: value` lines, keys `title`/`parent`/`status` only, duplicate and
   unknown keys are errors, malformed structure is an error. Total function, errors as
   values with line positions. Unit-smoke it with a temporary test file, then keep a
   permanent smoke file under `test/`.
3. **Path algebra** (`src/paths.bend`): lexical join + dot-segment normalization per
   v0-spec §5.2. Pure, total, no filesystem. This is the correctness core of link
   resolution — test the corner cases hard: `..` escaping the root, redundant `.`,
   duplicate slashes, deep nesting.
4. **The real validator** (`src/graph.bend`): replace the stub. Compute the depth
   certificate with fuel bounded by node count; aggregate all diagnostics (duplicate ids
   including case-insensitive collisions, dangling parents, cycles, self-parents) rather
   than failing on the first. `certificate_check` already exists and is verified — the
   validator must produce artifacts that pass it, or fail with errors. Then discharge
   `validate_sound` in `PROOF.bend` — really discharge it, or report exactly where the
   proof fights back; do not weaken the law without changing v0-spec in the same commit.
5. **Link resolution** (`src/links.bend`): classification (external / internal `.md` /
   passthrough) and resolution per v0-spec §5. Fragments pass through unvalidated.
6. **Compile assembly** (`src/compile.bend`): replace the stub with the real pure pipeline
   over pre-loaded pages (IO stays outside). Graph validation is the join; everything
   downstream consumes `ValidatedGraph`. Then assess `link_integrity` in `PROOF.bend` — if
   the full proof is not yet tractable, narrow it honestly (e.g. prove for a structural
   subset) and document exactly what is proved vs. open. Never fake it.
7. **First end-to-end** (only after the corpus exists): compile every site in `corpus/`,
   compare verdicts against the oracle checker (Track C), record wall times par vs `--seq`.

## Track B — content corpus agents (parallel, one site each)

Each agent authors one realistic publication site under `corpus/<slug>/` where `<slug>` is
a short lowercase name the agent chooses to fit its invented topic. **The agent invents the
topic itself** — pick something genuinely suited to the assigned graph shape, something you
can write plausible real content about. Not lorem ipsum, not placeholder text: real-ish
writing, a paragraph or more per page, the kind of content where the links and hierarchy
exist because the topic demands them.

Hard requirements for every site:

- Input tree shape per v0-spec: `corpus/<slug>/content/**/*.md`, nothing outside `content/`
  except the manifest described below.
- 15–50 pages per site unless the shape assignment says otherwise.
- Frontmatter strictly within the closed grammar (`title`, `parent`, `status` only).
- Ids are path-derived; no id keys. Internal links are relative `.md` references and must
  resolve per the spec's path algebra. Fragments (`#...`) are allowed and pass through.
- All sites must be **valid** — they are positive fixtures. (Negative fixtures are Track C.)
- Each site root contains `corpus/<slug>/GRAPH-SHAPE.md`: the agent's manifest describing
  the intended topology — root count, max depth, fanout characteristics, approximate link
  density (links per page), whether cross-subtree links exist, fragment usage — plus one
  paragraph on why the invented topic naturally produces that shape. This manifest is what
  later compiler measurements get compared against.

The shape assignments — vary along both dimensions (forest shape × link density):

1. **Deep strict hierarchy, sparse links.** Depth 4–5, low fanout, almost no cross-links
   beyond what navigation implies. The kind of content that is naturally a nested taxonomy.
2. **Wide flat root, moderate links.** One root with 15–30 direct children, little or no
   nesting below them, a few cross-links where content genuinely relates.
3. **Multi-root forest.** 3–5 independent roots with disjoint subtrees; links within each
   subtree are natural, but include a handful of links that cross subtree boundaries.
4. **Dense cross-linked garden.** Moderate tree shape, but every page carries 3–8 internal
   links, heavy fragment usage, links that ignore the hierarchy entirely. The parent forest
   and the link web should visibly diverge.
5. **Sparse linear/minimal.** 8–15 pages, chain-like or near-flat, very few links. The
   low end of graphiness — what the compiler does when there is almost nothing to validate.

## Track C — oracle checker + negative fixtures (one agent, parallel with Track B)

1. Write `tools/check_corpus.py` — a zero-dependency Python 3 script that takes a site root
   and validates v0-spec conformance: frontmatter grammar, closed keys, duplicate ids
   (including case-insensitive collisions), parent resolution, cycles, internal `.md` link
   resolution including dot-segment normalization and root-escape detection. Exit 0 with a
   one-line summary on valid sites; nonzero with every violation listed on broken ones.
   This is a **test oracle**, scratch tooling — it is not product code and must not be
   imported by anything in `src/`; its job is to cross-check the real compiler's verdicts
   later. Validate the oracle itself against the Track B sites as they appear.
2. Author `corpus-negative/` — a set of tiny sites (3–6 pages each), each violating exactly
   one rule: duplicate id, case-only-collision duplicate, dangling parent, self-parent,
   two-node cycle, longer cycle, unknown frontmatter key, duplicate frontmatter key,
   malformed frontmatter, link escaping the content root, link to a nonexistent page,
   over-complex-but-valid edge cases that must *pass* (clearly marked). One subdirectory per
   violation, each with a one-line `EXPECTED` file naming the expected diagnostic class.

## Acceptance criteria for the whole session

- `bend PROOF.bend` output reported honestly, with fewer or equal TODOs than at start, and
  any remaining TODOs explicitly named with what blocks them.
- `python3 tools/check_corpus.py corpus/<slug>` exits 0 for every Track B site.
- Every negative fixture produces exactly its expected diagnostic class from the oracle.
- If Track A reaches step 7: every corpus site compiles, compiler verdicts match oracle
  verdicts on all positive and negative sites, and par/seq outputs are byte-identical.
- Commit work in the pubend repo (do not push). One commit per coherent unit; corpus sites
  may be one commit each. If the engine submodule is added, that is its own commit.
- Final report: what got built, what got proved, what got measured, what fights back.
