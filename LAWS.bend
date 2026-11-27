import Base
import ./src/model.bend as Model
import ./src/compile.bend as Compile
import ./src/graph.bend as Graph

# pubend laws. Written before the implementation, deliberately.
# Open laws are the ratchet: `bend PROOF.bend` prints SOME PROOFS FAIL until
# each one is genuinely proved. Do not weaken a law to make a proof easier;
# weaken the spec (docs/v0-spec.md) instead, in the same change.

# Same input, same output. In a pure language this is partly a regression pin
# against hidden effects or ordering leakage creeping into the pipeline.
law compile_deterministic:
  for +config: Model.Config
  for +pages: List<&2, Model.SourcePage>
  {Compile.compile(config, pages) == Compile.compile(config, pages) : Maybe<&2, Model.Publication>}

# The flagship law.
# If compilation succeeds and emits publication `pub`, then every resolved
# internal link carried by every emitted page names a page emitted in `pub`.
# Broken internal links in a successful build are impossible by theorem —
# not checked per build, not audited after the fact.
#
# Boundary honesty: this quantifies over the pure compile pipeline only.
# It says nothing about external links, fragments, the filesystem, or what
# happens to the output tree after emission. See docs/v0-spec.md §5.
law link_integrity:
  for +config: Model.Config
  for +pages: List<&2, Model.SourcePage>
  for +pub: Model.Publication
  for ev: {Compile.compile(config, pages) == Some{pub} : Maybe<&2, Model.Publication>}
  {Model.publication_links_resolve(pub) == True{} : Bool}

# Validation soundness. If the validator succeeds and produces graph `g`,
# then `g` carries a valid depth certificate: unique ids, every parent
# resolving, depth(node) = depth(parent) + 1, roots at 0. Because such an
# assignment exists if and only if the parent structure is an acyclic forest,
# this law means cycles, self-parents, and dangling parents can never be
# present in any artifact the validator accepts.
#
# This is deliberately the first-class-center law of the compiler: the graph
# is not checked as a phase, it is constructed as a certified artifact, and
# downstream stages consume nothing else.
law validate_sound:
  for +nodes: List<&2, Graph.RawNode>
  for +g: Graph.ValidatedGraph
  for ev: {Graph.validate(nodes) == Some{g} : Maybe<&2, Graph.ValidatedGraph>}
  {Graph.certificate_check(g) == True{} : Bool}
