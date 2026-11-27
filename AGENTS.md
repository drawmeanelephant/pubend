# pubend agent notes

Read these before changing code:

1. [docs/architecture.md](docs/architecture.md)
2. [docs/v0-spec.md](docs/v0-spec.md)
3. [LAWS.bend](LAWS.bend)
4. [PROOF.bend](PROOF.bend)

pubend is the publication compiler ("the car"); bendown is the pure markup engine. Do not reimplement markdown
parsing or rendering in pubend. Do not make bendown aware of publication sites, filesystem layout, frontmatter,
or nav policy.

## Verification

Bend 2.0.40 is expected at `~/.bend/bin/bend`. If it is absent, install the pinned CI toolchain with:

```sh
sh engine/tools/install_bend_ci.sh
```

Use the shared verification entrypoint from the repository root:

```sh
sh tools/verify_ci.sh all
```

The protected CI lanes are exactly:

```sh
sh tools/verify_ci.sh proofs
sh tools/verify_ci.sh corpus
```

Direct commands, when debugging one lane:

```sh
BEND_NO_TELEMETRY=1 ~/.bend/bin/bend PROOF.bend
BEND_NO_TELEMETRY=1 ~/.bend/bin/bend test/frontmatter_smoke.bend
BEND_NO_TELEMETRY=1 ~/.bend/bin/bend test/paths_smoke.bend
BEND_NO_TELEMETRY=1 ~/.bend/bin/bend test/graph_smoke.bend
BEND_NO_TELEMETRY=1 ~/.bend/bin/bend test/links_smoke.bend
BEND_NO_TELEMETRY=1 ~/.bend/bin/bend test/compile_smoke.bend
PYTHONDONTWRITEBYTECODE=1 python3 tools/check_corpus.py --self-test corpus-negative
node tools/compile_corpus.mjs all corpus corpus-negative --rebuild
```

`LAWS.bend` intentionally reports open `law` declarations when checked standalone; they are discharged in
`PROOF.bend`. `PROOF.bend --verdict` requires Lean v4.34.0 or `$BENDTT`; do not claim kernel-level validity
unless that command genuinely succeeds.

## Hard rules for agents

- Never weaken a law, proof obligation, smoke expectation, corpus fixture, or oracle expectation merely to make
  verification pass. If the implementation is wrong, fix the implementation or report the mismatch honestly.
- Do not add a regex markdown scanner to `src/`. Link extraction must come from bendown parse results.
- Keep IO outside the pure compile pipeline. `src/compile.bend` is pure over pre-loaded `SourcePage` values.
- Downstream publication work is supposed to consume `ValidatedGraph`; do not add new bypasses. The current
  emission path is known to be weaker than the spec's strongest reading and must not be treated as finished.
- Do not claim par/seq equivalence or performance until separate parallel and sequential implementations exist
  and produce byte-identical outputs.
- Do not claim artifact-level broken-link freedom until rendered `.md` hrefs are rewritten to `.html` output
  paths and the link-model/HTML correspondence is addressed.
- Do not install or use Docker, VM runtimes, containers, or container emulators for verification.
- Do not commit secrets or tokens. Do not weaken branch protection, CI, security settings, or supply-chain
  pinning to make a check pass.
- When a bendown boundary bug, missing pure API, or semantic mismatch is found, file an upstream bendown issue
  with a minimal reproduction instead of hiding a workaround in pubend. Upstream fixes remain separate reviewed
  changes and pin updates.
- Keep commits small and coherent. Run the narrowest relevant verification first, then `sh tools/verify_ci.sh
  all` before opening or updating a PR when the change affects compile, proofs, corpus, or CI.

## Bend implementation constraints already learned

- A `match` cannot scrutinize a computed value. Route the computed value into a named helper whose parameter is
  matched.
- Definitions are checked in file order; mutual recursion is not available.
- Affine values are use-once. Mark reusable data parameters with `+`.
- Constructor inference can fail inside complex expressions. Tiny explicitly typed factory/cons helpers are the
  reliable pattern.
- Strings are Unicode-linked structure, not byte arrays.
- Proof-friendly implementation uses named gates that accept scrutinees as parameters. Do not collapse those
  gates back into opaque inline conditionals without expecting the proofs to shatter.

## Current known gaps

The honest current state is documented in [README.md](README.md). In particular, there is no product CLI, no
written output tree, no layout/nav/manifest, no rendered `.md` to `.html` href rewriting, no user-facing spanned
diagnostics, and no par/seq implementation. Treat those as open work, not as bugs in the verification commands.
