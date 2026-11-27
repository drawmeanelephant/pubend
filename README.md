<img src="assets/icon.svg" width="64" height="64" alt="">

# pubend

[![CI](https://github.com/drawmeanelephant/pubend/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/pubend/actions/workflows/ci.yml)

pubend is a proof-carrying, graph-native publication compiler written in Bend 2. It uses
[bendown](https://github.com/drawmeanelephant/bendown) as its pure markup engine.

The project boundary is deliberate: bendown owns markdown parsing and rendering; pubend owns page identity,
frontmatter, graph validation, link resolution, and publication semantics. pubend must not grow a parallel regex
markdown parser, and bendown must not learn about sites, filesystems, or publication policy.

## Current status

Implemented and verified:

- a pure in-memory compile pipeline over pre-loaded pages;
- closed-grammar frontmatter parsing;
- lexical path normalization and internal link resolution;
- graph validation with a depth-certificate artifact;
- proofs for `validate_sound`, `link_integrity`, and `compile_deterministic` under Bend's checker;
- five positive corpus sites and a negative-fixture oracle;
- a Node-based scratch harness that compiles the real corpus through Bend's generated JavaScript export and
  compares compiler/oracle verdicts.

Not yet implemented:

- a product `pubend build DIR` CLI;
- output-tree writing, layout, navigation, or manifest emission;
- `.md` to `.html` href rewriting in rendered HTML;
- user-facing spanned diagnostics;
- parallel/sequential compile modes or par/seq byte-identity comparison.

Read [docs/v0-spec.md](docs/v0-spec.md) before treating any of those gaps as complete. The specification is the
target; the current implementation is a verified proof core plus corpus harness, not the full v0 product shell.

## Verification

CI uses Bend 2.0.40. Locally, install it hermetically with the pinned installer carried by the engine submodule:

```sh
sh engine/tools/install_bend_ci.sh
```

Then run the same verification entrypoint as CI:

```sh
sh tools/verify_ci.sh all
```

Or run the two protected CI lanes separately:

```sh
sh tools/verify_ci.sh proofs
sh tools/verify_ci.sh corpus
```

The proof lane checks `PROOF.bend` and all Bend smoke suites. The corpus lane checks the positive corpus, the
negative oracle matrix, and the compiler/oracle comparison harness. `LAWS.bend` intentionally reports open law
declarations when checked standalone; those obligations are discharged in `PROOF.bend`.

`bend PROOF.bend --verdict` requires Lean v4.34.0 or `$BENDTT` pointing at a built BendTT kernel. The current CI
uses Bend's own `ALL PROOFS CHECK` result, not the Lean-kernel verdict.

## Repository layout

```text
src/               pure pubend compile core
test/              executable Bend smoke suites
corpus/            positive publication graph corpus
corpus-negative/   invalid and valid-boundary oracle fixtures
tools/             scratch verification and comparison harnesses
docs/              architecture, v0 specification, and work prompts
engine/            bendown git submodule, pinned
```

## Development workflow

`main` is protected. Changes land through pull requests with the required `verify-proofs` and `verify-corpus`
checks green. Reviewer approval is intentionally not required at this stage; the repository is optimized for
small, auditable agent-driven changes with machine verification as the gate.

Agent-facing operational rules live in [AGENTS.md](AGENTS.md). Contribution basics live in
[CONTRIBUTING.md](CONTRIBUTING.md).
