import Base
import ./harness.bend as H
import ../src/graph.bend as G

# Smoke tests for the real validator: every diagnostic class, aggregation
# (multiple violations reported together), and the certificate contract —
# every Some{} artifact passes certificate_check, every invalid input is
# rejected.

def rn(+id: String, p: Maybe<&2, String>) -> G.RawNode:
  G.RawNode{id, p}

def no_parent() -> Maybe<&2, String>:
  None{}

def par(+p: String) -> Maybe<&2, String>:
  Some{p}

def show_valid(m: Maybe<&2, G.ValidatedGraph>) -> String:
  match m:
    case None{}:
      "INVALID"
    case Some{+g}:
      "VALID"

def case_val(+name: String, nodes: List<&2, G.RawNode>, +want: String) -> H.Check:
  H.chk(name, show_valid(G.validate(nodes)), want)

def cert_of(m: Maybe<&2, G.ValidatedGraph>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{+g}:
      G.certificate_check(g)

# The certificate contract, checked directly: a returned graph must pass
# certificate_check (this is what validate_sound asserts).
def case_cert(+name: String, nodes: List<&2, G.RawNode>, want: Bool) -> H.Check:
  H.chkb(name, cert_of(G.validate(nodes)), want)

# --- diagnostics -------------------------------------------------------------

def diag_kind_name(k: G.DiagKind) -> String:
  match k:
    case G.DDupId{}: "dup"
    case G.DDupIdCase{}: "case"
    case G.DDangling{}: "dangling"
    case G.DSelfParent{}: "self"
    case G.DCycle{}: "cycle"

def maybe_str(m: Maybe<&2, String>) -> String:
  match m:
    case None{}: "-"
    case Some{+s}: s

def diag_str(d: G.Diag) -> String:
  match d:
    case G.Diag{+kind, +id, +other}:
      String.append(diag_kind_name(kind),
        String.append(":", String.append(id,
          String.append(":", maybe_str(other)))))

def diags_str_go(xs: List<&2, G.Diag>) -> String:
  match xs:
    case Nil{}: ""
    case +h <> t:
      String.append(diag_str(h), String.append(",", diags_str_go(t)))

def diags_str(nodes: List<&2, G.RawNode>) -> String:
  diags_str_go(G.validate_diags(nodes))

def case_diag(+name: String, nodes: List<&2, G.RawNode>, +want: String) -> H.Check:
  H.chk(name, diags_str(nodes), want)

# --- depth checks ---------------------------------------------------------------

def depth_str(m: Maybe<&2, Nat>) -> String:
  match m:
    case None{}: "?"
    case Some{+d}: Nat.show(d)

def depth_show(+id: String, m: Maybe<&2, G.ValidatedGraph>) -> String:
  match m:
    case None{}:
      "INVALID"
    case Some{+g}:
      depth_str(G.find_depth(id, G.graph_nodes(g)))

def case_depth(+name: String, +id: String, nodes: List<&2, G.RawNode>, +want: String) -> H.Check:
  H.chk(name, depth_show(id, G.validate(nodes)), want)

def valid_forest() -> List<&2, G.RawNode>:
  rn("a", no_parent()) <>
  rn("b", par("a")) <>
  rn("c", par("b")) <> Nil{}

def ids_str_go(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}: ""
    case +h <> t: String.append(h, String.append(",", ids_str_go(t)))

def ids_str(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}: ""
    case +h <> t: String.append(h, String.append(",", ids_str_go(t)))

def ids_of(m: Maybe<&2, G.ValidatedGraph>) -> String:
  match m:
    case None{}: "INVALID"
    case Some{+g}: ids_str(G.graph_ids(g))

def find_is_some(+id: String, m: Maybe<&2, G.ValidatedGraph>) -> Bool:
  match m:
    case None{}: False{}
    case Some{+g}: Maybe.is_some(&2, G.GraphNode, G.find_gnode(id, G.graph_nodes(g)))

def child_ids_go(xs: List<&2, G.GraphNode>) -> String:
  match xs:
    case Nil{}: ""
    case +h <> t:
      match h:
        case G.GraphNode{+id, parent, depth}:
          String.append(id, String.append(",", child_ids_go(t)))

def children_str(+id: String, m: Maybe<&2, G.ValidatedGraph>) -> String:
  match m:
    case None{}: "INVALID"
    case Some{+g}: child_ids_go(G.graph_children(id, g))

def checks() -> List<&2, H.Check>:
  # --- valid inputs ---
  case_val("empty", Nil{}, "VALID") <>
  case_val("one-root",
    rn("index", no_parent()) <> Nil{}, "VALID") <>
  case_val("chain",
    rn("a", no_parent()) <>
    rn("b", par("a")) <>
    rn("c", par("b")) <> Nil{}, "VALID") <>
  case_val("forest",
    rn("r1", no_parent()) <>
    rn("r2", no_parent()) <>
    rn("x", par("r1")) <>
    rn("y", par("r2")) <> Nil{}, "VALID") <>
  case_val("wide",
    rn("r", no_parent()) <>
    rn("a", par("r")) <>
    rn("b", par("r")) <>
    rn("c", par("r")) <> Nil{}, "VALID") <>
  case_val("order-independent",
    rn("c", par("b")) <>
    rn("a", no_parent()) <>
    rn("b", par("a")) <> Nil{}, "VALID") <>
  # --- certificate contract on valid inputs ---
  case_cert("cert-empty", Nil{}, True{}) <>
  case_cert("cert-chain",
    rn("a", no_parent()) <>
    rn("b", par("a")) <>
    rn("c", par("b")) <> Nil{}, True{}) <>
  # --- depth values ---
  case_depth("depth-root", "a",
    rn("a", no_parent()) <>
    rn("b", par("a")) <>
    rn("c", par("b")) <> Nil{}, "0") <>
  case_depth("depth-mid", "b",
    rn("a", no_parent()) <>
    rn("b", par("a")) <>
    rn("c", par("b")) <> Nil{}, "1") <>
  case_depth("depth-leaf", "c",
    rn("a", no_parent()) <>
    rn("b", par("a")) <>
    rn("c", par("b")) <> Nil{}, "2") <>
  # --- invalid inputs, one class each ---
  case_val("dup-id",
    rn("a", no_parent()) <>
    rn("a", no_parent()) <> Nil{}, "INVALID") <>
  case_val("case-collision",
    rn("Guide", no_parent()) <>
    rn("guide", no_parent()) <> Nil{}, "INVALID") <>
  case_val("dangling",
    rn("a", no_parent()) <>
    rn("b", par("zzz")) <> Nil{}, "INVALID") <>
  case_val("self-parent",
    rn("a", no_parent()) <>
    rn("b", par("b")) <> Nil{}, "INVALID") <>
  case_val("2-cycle",
    rn("a", par("b")) <>
    rn("b", par("a")) <> Nil{}, "INVALID") <>
  case_val("3-cycle",
    rn("a", par("c")) <>
    rn("b", par("a")) <>
    rn("c", par("b")) <> Nil{}, "INVALID") <>
  case_val("upstream-of-cycle",
    rn("x", par("a")) <>
    rn("a", par("b")) <>
    rn("b", par("a")) <> Nil{}, "INVALID") <>
  # --- diagnostics content ---
  case_diag("diag-dup",
    rn("a", no_parent()) <>
    rn("a", no_parent()) <> Nil{},
    "dup:a:a,dup:a:a,") <>
  case_diag("diag-case",
    rn("Guide", no_parent()) <>
    rn("guide", no_parent()) <> Nil{},
    "case:Guide:guide,case:guide:Guide,") <>
  case_diag("diag-dangling",
    rn("a", no_parent()) <>
    rn("b", par("zzz")) <> Nil{},
    "dangling:b:zzz,") <>
  case_diag("diag-self",
    rn("a", no_parent()) <>
    rn("b", par("b")) <> Nil{},
    "self:b:b,") <>
  case_diag("diag-2cycle",
    rn("a", par("b")) <>
    rn("b", par("a")) <> Nil{},
    "cycle:a:b,cycle:b:a,") <>
  case_diag("diag-3cycle",
    rn("a", par("c")) <>
    rn("b", par("a")) <>
    rn("c", par("b")) <> Nil{},
    "cycle:a:c,cycle:b:a,cycle:c:b,") <>
  # aggregation: several violations in one input all report, in spec order
  case_diag("diag-aggregate",
    rn("a", par("zzz")) <>        # dangling
    rn("b", par("b")) <>          # self-parent
    rn("c", par("d")) <>          # cycle pair member
    rn("d", par("c")) <>          # cycle pair member
    rn("a", no_parent()) <> Nil{}, # duplicate id "a"
    "dup:a:a,dup:a:a,dangling:a:zzz,self:b:b,cycle:c:d,cycle:d:c,") <>
  case_val("aggregate-invalid",
    rn("a", par("zzz")) <>
    rn("b", par("b")) <>
    rn("c", par("d")) <>
    rn("d", par("c")) <>
    rn("a", no_parent()) <> Nil{}, "INVALID") <>
  # valid input produces no diagnostics
  case_diag("diag-none",
    rn("a", no_parent()) <>
    rn("b", par("a")) <> Nil{}, "") <>
  # --- accessors ---
  H.chk("ids-of-valid", ids_of(G.validate(valid_forest())), "a,b,c,") <>
  H.chkb("find-node", find_is_some("b", G.validate(valid_forest())), True{}) <>
  H.chkb("find-missing", find_is_some("zzz", G.validate(valid_forest())), False{}) <>
  H.chk("children-of-a", children_str("a", G.validate(valid_forest())), "b,") <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
