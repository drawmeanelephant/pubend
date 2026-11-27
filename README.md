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

- a pure in-memory compile pipeline whose emission consumes the validated graph;
- closed-grammar frontmatter parsing, lexical path normalization, strict internal-link percent decoding, and
  graph validation with a depth-certificate artifact;
- typed bendown AST rewriting of internal `.md` link/image/autolink targets to canonical relative `.html` hrefs;
- pure v0 layout, title fallback, and graph-derived parent/child navigation with drafts absent from generated nav;
- structured compile diagnostics with the documented engine-span limitations;
- proofs for `validate_sound`, `link_integrity`, and `compile_deterministic` under Bend's checker;
- the `./pubend build DIR [--out OUT]` host CLI, deterministic output trees, exact `_pubend/manifest.json`
  emission, structured failure JSON, and conservative staged publication/recovery behavior;
- positive corpus, negative-fixture oracle, compiler/oracle comparison, and end-to-end artifact audits covering
  repeated builds with identical entry shape and regular-file bytes, emitted HTML target resolution, manifest
  order/digests, nav/draft behavior, and negative-fixture failure behavior.

Not yet implemented or not claimed:

- parallel/sequential compile modes or par/seq byte-identity comparison;
- Lean/BendTT kernel-level proof validity (`PROOF.bend --verdict` is not green in this environment);
- original-author-source line/column spans for markdown link destinations (current spans are engine-normalized
  AST node spans; see bendown issues #7/#8);
- large-input robustness in bendown's JavaScript backend: valid inputs around a few KiB can exhaust the call
  stack under real Node; upstream bendown issue #11 is filed;
- immunity to adversarial concurrent mutation of input/output trees; the host requires stable trees and uses
  post-stage validation only as a mitigation;
- an alternate output mapping for physically colliding page output paths such as `a` plus `a.html/x`.

Read [docs/v0-spec.md](docs/v0-spec.md) before treating any of those gaps as complete. The specification is the
target; v0 now has a real core and host shell, but the remaining limits above are explicit rather than hidden.

## Verification

CI uses Bend 2.0.40. Locally, install it hermetically with the pinned installer carried by the engine submodule:

```sh
sh engine/tools/install_bend_ci.sh
```

Then run the same verification entrypoint as CI:

```sh
sh tools/verify_ci.sh all
```

Or run individual lanes separately:

```sh
sh tools/verify_ci.sh proofs
sh tools/verify_ci.sh corpus
sh tools/verify_ci.sh end-to-end
```

The proof lane checks `PROOF.bend` and all Bend smoke suites. The corpus lane checks the positive corpus, the
negative oracle matrix, and the compiler/oracle comparison harness. The end-to-end lane copies corpus inputs
into `/tmp`, builds them twice through the product `./pubend` CLI, audits output trees and deterministic
manifest order with `tools/check_output.py`, and compares repeated output trees by complete entry path/kind
shape (including empty directories) plus exact regular-file bytes. Manifest order evidence is a strict JSON
array of strings; the auditor's legacy newline-delimited order format remains supported but cannot represent an
id containing U+000A. Physical negative-fixture diagnostic classes are compared as oracle-derived multisets,
with exact multiplicity for malformed-percent (three diagnostics) and the other applicable fixtures. The one
documented exact-multiplicity skip is `malformed-frontmatter`: its unterminated trailing-newline boundary is
outside the Python oracle's exact multiplicity approximation, so only class-set evidence is claimed there. The
lane also probes newline-id order round-tripping, generated-nav scoping/whitespace behavior, absence of failed-
build publication siblings, and preservation of a previously published tree after a failed rebuild.
Synthetic-injection fixtures and `EXPECTED=valid` boundary controls are reported by the lane but are not
negative evidence. `LAWS.bend` intentionally reports open law declarations when checked standalone; those
obligations are discharged in `PROOF.bend`.

`bend PROOF.bend --verdict` requires Lean v4.34.0 or `$BENDTT` pointing at a built BendTT kernel. The current CI
uses Bend's own `ALL PROOFS CHECK` result, not the Lean-kernel verdict.

## Repository layout

```text
src/               pure pubend compile core
test/              executable Bend smoke suites
corpus/            positive publication graph corpus
corpus-negative/   invalid and valid-boundary oracle fixtures
tools/             product CLI host plus verification and comparison harnesses
docs/              architecture, v0 specification, and work prompts
engine/            bendown git submodule, pinned
```

## Development workflow

`main` is protected. Changes land through pull requests with the required `verify-proofs` and `verify-corpus`
checks green. Reviewer approval is intentionally not required at this stage; the repository is optimized for
small, auditable agent-driven changes with machine verification as the gate.

Agent-facing operational rules live in [AGENTS.md](AGENTS.md). Contribution basics live in
[CONTRIBUTING.md](CONTRIBUTING.md).
