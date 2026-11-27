import Base

# Proof-of-concept data model for a subset of Boris graph.json.
# This is not a Boris-compatible ingestion format and not evidence that an
# external artifact carries Boris provenance.

type Role is Data:
  Trunk{}
  Satellite{}

type Endpoint is Data:
  PageEndpoint{id: String}
  SourceEndpoint{path: String}

type Node is Data:
  Node{index: U32, id: String, sourcePath: String, role: Role,
    parent: Maybe<&2, String>, parentIndex: Maybe<&2, U32>,
    title: String, status: String, tags: List<&2, String>, bodyOffset: U32}

type Edge is Data:
  Edge{from: Endpoint, to: Endpoint, kind: String}

type ReverseEntry is Data:
  ReverseEntry{target: Endpoint, sources: List<&2, Endpoint>}

type NavEntry is Data:
  NavEntry{index: U32, breadcrumb: List<&2, U32>,
    children: List<&2, U32>, siblings: List<&2, U32>}

type GraphIr is Data:
  GraphIr{schemaVersion: String, frozen: Bool,
    nodes: List<&2, Node>, edges: List<&2, Edge>,
    reverseIndex: List<&2, ReverseEntry>, nav: List<&2, NavEntry>}

def endpoint_eq(a: Endpoint, b: Endpoint) -> Bool:
  match a b:
    case PageEndpoint{+x} PageEndpoint{+y}:
      String.eq(x, y)
    case SourceEndpoint{+x} SourceEndpoint{+y}:
      String.eq(x, y)
    case x y:
      False{}

def node_count(g: GraphIr) -> Nat:
  match g:
    case GraphIr{schemaVersion, frozen, nodes, edges, reverseIndex, nav}:
      List.length(&2, Node, nodes)

def edge_count(g: GraphIr) -> Nat:
  match g:
    case GraphIr{schemaVersion, frozen, nodes, edges, reverseIndex, nav}:
      List.length(&2, Edge, edges)

# Executable shape check only. Full proof-carrying auditing would still need
# laws/witnesses for sortedness, uniqueness, exact reverseIndex inversion,
# schema-version/facet coherence, and a boundary-checked JSON decoder.
def node_nav_length_eq(g: GraphIr) -> Bool:
  match g:
    case GraphIr{schemaVersion, frozen, nodes, edges, reverseIndex, nav}:
      Nat.is_eq(List.length(&2, Node, nodes), List.length(&2, NavEntry, nav))
