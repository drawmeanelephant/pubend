import Base
import ./model.bend as Model

# Graph validation, first-class.
#
# pubend is graph-native: the validated graph is the central artifact of
# compilation.  Downstream stages consume ValidatedGraph, which only the
# validator may produce — bypassing validation is unrepresentable, not
# merely discouraged.  (Bend has no private constructors, so this is a
# documented discipline rather than a visibility rule; the proof surface is
# what enforces it in practice.)
#
# The design is deliberately not frozen: parent semantics, multi-root
# policy, and nav derivation may evolve.  What is not negotiable is
# centrality.
#
# The validator produces evidence, not verdicts.  Its structure:
#
#   assign_depths  — computes a candidate depth assignment: roots at 0,
#                    every other node one deeper than its parent, walking
#                    the parent chain with Nat fuel bounded by node count.
#                    On invalid input the produced assignment is garbage —
#                    and necessarily fails the certificate checker, since a
#                    coherent depth assignment exists iff the parent
#                    structure is an acyclic forest.
#   validate_diags — aggregates every diagnostic (spec §4 order): exact
#                    duplicate ids, case-insensitive id collisions,
#                    dangling parents, self-parents, cycles (including
#                    nodes whose ancestry enters a cycle).  Sequential by
#                    design: validation is the join phase of a fork/join
#                    pipeline, not a parallel stage.
#   validate_gate  — returns Some{candidate} only when diagnostics are
#                    empty AND certificate_check accepts the candidate.
#                    The certificate is the authoritative verdict; the
#                    diagnostics explain failures to humans.
#
# `validate` is therefore sound *by construction*: a returned
# ValidatedGraph literally passed certificate_check, which is what the
# `validate_sound` law in LAWS.bend asserts.  `validate_full` attaches the
# diagnostic list to the same verdict for reporting.

# Input shape: one row per page, exactly as frontmatter+path derivation
# produces it.  parent is a page id or absent (root).
type RawNode is Data:
  RawNode{id: String, parent: Maybe<&2, String>}

# A validated node carries its depth in the forest: roots are 0, every other
# node is exactly one deeper than its parent.  The depth assignment is the
# certificate of forest shape — see certificate_check below.
type GraphNode is Data:
  GraphNode{id: String, parent: Maybe<&2, String>, depth: Nat}

type ValidatedGraph is Data:
  ValidatedGraph{nodes: List<&2, GraphNode>}

# --- diagnostics ------------------------------------------------------------

# The diagnostic classes of spec §4, one per violated rule.  `id` is the
# offending node's page id; `other` is the implicated foreign id (the
# colliding id, the unresolved/self/cyclic parent) when there is one.
type DiagKind is Data:
  DDupId{}
  DDupIdCase{}
  DDangling{}
  DSelfParent{}
  DCycle{}

type Diag is Data:
  Diag{kind: DiagKind, id: String, other: Maybe<&2, String>}

# The reporting shape of validation: the certified artifact on success,
# the aggregated diagnostics on failure.
type Validation is Data:
  Valid{graph: ValidatedGraph}
  Invalid{errors: List<&2, Diag>}

# --- small factories ----------------------------------------------------------

def vg_of(nodes: List<&2, GraphNode>) -> ValidatedGraph:
  ValidatedGraph{nodes}

def g_str(+s: String) -> Maybe<&2, String>:
  Some{s}

def g_raw(+id: String, p: Maybe<&2, String>) -> RawNode:
  RawNode{id, p}

def g_raw_some(+id: String, p: Maybe<&2, String>) -> Maybe<&2, RawNode>:
  Some{g_raw(id, p)}

def g_node(+id: String, +p: Maybe<&2, String>, +d: Nat) -> GraphNode:
  GraphNode{id, p, d}

def g_diag(k: DiagKind, +id: String, o: Maybe<&2, String>) -> Diag:
  Diag{k, id, o}

def g_diag_some(k: DiagKind, +id: String, o: Maybe<&2, String>) -> Maybe<&2, Diag>:
  Some{g_diag(k, id, o)}

def g_diag_none() -> Maybe<&2, Diag>:
  None{}

def g_node_some(n: GraphNode) -> Maybe<&2, GraphNode>:
  Some{n}

def g_node_none() -> Maybe<&2, GraphNode>:
  None{}

def g_vg_some(+g: ValidatedGraph) -> Maybe<&2, ValidatedGraph>:
  Some{g}

def g_vg_none() -> Maybe<&2, ValidatedGraph>:
  None{}

# --- lookups -----------------------------------------------------------------

def id_member(+id: String, nodes: List<&2, RawNode>) -> Bool:
  match nodes:
    case Nil{}:
      False{}
    case +h <> t:
      match h:
        case RawNode{+nid, parent}:
          Model.ifs(Bool, String.eq(id, nid),
            u => True{},
            u => id_member(id, t))

def count_id(+id: String, nodes: List<&2, RawNode>) -> Nat:
  match nodes:
    case Nil{}:
      0n
    case +h <> t:
      match h:
        case RawNode{+nid, parent}:
          Nat.add(
            Model.ifs(Nat, String.eq(id, nid), u => 1n, u => 0n),
            count_id(id, t))

# The first id that collides with `id` only by letter case (exact-equal ids
# are reported as plain duplicates, not case collisions).
def case_hit(+id: String, nodes: List<&2, RawNode>) -> Maybe<&2, String>:
  match nodes:
    case Nil{}:
      None{}
    case +h <> t:
      match h:
        case RawNode{+nid, parent}:
          Model.ifs(Maybe<&2, String>,
            Bool.and(Bool.not(String.eq(id, nid)),
              String.eq(String.to_lower(id), String.to_lower(nid))),
            u => g_str(nid),
            u => case_hit(id, t))

def find_raw(+id: String, nodes: List<&2, RawNode>) -> Maybe<&2, RawNode>:
  match nodes:
    case Nil{}:
      None{}
    case +h <> t:
      match h:
        case RawNode{+nid, +parent}:
          Model.ifs(Maybe<&2, RawNode>, String.eq(id, nid),
            u => g_raw_some(nid, parent),
            u => find_raw(id, t))

# --- the depth assignment ------------------------------------------------------

# Walk cur's ancestor chain: True when it reaches a root (or a missing id,
# which dangling-parent diagnostics report separately) without revisiting
# start; False when it comes back to start or runs out of fuel — both only
# possible through a cycle.  fuel = node count + 1 bounds every acyclic
# chain; it is the first parameter so everything after it is free at the
# recursive call.  `m` is find_raw(cur, nodes), supplied by the caller —
# Bend cannot match on a computed lookup, so the match happens on this
# parameter instead.
def chain_ok(+fuel: Nat, +start: String, +cur: String, +nodes: List<&2, RawNode>,
  m: Maybe<&2, RawNode>) -> Bool:
  match fuel:
    case 0n:
      False{}
    case 1n+f:
      match m:
        case None{}:
          True{}
        case Some{+rn}:
          match rn:
            case RawNode{id2, parent}:
              match parent:
                case None{}:
                  True{}
                case Some{+pid}:
                  Model.ifs(Bool, String.eq(pid, start),
                    u => False{},
                    u => chain_ok(f, start, pid, nodes, find_raw(pid, nodes)))

# The depth of one id: 0 for a root, one deeper than its parent otherwise.
# Sentinels 0 cover the unreachable cases (fuel exhaustion needs a cycle;
# a missing id needs a dangling parent — both are invalid inputs whose
# candidate fails the certificate checker anyway).  Same shape as
# chain_ok: fuel first, the lookup result as the matched parameter.
def depth_of(+fuel: Nat, +id: String, +nodes: List<&2, RawNode>, m: Maybe<&2, RawNode>) -> Nat:
  match fuel:
    case 0n:
      0n
    case 1n+f:
      match m:
        case None{}:
          0n
        case Some{+rn}:
          match rn:
            case RawNode{id2, parent}:
              match parent:
                case None{}:
                  0n
                case Some{+pid}:
                  Nat.add(depth_of(f, pid, nodes, find_raw(pid, nodes)), 1n)

def assign_node(+all: List<&2, RawNode>, +fuel: Nat, n: RawNode) -> GraphNode:
  match n:
    case RawNode{+id, +parent}:
      g_node(id, parent, depth_of(fuel, id, all, find_raw(id, all)))

def assign_go(+all: List<&2, RawNode>, +fuel: Nat, xs: List<&2, RawNode>) -> List<&2, GraphNode>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      assign_node(all, fuel, h) <> assign_go(all, fuel, t)

# The candidate certified artifact: every node with a computed depth.  For
# a valid forest this is THE depth assignment; for invalid input it is a
# candidate the certificate checker will reject.
def assign_depths(+nodes: List<&2, RawNode>) -> ValidatedGraph:
  +n = List.length(&2, RawNode, nodes)
  vg_of(assign_go(nodes, Nat.add(n, 1n), nodes))

# --- per-class diagnostic scans (spec §4 order) --------------------------------

# A Maybe-wrapped diagnostic cons: keeps aggregation code flat.
def diag_cons(m: Maybe<&2, Diag>, rest: List<&2, Diag>) -> List<&2, Diag>:
  match m:
    case None{}:
      rest
    case Some{+d}:
      d <> rest

# 1a. exact duplicate ids: every node whose id occurs more than once.
def dup_diag(+id: String, +all: List<&2, RawNode>) -> Maybe<&2, Diag>:
  Model.ifs(Maybe<&2, Diag>, Nat.is_gt(count_id(id, all), 1n),
    u => g_diag_some(DDupId{}, id, g_str(id)),
    u => g_diag_none())

def dup_go(xs: List<&2, RawNode>, +all: List<&2, RawNode>) -> List<&2, Diag>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case RawNode{+id, parent}:
          diag_cons(dup_diag(id, all), dup_go(t, all))

# 1b. case-insensitive collisions: distinct ids equal after lowering.
def case_diag(+id: String, +all: List<&2, RawNode>) -> Maybe<&2, Diag>:
  Model.ifs(Maybe<&2, Diag>, Maybe.is_some(&2, String, case_hit(id, all)),
    u => g_diag_some(DDupIdCase{}, id, case_hit(id, all)),
    u => g_diag_none())

def case_go(xs: List<&2, RawNode>, +all: List<&2, RawNode>) -> List<&2, Diag>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case RawNode{+id, parent}:
          diag_cons(case_diag(id, all), case_go(t, all))

# 2. dangling parents: a parent id that names no node.
def dang_diag(+id: String, parent: Maybe<&2, String>, +all: List<&2, RawNode>) -> Maybe<&2, Diag>:
  match parent:
    case None{}:
      g_diag_none()
    case Some{+p}:
      Model.ifs(Maybe<&2, Diag>, id_member(p, all),
        u => g_diag_none(),
        u => g_diag_some(DDangling{}, id, g_str(p)))

def dang_go(xs: List<&2, RawNode>, +all: List<&2, RawNode>) -> List<&2, Diag>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case RawNode{+id, +parent}:
          diag_cons(dang_diag(id, parent, all), dang_go(t, all))

# 3a. self-parents.
def self_diag(+id: String, parent: Maybe<&2, String>) -> Maybe<&2, Diag>:
  match parent:
    case None{}:
      g_diag_none()
    case Some{+p}:
      Model.ifs(Maybe<&2, Diag>, String.eq(id, p),
        u => g_diag_some(DSelfParent{}, id, g_str(p)),
        u => g_diag_none())

def self_go(xs: List<&2, RawNode>) -> List<&2, Diag>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case RawNode{+id, +parent}:
          diag_cons(self_diag(id, parent), self_go(t))

# 3b. cycles: a node's ancestor chain loops (either back to the node, or
# into a cycle upstream — both leave the chain unable to reach a root).
# Self-parents are reported as DSelfParent instead, so each violated rule
# reports once.
def cycle_diag(+id: String, parent: Maybe<&2, String>, +all: List<&2, RawNode>, +fuel: Nat) -> Maybe<&2, Diag>:
  match parent:
    case None{}:
      g_diag_none()
    case Some{+p}:
      Model.ifs(Maybe<&2, Diag>, String.eq(id, p),
        u => g_diag_none(),
        u => Model.ifs(Maybe<&2, Diag>, chain_ok(fuel, id, p, all, find_raw(p, all)),
          u2 => g_diag_none(),
          u2 => g_diag_some(DCycle{}, id, g_str(p))))

def cycle_go(xs: List<&2, RawNode>, +all: List<&2, RawNode>, +fuel: Nat) -> List<&2, Diag>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      match h:
        case RawNode{+id, +parent}:
          diag_cons(cycle_diag(id, parent, all, fuel), cycle_go(t, all, fuel))

# Every diagnostic, in spec order: duplicates, case collisions, dangling
# parents, self-parents, cycles.  Aggregated — never fail-first.
def validate_diags(+nodes: List<&2, RawNode>) -> List<&2, Diag>:
  +fuel = Nat.add(List.length(&2, RawNode, nodes), 1n)
  List.append(&2, Diag, dup_go(nodes, nodes),
    List.append(&2, Diag, case_go(nodes, nodes),
      List.append(&2, Diag, dang_go(nodes, nodes),
        List.append(&2, Diag, self_go(nodes),
          cycle_go(nodes, nodes, fuel)))))

def diags_empty(+nodes: List<&2, RawNode>) -> Bool:
  List.is_empty(&2, Diag, validate_diags(nodes))

# --- the certificate checker (unchanged, already verified) --------------------

def some_nat(+x: Nat) -> Maybe<&2, Nat>:
  Some{x}

def find_depth(+id: String, nodes: List<&2, GraphNode>) -> Maybe<&2, Nat>:
  match nodes:
    case Nil{}:
      None{}
    case +h <> t:
      match h:
        case GraphNode{+nid, parent, +depth}:
          Model.ifs(Maybe<&2, Nat>, String.eq(id, nid),
            u => some_nat(depth),
            u => find_depth(id, t))

def id_absent(+id: String, nodes: List<&2, GraphNode>) -> Bool:
  match nodes:
    case Nil{}:
      True{}
    case +h <> t:
      match h:
        case GraphNode{+nid, parent, depth}:
          Model.ifs(Bool, String.eq(id, nid),
            u => False{},
            u => id_absent(id, t))

def ids_unique(nodes: List<&2, GraphNode>) -> Bool:
  match nodes:
    case Nil{}:
      True{}
    case +h <> +t:
      match h:
        case GraphNode{+nid, parent, depth}:
          Bool.and(id_absent(nid, t), ids_unique(t))

def depth_parent_check(+all: List<&2, GraphNode>, +depth: Nat, m: Maybe<&2, Nat>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{+pd}:
      Nat.is_eq(depth, Nat.add(pd, 1n))

def depth_coherent_node(+all: List<&2, GraphNode>, +id: String, parent: Maybe<&2, String>, +depth: Nat) -> Bool:
  match parent:
    case None{}:
      Nat.is_eq(depth, 0n)
    case Some{+pid}:
      depth_parent_check(all, depth, find_depth(pid, all))

def depths_coherent(nodes: List<&2, GraphNode>, +all: List<&2, GraphNode>) -> Bool:
  match nodes:
    case Nil{}:
      True{}
    case +h <> t:
      match h:
        case GraphNode{+nid, +parent, +depth}:
          Bool.and(depth_coherent_node(all, nid, parent, depth), depths_coherent(t, all))

# A depth assignment certifies forest shape: ids unique, every parent
# resolves, and depth(node) = depth(parent) + 1 with roots at 0.  Such an
# assignment exists IF AND ONLY IF the parent structure is an acyclic
# forest — so cycles, self-parents, and dangling parents are all
# unrepresentable in an artifact passing this checker.  Checking is
# structural recursion; no fuel, no marks, no traversal state.
def certificate_check(g: ValidatedGraph) -> Bool:
  match g:
    case ValidatedGraph{+nodes}:
      Bool.and(ids_unique(nodes), depths_coherent(nodes, nodes))

# --- the validator ----------------------------------------------------------------

# The gate: Some{candidate} only when both the diagnostic pass and the
# certificate check pass.  Separating the two Booleans keeps each check
# visible to callers and to PROOF.bend's case analysis.
def validate_gate(+cand: ValidatedGraph, d_ok: Bool, c_ok: Bool) -> Maybe<&2, ValidatedGraph>:
  match d_ok:
    case False{}:
      g_vg_none()
    case True{}:
      match c_ok:
        case False{}:
          g_vg_none()
        case True{}:
          g_vg_some(cand)

# The validator.  Sequential by design (the join phase of the fork/join
# pipeline).  The returned artifact literally passed certificate_check —
# that is what makes validate_sound provable rather than hopeful.
def validate(+nodes: List<&2, RawNode>) -> Maybe<&2, ValidatedGraph>:
  +cand = assign_depths(nodes)
  validate_gate(cand, diags_empty(nodes), certificate_check(cand))

# The reporting shape: the same verdict with its diagnostics attached.
def vfull_of(m: Maybe<&2, ValidatedGraph>, ds: List<&2, Diag>) -> Validation:
  match m:
    case Some{+g}:
      Valid{g}
    case None{}:
      Invalid{ds}

def validate_full(+nodes: List<&2, RawNode>) -> Validation:
  vfull_of(validate(nodes), validate_diags(nodes))

# --- accessors for downstream stages --------------------------------------------

def graph_nodes(+g: ValidatedGraph) -> List<&2, GraphNode>:
  match g:
    case ValidatedGraph{+nodes}:
      nodes

def node_id(+n: GraphNode) -> String:
  match n:
    case GraphNode{+id, parent, depth}:
      id

def graph_ids_go(xs: List<&2, GraphNode>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      match h:
        case GraphNode{+id, parent, depth}:
          id <> graph_ids_go(t)

# The page ids of a validated graph, in node order — the membership set
# link resolution checks against.
def graph_ids(+g: ValidatedGraph) -> List<&2, String>:
  graph_ids_go(graph_nodes(g))

def gnode_member(+id: String, nodes: List<&2, GraphNode>) -> Bool:
  match nodes:
    case Nil{}:
      False{}
    case +h <> t:
      match h:
        case GraphNode{+nid, parent, depth}:
          Model.ifs(Bool, String.eq(id, nid),
            u => True{},
            u => gnode_member(id, t))

def find_gnode(+id: String, nodes: List<&2, GraphNode>) -> Maybe<&2, GraphNode>:
  match nodes:
    case Nil{}:
      g_node_none()
    case +h <> t:
      match h:
        case GraphNode{+nid, +parent, +depth}:
          Model.ifs(Maybe<&2, GraphNode>, String.eq(id, nid),
            u => g_node_some(g_node(nid, parent, depth)),
            u => find_gnode(id, t))

# Does this node name `id` as its parent?
def node_parents_id(+id: String, n: GraphNode) -> Bool:
  match n:
    case GraphNode{nid, parent, depth}:
      match parent:
        case None{}:
          False{}
        case Some{+p}:
          String.eq(p, id)

def children_go(+id: String, xs: List<&2, GraphNode>) -> List<&2, GraphNode>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      match h:
        case GraphNode{+nid, +parent, +depth}:
          Model.ifs(List<&2, GraphNode>, node_parents_id(id, g_node(nid, parent, depth)),
            u => g_node(nid, parent, depth) <> children_go(id, t),
            u => children_go(id, t))

# The direct children of a page id in the validated forest (for nav).
def graph_children(+id: String, +g: ValidatedGraph) -> List<&2, GraphNode>:
  children_go(id, graph_nodes(g))
