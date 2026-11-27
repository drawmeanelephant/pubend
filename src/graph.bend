import Base
import ./model.bend as Model

# Graph validation, first-class.
#
# pubend is graph-native: the validated graph is the central artifact of
# compilation. Downstream stages consume ValidatedGraph, which only the
# validator may produce — bypassing validation is unrepresentable, not
# merely discouraged. (Bend has no private constructors, so this is a
# documented discipline rather than a visibility rule; the proof surface is
# what enforces it in practice.)
#
# The design is deliberately not frozen: parent semantics, multi-root policy,
# and nav derivation may evolve. What is not negotiable is centrality.

# Input shape: one row per page, exactly as frontmatter+path derivation
# produces it. parent is a page id or absent (root).
type RawNode is Data:
  RawNode{id: String, parent: Maybe<&2, String>}

# A validated node carries its depth in the forest: roots are 0, every other
# node is exactly one deeper than its parent. The depth assignment is the
# certificate of forest shape — see certificate_check below.
type GraphNode is Data:
  GraphNode{id: String, parent: Maybe<&2, String>, depth: Nat}

type ValidatedGraph is Data:
  ValidatedGraph{nodes: List<&2, GraphNode>}

# The validator. STUB: returns None until implemented. The real validator is
# sequential by design (the join phase of the fork/join pipeline), aggregates
# all diagnostics rather than failing on the first, and must compute depths —
# it does not merely check, it produces the certificate downstream proofs
# rely on. Error representation arrives with the diagnostics work; the Maybe
# shape is sufficient for the law surface now.
def validate(nodes: List<&2, RawNode>) -> Maybe<&2, ValidatedGraph>:
  None{}

# --- The certificate checker, real code ------------------------------------
# A depth assignment certifies forest shape: ids unique, every parent
# resolves, and depth(node) = depth(parent) + 1 with roots at 0. Such an
# assignment exists IF AND ONLY IF the parent structure is an acyclic forest
# — so cycles, self-parents, and dangling parents are all unrepresentable in
# an artifact passing this checker. Checking is structural recursion; no
# fuel, no marks, no traversal state.

def some_nat(+x: Nat) -> Maybe<&2, Nat>:
  Some{x}

def find_depth(+id: String, nodes: List<&2, GraphNode>) -> Maybe<&2, Nat>:
  match nodes:
    case Nil{}:
      None{}
    case +h <> +t:
      match h:
        case GraphNode{+nid, parent, +depth}:
          Model.ifs(Maybe<&2, Nat>, String.eq(id, nid),
            u => some_nat(depth),
            u => find_depth(id, t))

def id_absent(+id: String, nodes: List<&2, GraphNode>) -> Bool:
  match nodes:
    case Nil{}:
      True{}
    case +h <> +t:
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
    case +h <> +t:
      match h:
        case GraphNode{+nid, +parent, +depth}:
          Bool.and(depth_coherent_node(all, nid, parent, depth), depths_coherent(t, all))

def certificate_check(g: ValidatedGraph) -> Bool:
  match g:
    case ValidatedGraph{+nodes}:
      Bool.and(ids_unique(nodes), depths_coherent(nodes, nodes))
