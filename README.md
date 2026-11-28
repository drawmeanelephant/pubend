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
- the native Bend host binary behind the `./pubend build DIR [--out OUT]` product CLI, deterministic output
  trees, exact `_pubend/manifest.json` emission, structured failure JSON, and conservative staged
  publication/recovery behavior;
- positive corpus, negative-fixture oracle, compiler/oracle comparison, and end-to-end artifact audits covering
  repeated builds with identical entry shape and regular-file bytes, emitted HTML target resolution, manifest
  order/digests, nav/draft behavior, and negative-fixture failure behavior;
- a differential migration harness that reruns positive sites, negative fixtures, and CLI boundary probes through
  both the native host and the temporary JavaScript reference oracle, requiring identical exit codes, stdout and
  stderr bytes, and post-run filesystem trees.

Not yet implemented or not claimed:

- parallel/sequential compile modes or par/seq byte-identity comparison;
- Lean/BendTT kernel-level proof validity (`PROOF.bend --verdict` is not green in this environment);
- original-author-source line/column spans for markdown link destinations (current spans are engine-normalized
  AST node spans; see bendown issues #7/#8);
- large-input robustness in bendown's JavaScript backend: valid inputs around a few KiB can exhaust the call
  stack under real Node; upstream bendown issue #11 is filed. That backend is now confined to the temporary
  reference oracle and compile-comparison harnesses, not the product host;
- deep container nesting costs in the shared markup algorithms even on the native backend; the 1 MiB input
  ceiling is a boundary limit, not a claim that every admitted input is practically cheap;
- exhaustive fault-injection evidence for rare filesystem errno paths; deterministic boundary behavior is
  probed, while platform-dependent IO error text remains outside the byte-level contract;
- immunity to adversarial concurrent mutation of input/output trees; the host requires stable trees and uses
  post-stage validation only as a mitigation;
- wrapper symlink chains whose link target paths contain U+000A; ordinary relative/absolute symlinked wrapper
  resolution is probed, but newline-bearing symlink target paths are outside the shell resolver contract;
- an alternate output mapping for physically colliding page output paths such as `a` plus `a.html/x`.

Read [docs/v0-spec.md](docs/v0-spec.md) before treating any of those gaps as complete. The specification is the
target; v0 now has a real core and native host shell, but the remaining limits above are explicit rather than hidden.

## Verification

CI uses Bend 2.0.40. Locally, install it hermetically with the pinned installer carried by the engine submodule:

```sh
sh engine/tools/install_bend_ci.sh
```

Then run the same verification entrypoint as CI:

```sh
sh tools/verify_ci.sh all
```

### Product host bootstrap

`./pubend` is a portable `sh` launcher for the native host, not a JavaScript shim. It resolves wrapper symlinks,
requires the pinned Bend 2.0.40 toolchain, and content-addresses the host binary in the gitignored
`.pubend-cache/` directory. The cache key covers the cache format, operating system, architecture, Bend version,
`host/*.bend`, `host/host_eff.c`, `host/host_eff.js`, `src/*.bend`, every `.bend` file under `engine/src`, the
toolchain's `bend2/base.bend`, and every `.c`/`.js` effect implementation under `bend2/effs` — a deliberately
conservative superset of the host's transitive compile inputs. Input enumeration uses a locale-stable `LC_ALL=C`
sort order, and missing or unreadable hash inputs are bootstrap failures rather than skippable data.

If the needed binary is absent, one builder acquires a `mkdir` lock and records its wrapper owner pid. A child
shell `exec`s Bend in that same process, and the wrapper records that child pid as the lock's compiler pid, so
`pid` names the real compiler rather than a short-lived wrapper. Bend compiles `host/hostmain.bend` to a temporary file,
the builder checks that it is executable and has the host platform's Mach-O or ELF magic, and the binary is
atomically moved into place. Concurrent invocations wait behind a live compiler even when its wrapper was
killed; once the compiler and owner are both gone, stale lock and `.building` artifacts are removed and one
waiter rebuilds. A live non-builder pid in the compiler slot is treated as malformed after a short grace period.
Old content-addressed binaries may remain in the cache and can be removed with the whole `.pubend-cache/`
directory. Source or Bend-library changes change the hash and therefore select a fresh binary. The lock is a
crash-serialization mechanism for a cooperating local cache directory, not a security boundary against an
adversary who can write that directory.

After the cache check, the launcher `exec`s the cached native binary. The product path does not invoke Node.js,
Bun, or any other JavaScript runtime. Missing or wrong-version Bend toolchains, missing SHA-256 utilities,
structurally invalid cache entries, and native-host build failures are bootstrap environment failures: the launcher prints a plain
stderr explanation with the install command and exits 3, because the structured-diagnostic host binary is not
yet available.

Or run individual lanes separately:

```sh
sh tools/verify_ci.sh proofs
sh tools/verify_ci.sh corpus
sh tools/verify_ci.sh end-to-end
sh tools/verify_ci.sh cli-boundary
sh tools/verify_ci.sh host-parity
```

The proof lane checks `PROOF.bend` and all Bend smoke suites. The corpus lane checks the positive corpus, the
negative oracle matrix, and the compiler/oracle comparison harness. The end-to-end lane copies corpus inputs
into `/tmp`, builds them twice through the product `./pubend` CLI, audits output trees and deterministic
manifest order with `tools/check_output.py`, and compares repeated output trees by complete entry path/kind
shape (including empty directories) plus exact regular-file bytes. Manifest order evidence is a strict JSON
array of strings; the auditor's legacy newline-delimited order format remains supported but cannot represent an
id containing U+000A. Contract evidence includes exact duplicate-target multiplicity, valid percent-encoded
non-ASCII input links, canonical BMP/astral Unicode href encoding, and BMP-versus-astral filename ordering.
Physical negative-fixture diagnostic classes are compared as oracle-derived multisets,
with exact multiplicity for malformed-percent (three diagnostics) and the other applicable fixtures. The one
documented exact-multiplicity skip is `malformed-frontmatter`: its unterminated trailing-newline boundary is
outside the Python oracle's exact multiplicity approximation, so only class-set evidence is claimed there. The
lane also probes newline-id order round-tripping, generated-nav scoping/whitespace behavior, absence of failed-
build publication siblings, and preservation of a previously published tree after a failed rebuild. Its CLI
boundary regression probes cover case-alias/content overwrite refusal, reserved publication names, canonical
symlink containment, exact foreign lock/stage/backup tree preservation, owned-lock release after handled
failures, marker-owned recovery, symlinked output refusal, and ordinary/fixed-host-file output-path collisions
including filesystem-dependent ASCII-case aliases. They also cover repeated-build determinism and
relative/absolute symlinked wrapper resolution. Those probes can also be run
directly as `sh tools/verify_ci.sh cli-boundary`. Synthetic-injection fixtures and `EXPECTED=valid`
boundary controls are reported by the lane but are not negative evidence.

The host-parity lane is the migration harness for issue #2. It copies or constructs inputs under `/tmp`, runs
each positive corpus site and physical negative fixture through the native product host and the JavaScript
reference oracle at the same path with a full reset of the per-case workspace between runs, and requires exact
equality of exit codes, stdout bytes, stderr bytes, and post-run per-case trees. Negative direct cases are also
checked against their `EXPECTED` diagnostic class sets and the independent corpus-oracle class multisets, with
the same documented `malformed-frontmatter` exact-multiplicity skip as the end-to-end lane. It also reruns
every CLI boundary probe through both hosts under the same reset-at-the-same-path discipline and compares the
ordered raw invocation bytes. The oracle, `tools/pubend.mjs`, is retained only for this migration/evidence role
and for the older compiler-comparison harness; it is not the product host. The parity lane uses `node` on
`PATH` for the oracle by default; `PUBEND_ORACLE_NODE` may point at a specific JavaScript runtime executable
when the oracle itself is being debugged.

`LAWS.bend` intentionally reports open law declarations when checked standalone; those obligations are
discharged in `PROOF.bend`.

`bend PROOF.bend --verdict` requires Lean v4.34.0 or `$BENDTT` pointing at a built BendTT kernel. The current CI
uses Bend's own `ALL PROOFS CHECK` result, not the Lean-kernel verdict.

## Repository layout

```text
src/               pure pubend compile core
host/              native Bend publication host and pinned filesystem effects
test/              executable Bend smoke suites
corpus/            positive publication graph corpus
corpus-negative/   invalid and valid-boundary oracle fixtures
tools/             JavaScript reference oracle plus verification and comparison harnesses
docs/              architecture, v0 specification, and work prompts
engine/            bendown git submodule, pinned
```

## Development workflow

`main` is protected. Changes land through pull requests with the required `verify-proofs` and `verify-corpus`
checks green. Reviewer approval is intentionally not required at this stage; the repository is optimized for
small, auditable agent-driven changes with machine verification as the gate.

Agent-facing operational rules live in [AGENTS.md](AGENTS.md). Contribution basics live in
[CONTRIBUTING.md](CONTRIBUTING.md).
