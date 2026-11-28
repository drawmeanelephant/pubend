import Base
import ./src/model.bend as Model
import ./src/compile.bend as Compile
import ./src/compile.bend as C
import ./src/graph.bend as Graph
import ./src/links.bend as L
import ./src/paths.bend as P
import ./src/percent.bend as Pct
import ./engine/src/document_links.bend as DocumentLinks
import ./LAWS.bend as Laws

# pubend proofs.
#
# compile_deterministic is reflexivity — trivially true of any pure def, kept
# as a regression pin against effect leakage.
#
# link_integrity is proved against the real graph-centered pipeline below.
# The proof follows the membership-only LinkOk gate through percent decoding,
# path normalization, and id membership, then bridges validated graph node ids
# to the emitted pages produced solely from that validated graph.  HTML output
# correspondence remains implementation/test-backed and is deliberately not a
# theorem here.

def Laws.compile_deterministic(config, pages):
  {==}

# --- validate_sound -------------------------------------------------------------
#
# validate(nodes) = validate_gate(cand, d_ok, c_ok) where
#   cand = assign_depths(nodes), d_ok = diags_empty(nodes),
#   c_ok = certificate_check(cand).
# Evidence that it returns Some{g} therefore splits on the two gate flags:
# either False branch normalizes the gate to None{}, contradicting Some{g};
# the True{}+True{} branch normalizes it to Some{cand}, so cand == g, and
# the certificate evidence c_ok then answers the goal directly.

# Extract the proven-equal graph out of the Maybe evidence: used as the
# rewrite motive in the True{}+True{} branch, turning Some{cand} == Some{g}
# into cand == g at the position the goal talks about.
def unmaybe_vg(+d: Graph.ValidatedGraph, m: Maybe<&2, Graph.ValidatedGraph>) -> Graph.ValidatedGraph:
  match m:
    case None{}:
      d
    case Some{+x}:
      x

# Discriminating motive for the impossible branches: maps Some{_} to the
# goal and None{} to Unit, so rewriting evidence None{} == Some{g} reduces
# the goal to a trivial Unit.
def vs_disc(+g: Graph.ValidatedGraph, m: Maybe<&2, Graph.ValidatedGraph>) -> Type:
  match m:
    case None{}:
      Unit
    case Some{x}:
      {Graph.certificate_check(g) == True{} : Bool}

def vs_c(+cand: Graph.ValidatedGraph, c: Bool,
  cev: {Graph.certificate_check(cand) == c : Bool},
  +g: Graph.ValidatedGraph,
  ev: {Graph.validate_gate(cand, True{}, c) == Some{g} : Maybe<&2, Graph.ValidatedGraph>}) ->
  {Graph.certificate_check(g) == True{} : Bool}:
  match c:
    case False{}:
      # ev : None{} == Some{g} — impossible.
      %ev : vs_disc(g, _)
      Unit{}
    case True{}:
      # ev : Some{cand} == Some{g}; unmaybe_vg reads the graph out of the
      # Maybe, so the rewrite transports the goal onto cand, which cev
      # discharges.
      %ev : {Graph.certificate_check(unmaybe_vg(cand, _)) == True{} : Bool}
      cev

def vs_d(+cand: Graph.ValidatedGraph, d: Bool, c: Bool,
  cev: {Graph.certificate_check(cand) == c : Bool},
  +g: Graph.ValidatedGraph,
  ev: {Graph.validate_gate(cand, d, c) == Some{g} : Maybe<&2, Graph.ValidatedGraph>}) ->
  {Graph.certificate_check(g) == True{} : Bool}:
  match d:
    case False{}:
      # ev : None{} == Some{g} — impossible.
      %ev : vs_disc(g, _)
      Unit{}
    case True{}:
      vs_c(cand, c, cev, g, ev)

def Laws.validate_sound(nodes, g, ev):
  vs_d(Graph.assign_depths(nodes), Graph.diags_empty(nodes),
    Graph.certificate_check(Graph.assign_depths(nodes)), {==}, g, ev)

# --- link_integrity -------------------------------------------------------------
#
# The law, discharged from the pipeline's construction.  Nothing here
# reasons about String equality propositionally: every goal stays at the
# Bool level, and the ids carried by emitted pages are literally the same
# terms the membership checks ran on — the correspondence is by
# construction, not by an equality-soundness lemma Bend does not ship.

# --- small motives -----------------------------------------------------------
#
# Discriminating motives: evidence of the form Impossible == Expected is
# eliminated by rewriting through a motive that maps Expected to the goal
# and every other constructor to Unit.  Each motive is parameterized by the
# goal's free variables — a -G type parameter cannot be returned as a
# term, so the goal is built inside the motive instead.

def lo_disc_eq2(+i: String, +j: String, o: L.LinkOutcome) -> Type:
  match o:
    case L.LinkOk{k}: {i == j : String}
    case L.LinkErr{e}: Unit
    case L.LinkPass{}: Unit

def lo_disc_bt(+m: Bool, o: L.LinkOutcome) -> Type:
  match o:
    case L.LinkOk{k}: {m == True{} : Bool}
    case L.LinkErr{e}: Unit
    case L.LinkPass{}: Unit

def lo_disc_mem(+i: String, +ids: List<&2, String>, o: L.LinkOutcome) -> Type:
  match o:
    case L.LinkOk{k}: {L.str_member(i, ids) == True{} : Bool}
    case L.LinkErr{e}: Unit
    case L.LinkPass{}: Unit

def meps_par(+ps: List<&2, Model.EmittedPage>, m: Maybe<&2, List<&2, Model.EmittedPage>>) -> Type:
  match m:
    case Some{x}: {Model.pages_all_resolve(ps, ps) == True{} : Bool}
    case None{}: Unit

def mep_inp(+l: String, +ps: List<&2, Model.EmittedPage>, m: Maybe<&2, Model.EmittedPage>) -> Type:
  match m:
    case Some{x}: {Model.id_in_pages(l, ps) == True{} : Bool}
    case None{}: Unit

def meps_inp(+l: String, +ps: List<&2, Model.EmittedPage>, m: Maybe<&2, List<&2, Model.EmittedPage>>) -> Type:
  match m:
    case Some{x}: {Model.id_in_pages(l, ps) == True{} : Bool}
    case None{}: Unit

def mpps_law(+pub: Model.Publication, m: Maybe<&2, List<&2, Graph.RawNode>>) -> Type:
  match m:
    case Some{x}: {Model.publication_links_resolve(pub) == True{} : Bool}
    case None{}: Unit

def mvg_par(+ps: List<&2, Model.EmittedPage>, m: Maybe<&2, Graph.ValidatedGraph>) -> Type:
  match m:
    case Some{g}: {Model.pages_all_resolve(ps, ps) == True{} : Bool}
    case None{}: Unit

def mpub_par(+pub: Model.Publication, m: Maybe<&2, Model.Publication>) -> Type:
  match m:
    case Some{x}: {Model.publication_links_resolve(pub) == True{} : Bool}
    case None{}: Unit

def inp_nil_disc(+l: String, +ps: List<&2, Model.EmittedPage>, b: Bool) -> Type:
  match b:
    case True{}: {Model.id_in_pages(l, ps) == True{} : Bool}
    case False{}: Unit

# Field readers used as rewrite motives.
def unlo(+d: String, o: L.LinkOutcome) -> String:
  match o:
    case L.LinkOk{+x}: x
    case L.LinkErr{e}: d
    case L.LinkPass{}: d

def res_ids(+r: L.LinkResolution) -> List<&2, String>:
  match r:
    case L.LinkResolution{+ids, errors}: ids

def uneps(+d: List<&2, Model.EmittedPage>, m: Maybe<&2, List<&2, Model.EmittedPage>>) -> List<&2, Model.EmittedPage>:
  match m:
    case None{}: d
    case Some{+x}: x

def ep_id(+e: Model.EmittedPage) -> String:
  match e:
    case Model.EmittedPage{+id, links, html}: id

def ep_links(+e: Model.EmittedPage) -> List<&2, String>:
  match e:
    case Model.EmittedPage{id, +links, html}: links

def gn_id2(+p: Graph.GraphNode) -> String:
  match p:
    case Graph.GraphNode{+id, parent, depth, title, status, document}: id

# --- eliminator lemmas over model.bend's ifs-based helpers --------------------

# id_in_pages on a cons: ifs(String.eq(l, hid), u=>True, u=>id_in_pages(l,t)).
# With head-match evidence z==True the whole ifs is True; with tail
# evidence id_in_pages(l,t)==True it is also True — one helper per branch.
def inp_here(+l: String, +hid: String, +t: List<&2, Model.EmittedPage>, z: Bool,
  ev: {z == True{} : Bool}) ->
  {Model.ifs(Bool, z, u => True{}, u => Model.id_in_pages(l, t)) == True{} : Bool}:
  match z:
    case True{}: {==}
    case False{}:
      %ev : inp_nil_disc(l, t, _)
      Unit{}

def inp_tail(+l: String, +hid: String, +t: List<&2, Model.EmittedPage>, z: Bool,
  ev: {Model.id_in_pages(l, t) == True{} : Bool}) ->
  {Model.ifs(Bool, z, u => True{}, u => Model.id_in_pages(l, t)) == True{} : Bool}:
  match z:
    case True{}: {==}
    case False{}: ev

# links_all_resolve on a cons needs both conjuncts of its ifs.
def lar_cons(+ps: List<&2, Model.EmittedPage>, +ls: List<&2, String>, z: Bool,
  evz: {z == True{} : Bool},
  evr: {Model.links_all_resolve(ps, ls) == True{} : Bool}) ->
  {Model.ifs(Bool, z, u => Model.links_all_resolve(ps, ls), u => False{}) == True{} : Bool}:
  match z:
    case True{}: evr
    case False{}: evz

# pages_all_resolve on a cons, same shape.
def par_cons(+all: List<&2, Model.EmittedPage>, +rest: List<&2, Model.EmittedPage>, z: Bool,
  evz: {z == True{} : Bool},
  evr: {Model.pages_all_resolve(rest, all) == True{} : Bool}) ->
  {Model.ifs(Bool, z, u => Model.pages_all_resolve(rest, all), u => False{}) == True{} : Bool}:
  match z:
    case True{}: evr
    case False{}: evz

# Bool.or split, in continuation form: from Bool.or(e,r)==True produce the
# goal from either side's evidence.
def or_split(-G: Type, e: Bool, r: Bool,
  ev: {Bool.or(e, r) == True{} : Bool},
  fe: {e == True{} : Bool} -> G,
  fr: {r == True{} : Bool} -> G) -> G:
  match e:
    case True{}:
      fe({==})
    case False{}:
      fr(ev)

# --- resolve chain: LinkOk implies membership ---------------------------------

# resolve_mem returns LinkOk{i} only when its membership flag was True,
# and the payload is then exactly the checked id.
def li_mem_ij(+src: String, +t: String, +ids: List<&2, String>, +j: String, m: Bool, +i: String,
  ev: {L.resolve_mem(src, t, ids, j, m) == L.LinkOk{i} : L.LinkOutcome}) ->
  {i == j : String}:
  match m:
    case False{}:
      %ev : lo_disc_eq2(i, j, _)
      Unit{}
    case True{}:
      %ev : {unlo(i, _) == j : String}
      {==}

def li_mem_m(+src: String, +t: String, +ids: List<&2, String>, +j: String, m: Bool, +i: String,
  ev: {L.resolve_mem(src, t, ids, j, m) == L.LinkOk{i} : L.LinkOutcome}) ->
  {m == True{} : Bool}:
  match m:
    case False{}:
      %ev : lo_disc_bt(m, _)
      Unit{}
    case True{}:
      {==}

def li_norm(+src: String, +t: String, +ids: List<&2, String>, n: P.PathResult, +i: String,
  +ev: {L.resolve_norm(src, t, ids, n) == L.LinkOk{i} : L.LinkOutcome}) ->
  {L.str_member(i, ids) == True{} : Bool}:
  match n:
    case P.PathEscape{}:
      %ev : lo_disc_mem(i, ids, _)
      Unit{}
    case P.PathOk{+path}:
      %Equal.sym(String, i, P.path_strip_md(path), li_mem_ij(src, t, ids, P.path_strip_md(path),
        L.str_member(P.path_strip_md(path), ids), i, ev)) :
        {L.str_member(_, ids) == True{} : Bool}
      li_mem_m(src, t, ids, P.path_strip_md(path),
        L.str_member(P.path_strip_md(path), ids), i, ev)

def li_decode(+src: String, +t: String, +ids: List<&2, String>, d: Pct.PercentResult, +i: String,
  ev: {L.resolve_decode(src, t, ids, d) == L.LinkOk{i} : L.LinkOutcome}) ->
  {L.str_member(i, ids) == True{} : Bool}:
  match d:
    case Pct.PercentMalformed{}:
      %ev : lo_disc_mem(i, ids, _)
      Unit{}
    case Pct.PercentInvalidUtf8{}:
      %ev : lo_disc_mem(i, ids, _)
      Unit{}
    case Pct.PercentOk{+decoded}:
      li_norm(src, t, ids, P.path_normalize(P.path_join(P.path_dirname(src), decoded)), i, ev)

def li_query(+src: String, +t: String, +ids: List<&2, String>, q: Bool, +i: String,
  ev: {L.resolve_query(src, t, ids, q) == L.LinkOk{i} : L.LinkOutcome}) ->
  {L.str_member(i, ids) == True{} : Bool}:
  match q:
    case True{}:
      %ev : lo_disc_mem(i, ids, _)
      Unit{}
    case False{}:
      li_decode(src, t, ids, Pct.percent_decode(P.path_strip_fragment(t)), i, ev)

def li_cls(+src: String, +t: String, +ids: List<&2, String>, c: L.LinkClass, +i: String,
  ev: {L.resolve_cls(src, t, ids, c) == L.LinkOk{i} : L.LinkOutcome}) ->
  {L.str_member(i, ids) == True{} : Bool}:
  match c:
    case L.LExternal{}:
      %ev : lo_disc_mem(i, ids, _)
      Unit{}
    case L.LPassthrough{}:
      %ev : lo_disc_mem(i, ids, _)
      Unit{}
    case L.LInternal{}:
      li_query(src, t, ids, P.path_has_query(P.path_strip_fragment(t)), i, ev)

# A resolved link outcome carries a member of the id set — the per-link
# kernel of the flagship law.
def li_one(+src: String, +t: String, +ids: List<&2, String>, +i: String,
  ev: {L.resolve_one(src, t, ids) == L.LinkOk{i} : L.LinkOutcome}) ->
  {L.str_member(i, ids) == True{} : Bool}:
  li_cls(src, t, ids, L.classify_link(t), i, ev)

# --- emitted-page identity ---------------------------------------------------
#
# The emitted id and link list are literally the validated node id and the
# verified resolution — extracted here as equalities for the bridge lemmas.

def unl_hd(+d: Model.EmittedPage, m: Maybe<&2, List<&2, Model.EmittedPage>>) -> Model.EmittedPage:
  match m:
    case None{}: d
    case Some{+xs}:
      match xs:
        case Nil{}: d
        case +h <> t: h

def unl_tl(+d: List<&2, Model.EmittedPage>, m: Maybe<&2, List<&2, Model.EmittedPage>>) -> List<&2, Model.EmittedPage>:
  match m:
    case None{}: d
    case Some{+xs}:
      match xs:
        case Nil{}: d
        case h <> +t: t

def unep_id(+d: String, m: Maybe<&2, Model.EmittedPage>) -> String:
  match m:
    case None{}: d
    case Some{+x}: ep_id(x)

def unep_links(+d: List<&2, String>, m: Maybe<&2, Model.EmittedPage>) -> List<&2, String>:
  match m:
    case None{}: d
    case Some{+x}: ep_links(x)

def unpub_m(+d: Model.Publication, m: Maybe<&2, Model.Publication>) -> Model.Publication:
  match m:
    case None{}: d
    case Some{+x}: x

def ld_disc(+l: String, xs: List<&2, Model.EmittedPage>) -> Type:
  match xs:
    case Nil{}: {Model.id_in_pages(l, xs) == True{} : Bool}
    case +h <> t: Unit

def mep_lar(+fps: List<&2, Model.EmittedPage>, +e: Model.EmittedPage, m: Maybe<&2, Model.EmittedPage>) -> Type:
  match m:
    case Some{x}: {Model.links_all_resolve(fps, ep_links(e)) == True{} : Bool}
    case None{}: Unit

def mep_eqid(+e: Model.EmittedPage, +id2: String, m: Maybe<&2, Model.EmittedPage>) -> Type:
  match m:
    case Some{x}: {ep_id(e) == id2 : String}
    case None{}: Unit

# emit_gate produces EmittedPage{id2,lids,html} or nothing.
def lem_egate_id(+id2: String, +lids: List<&2, String>, +html: String, clean: Bool,
  +e: Model.EmittedPage,
  +ev: {C.emit_gate(id2, lids, html, clean) == Some{e} : Maybe<&2, Model.EmittedPage>}) ->
  {ep_id(e) == id2 : String}:
  match clean:
    case False{}:
      %ev : mep_eqid(e, id2, _)
      Unit{}
    case True{}:
      %ev : {unep_id(id2, _) == id2 : String}
      {==}

def lem_efin_id(+id2: String, +html: String, r: L.LinkResolution, +e: Model.EmittedPage,
  +ev: {C.emit_fin(id2, html, r) == Some{e} : Maybe<&2, Model.EmittedPage>}) ->
  {ep_id(e) == id2 : String}:
  match r:
    case L.LinkResolution{+lids, +errors}:
      lem_egate_id(id2, lids, html, List.is_empty(&2, L.LinkError, errors), e, ev)

# The emitted page's id is the validated graph node's id.
def lem_eid(p: Graph.GraphNode, +ids: List<&2, Graph.GraphNode>, +e: Model.EmittedPage,
  +ev: {C.emit_one(ids, p) == Some{e} : Maybe<&2, Model.EmittedPage>}) ->
  {ep_id(e) == gn_id2(p) : String}:
  match p:
    case Graph.GraphNode{+id, +parent, depth, +title, status, +document}:
      lem_efin_id(id, C.render_node_html(ids, id, parent, title, document),
        L.resolve_page_links(id, DocumentLinks.document_link_targets(document), Graph.graph_ids_go(ids)), e, ev)

# --- the membership bridge ------------------------------------------------------
#
# lem_B: a member of the prepped id set is a member of the emitted page
# set.  Induction over the prep list, following emit_cons's Some-chain.


# List-cons injectivity through the Maybe wrapper: Some{ep<>rest} ==
# Some{phd<>ptl} yields the component equalities via list-head/tail motives.
def cons_hd_eq(+ep: Model.EmittedPage, +rest: List<&2, Model.EmittedPage>,
  +phd: Model.EmittedPage, +ptl: List<&2, Model.EmittedPage>,
  ev: {Some{ep <> rest} == Some{phd <> ptl} : Maybe<&2, List<&2, Model.EmittedPage>>}) ->
  {ep == phd : Model.EmittedPage}:
  %ev : {ep == unl_hd(phd, _) : Model.EmittedPage}
  {==}

def cons_tl_eq(+ep: Model.EmittedPage, +rest: List<&2, Model.EmittedPage>,
  +phd: Model.EmittedPage, +ptl: List<&2, Model.EmittedPage>,
  ev: {Some{ep <> rest} == Some{phd <> ptl} : Maybe<&2, List<&2, Model.EmittedPage>>}) ->
  {rest == ptl : List<&2, Model.EmittedPage>}:
  %ev : {rest == unl_tl(ptl, _) : List<&2, Model.EmittedPage>}
  {==}

def eq_str_tr(+l: String, +a: String, +b: String,
  eab: {a == b : String},
  ev: {String.eq(l, a) == True{} : Bool}) ->
  {String.eq(l, b) == True{} : Bool}:
  %eab : {String.eq(l, _) == True{} : Bool}
  ev

def ep_tr(+ids: List<&2, Graph.GraphNode>, +x: Graph.GraphNode, +ep: Model.EmittedPage, +phd: Model.EmittedPage,
  eeq: {ep == phd : Model.EmittedPage},
  ev: {C.emit_one(ids, x) == Some{ep} : Maybe<&2, Model.EmittedPage>}) ->
  {C.emit_one(ids, x) == Some{phd} : Maybe<&2, Model.EmittedPage>}:
  %eeq : {C.emit_one(ids, x) == Some{_} : Maybe<&2, Model.EmittedPage>}
  ev

# The head-position answer of the bridge induction: the str_member hit is at
# the head prep page, whose emitted page is the head of the emitted list.
# Non-recursive — defined before the worker that calls it.
def lem_BW_herex(+l: String, +x: Graph.GraphNode, +ids: List<&2, Graph.GraphNode>,
  +ep: Model.EmittedPage, +rest: List<&2, Model.EmittedPage>,
  +phd: Model.EmittedPage, +ptl: List<&2, Model.EmittedPage>, +peid: String,
  +e1: {C.emit_cons(Some{ep}, Some{rest}) == Some{phd <> ptl} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +ez: {String.eq(l, gn_id2(x)) == True{} : Bool},
  +epe: {ep_id(phd) == peid : String},
  +ev1: {C.emit_one(ids, x) == Some{ep} : Maybe<&2, Model.EmittedPage>}) ->
  {Model.ifs(Bool, String.eq(l, peid), u => True{}, u => Model.id_in_pages(l, ptl)) == True{} : Bool}:
  +epeq = cons_hd_eq(ep, rest, phd, ptl, e1)
  +eidev = lem_eid(x, ids, phd, ep_tr(ids, x, ep, phd, epeq, ev1))
  +xpe = Equal.trans(String, gn_id2(x), ep_id(phd), peid,
    Equal.sym(String, ep_id(phd), gn_id2(x), eidev), epe)
  inp_here(l, peid, ptl, String.eq(l, peid), eq_str_tr(l, gn_id2(x), peid, xpe, ez))

# emit_all(ids, x2<>xt2) == Some{rest} composed with rest == ptl gives the
# tail's own emit evidence — i.e. emit_cons(emit_one(x2), emit_all(xt2)).
def ea_tr2(+ids: List<&2, Graph.GraphNode>, +x2: Graph.GraphNode, +xt2: List<&2, Graph.GraphNode>,
  +rest: List<&2, Model.EmittedPage>, +ptl: List<&2, Model.EmittedPage>,
  e: {rest == ptl : List<&2, Model.EmittedPage>},
  ev: {C.emit_all(ids, x2 <> xt2) == Some{rest} : Maybe<&2, List<&2, Model.EmittedPage>>}) ->
  {C.emit_cons(C.emit_one(ids, x2), C.emit_all(ids, xt2)) == Some{ptl} : Maybe<&2, List<&2, Model.EmittedPage>>}:
  %e : {C.emit_cons(C.emit_one(ids, x2), C.emit_all(ids, xt2)) == Some{_} : Maybe<&2, List<&2, Model.EmittedPage>>}
  ev

# The bridge worker.  emit_cons's Some-chain is taken apart by matching the
# generalized Maybe params (m1, mrest); the str_member disjunction rides
# along as Bool.or(z, tail).  Self-recursive on xt — Bend forbids forward
# references, so the whole case tree lives in one def.
def lem_BW(+l: String, xt: List<&2, Graph.GraphNode>, +x: Graph.GraphNode, +ids: List<&2, Graph.GraphNode>,
  m1: Maybe<&2, Model.EmittedPage>, mrest: Maybe<&2, List<&2, Model.EmittedPage>>,
  z: Bool, ps: List<&2, Model.EmittedPage>,
  +e1: {C.emit_cons(m1, mrest) == Some{ps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +e2: {Bool.or(z, L.str_member(l, Graph.graph_ids_go(xt))) == True{} : Bool},
  +ez: {z == String.eq(l, gn_id2(x)) : Bool},
  +ev1: {C.emit_one(ids, x) == m1 : Maybe<&2, Model.EmittedPage>},
  +evrest: {C.emit_all(ids, xt) == mrest : Maybe<&2, List<&2, Model.EmittedPage>>}) ->
  {Model.id_in_pages(l, ps) == True{} : Bool}:
  match xt:
    case Nil{}:
      match m1:
        case None{}:
          %e1 : meps_inp(l, ps, _)
          Unit{}
        case Some{+ep}:
          match mrest:
            case None{}:
              %e1 : meps_inp(l, ps, _)
              Unit{}
            case Some{+rest}:
              match z:
                case True{}:
                  match ps:
                    case Nil{}:
                      %e1 : ld_disc(l, uneps(Nil{}, _))
                      Unit{}
                    case +phd <> +ptl:
                      match phd:
                        case Model.EmittedPage{+peid, +plinks, +phtml}:
                          lem_BW_herex(l, x, ids, ep, rest,
                            Model.EmittedPage{peid, plinks, phtml}, ptl, peid, e1,
                            Equal.sym(Bool, z, String.eq(l, gn_id2(x)), ez), {==}, ev1)
                case False{}:
                  %e2 : inp_nil_disc(l, ps, _)
                  Unit{}
    case +x2 <> +xt2:
      match x2:
        case Graph.GraphNode{+x2id, +parent2, +depth2, +title2, +status2, +document2}:
          match m1:
            case None{}:
              %e1 : meps_inp(l, ps, _)
              Unit{}
            case Some{+ep}:
              match mrest:
                case None{}:
                  %e1 : meps_inp(l, ps, _)
                  Unit{}
                case Some{+rest}:
                  match z:
                    case True{}:
                      match ps:
                        case Nil{}:
                          %e1 : ld_disc(l, uneps(Nil{}, _))
                          Unit{}
                        case +phd <> +ptl:
                          match phd:
                            case Model.EmittedPage{+peid, +plinks, +phtml}:
                              lem_BW_herex(l, x, ids, ep, rest,
                                Model.EmittedPage{peid, plinks, phtml}, ptl, peid, e1,
                                Equal.sym(Bool, z, String.eq(l, gn_id2(x)), ez), {==}, ev1)
                    case False{}:
                      match ps:
                        case Nil{}:
                          %e1 : ld_disc(l, uneps(Nil{}, _))
                          Unit{}
                        case +phd <> +ptl:
                          match phd:
                            case Model.EmittedPage{+peid, +plinks, +phtml}:
                              +rteq = cons_tl_eq(ep, rest,
                                Model.EmittedPage{peid, plinks, phtml}, ptl, e1)
                              inp_tail(l, peid, ptl, String.eq(l, peid),
                                lem_BW(l, xt2, Graph.GraphNode{x2id, parent2, depth2, title2, status2, document2}, ids,
                                  C.emit_one(ids, Graph.GraphNode{x2id, parent2, depth2, title2, status2, document2}),
                                  C.emit_all(ids, xt2),
                                  String.eq(l, x2id), ptl,
                                  ea_tr2(ids, Graph.GraphNode{x2id, parent2, depth2, title2, status2, document2}, xt2,
                                    rest, ptl, rteq, evrest),
                                  e2, {==}, {==}, {==}))

def lem_B(+l: String, xs: List<&2, Graph.GraphNode>, +ids: List<&2, Graph.GraphNode>,
  ps: List<&2, Model.EmittedPage>,
  +e1: {C.emit_all(ids, xs) == Some{ps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +e2: {L.str_member(l, Graph.graph_ids_go(xs)) == True{} : Bool}) ->
  {Model.id_in_pages(l, ps) == True{} : Bool}:
  match xs:
    case Nil{}:
      %e2 : inp_nil_disc(l, ps, _)
      Unit{}
    case +x <> +xt:
      match x:
        case Graph.GraphNode{+xid, +parent, +depth, +title, +status, +document}:
          lem_BW(l, xt, Graph.GraphNode{xid, parent, depth, title, status, document}, ids,
            C.emit_one(ids, Graph.GraphNode{xid, parent, depth, title, status, document}), C.emit_all(ids, xt),
            String.eq(l, xid), ps, e1, e2, {==}, {==}, {==})

# Tail evidence for the Nil-resolution case: the resolved-id half is empty.
def lar_of_nil(+fps: List<&2, Model.EmittedPage>, +rs: List<&2, String>, +es: List<&2, L.LinkError>,
  ev: {L.LinkResolution{Nil{}, Nil{}} == L.LinkResolution{rs, es} : L.LinkResolution}) ->
  {Model.links_all_resolve(fps, rs) == True{} : Bool}:
  %ev : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
  {==}

# --- the resolve fold ---------------------------------------------------------
#
# res_go's accumulator: every id consed into the LinkResolution passed the
# membership gate, so the emitted link list resolves element-wise against
# the full emitted page set.  lem_B supplies the member→in_pages bridge.

def li_resW(+src: String, t: List<&2, String>, +h: String,
  o: L.LinkOutcome, rest: L.LinkResolution, r: L.LinkResolution,
  +fpps: List<&2, Graph.GraphNode>, +fps: List<&2, Model.EmittedPage>,
  +eve: {C.emit_all(fpps, fpps) == Some{fps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +evr: {L.res_cons(src, Graph.graph_ids_go(fpps), o, rest) == r : L.LinkResolution},
  +evo: {L.resolve_one(src, h, Graph.graph_ids_go(fpps)) == o : L.LinkOutcome},
  +evrest: {L.res_go(src, t, Graph.graph_ids_go(fpps)) == rest : L.LinkResolution}) ->
  {Model.links_all_resolve(fps, res_ids(r)) == True{} : Bool}:
  match t:
    case Nil{}:
      match o:
        case L.LinkPass{}:
          %evr : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
          %evrest : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
          {==}
        case L.LinkErr{+e}:
          match rest:
            case L.LinkResolution{+rs, +es}:
              %evr : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
              %evrest : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
              {==}
        case L.LinkOk{+i}:
          match rest:
            case L.LinkResolution{+rs, +es}:
              %evr : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
              lar_cons(fps, rs, Model.id_in_pages(i, fps),
                lem_B(i, fpps, fpps, fps, eve,
                  li_one(src, h, Graph.graph_ids_go(fpps), i, evo)),
                lar_of_nil(fps, rs, es, evrest))
    case +h2 <> +t2:
      match o:
        case L.LinkPass{}:
          %evr : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
          li_resW(src, t2, h2, L.resolve_one(src, h2, Graph.graph_ids_go(fpps)), L.res_go(src, t2, Graph.graph_ids_go(fpps)), rest,
            fpps, fps, eve, evrest, {==}, {==})
        case L.LinkErr{+e}:
          match rest:
            case L.LinkResolution{+rs, +es}:
              %evr : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
              li_resW(src, t2, h2, L.resolve_one(src, h2, Graph.graph_ids_go(fpps)), L.res_go(src, t2, Graph.graph_ids_go(fpps)),
                L.LinkResolution{rs, es}, fpps, fps, eve, evrest, {==}, {==})
        case L.LinkOk{+i}:
          match rest:
            case L.LinkResolution{+rs, +es}:
              %evr : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
              lar_cons(fps, rs, Model.id_in_pages(i, fps),
                lem_B(i, fpps, fpps, fps, eve,
                  li_one(src, h, Graph.graph_ids_go(fpps), i, evo)),
                li_resW(src, t2, h2, L.resolve_one(src, h2, Graph.graph_ids_go(fpps)), L.res_go(src, t2, Graph.graph_ids_go(fpps)),
                  L.LinkResolution{rs, es}, fpps, fps, eve, evrest, {==}, {==}))

def li_res(+src: String, ts: List<&2, String>, r: L.LinkResolution,
  +fpps: List<&2, Graph.GraphNode>, +fps: List<&2, Model.EmittedPage>,
  +eve: {C.emit_all(fpps, fpps) == Some{fps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +evr: {L.res_go(src, ts, Graph.graph_ids_go(fpps)) == r : L.LinkResolution}) ->
  {Model.links_all_resolve(fps, res_ids(r)) == True{} : Bool}:
  match ts:
    case Nil{}:
      %evr : {Model.links_all_resolve(fps, res_ids(_)) == True{} : Bool}
      {==}
    case +h <> +t:
      li_resW(src, t, h, L.resolve_one(src, h, Graph.graph_ids_go(fpps)), L.res_go(src, t, Graph.graph_ids_go(fpps)), r,
        fpps, fps, eve, evr, {==}, {==})

# --- per-page emitted links ----------------------------------------------------

def lem_efin(+id2: String, +html: String, +ts: List<&2, String>,
  +lids: List<&2, String>, +errors: List<&2, L.LinkError>, clean: Bool,
  +e: Model.EmittedPage, +fpps: List<&2, Graph.GraphNode>,
  +fps: List<&2, Model.EmittedPage>,
  +eve: {C.emit_all(fpps, fpps) == Some{fps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +evr: {L.res_go(id2, ts, Graph.graph_ids_go(fpps)) == L.LinkResolution{lids, errors} : L.LinkResolution},
  +ev: {C.emit_gate(id2, lids, html, clean) == Some{e} : Maybe<&2, Model.EmittedPage>}) ->
  {Model.links_all_resolve(fps, ep_links(e)) == True{} : Bool}:
  match clean:
    case False{}:
      %ev : mep_lar(fps, e, _)
      Unit{}
    case True{}:
      %ev : {Model.links_all_resolve(fps, unep_links(lids, _)) == True{} : Bool}
      li_res(id2, ts, L.LinkResolution{lids, errors}, fpps, fps, eve, evr)

def lem_efin_r(+id2: String, +html: String, +ts: List<&2, String>, r: L.LinkResolution,
  +e: Model.EmittedPage, +fpps: List<&2, Graph.GraphNode>,
  +fps: List<&2, Model.EmittedPage>,
  +eve: {C.emit_all(fpps, fpps) == Some{fps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +evr: {L.res_go(id2, ts, Graph.graph_ids_go(fpps)) == r : L.LinkResolution},
  +ev: {C.emit_fin(id2, html, r) == Some{e} : Maybe<&2, Model.EmittedPage>}) ->
  {Model.links_all_resolve(fps, ep_links(e)) == True{} : Bool}:
  match r:
    case L.LinkResolution{+lids, +errors}:
      lem_efin(id2, html, ts, lids, errors, List.is_empty(&2, L.LinkError, errors),
        e, fpps, fps, eve, evr, ev)

# One validated graph node's emitted links all resolve against the full emitted set.
def lem_elinks(p: Graph.GraphNode, +e: Model.EmittedPage,
  +fpps: List<&2, Graph.GraphNode>, +fps: List<&2, Model.EmittedPage>,
  +eve: {C.emit_all(fpps, fpps) == Some{fps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +ev: {C.emit_one(fpps, p) == Some{e} : Maybe<&2, Model.EmittedPage>}) ->
  {Model.links_all_resolve(fps, ep_links(e)) == True{} : Bool}:
  match p:
    case Graph.GraphNode{+id, +parent, depth, +title, status, +document}:
      lem_efin_r(id, C.render_node_html(fpps, id, parent, title, document),
        DocumentLinks.document_link_targets(document),
        L.resolve_page_links(id, DocumentLinks.document_link_targets(document), Graph.graph_ids_go(fpps)),
        e, fpps, fps, eve, {==}, ev)

# --- the emit_all fold ----------------------------------------------------------

def meps_par2(+fps: List<&2, Model.EmittedPage>, +ps: List<&2, Model.EmittedPage>,
  m: Maybe<&2, List<&2, Model.EmittedPage>>) -> Type:
  match m:
    case Some{x}: {Model.pages_all_resolve(ps, fps) == True{} : Bool}
    case None{}: Unit

def ldp_disc(+fps: List<&2, Model.EmittedPage>, xs: List<&2, Model.EmittedPage>) -> Type:
  match xs:
    case Nil{}: {Model.pages_all_resolve(xs, fps) == True{} : Bool}
    case +h <> t: Unit

def xsnil_par(+fps: List<&2, Model.EmittedPage>, +ps: List<&2, Model.EmittedPage>,
  xs: List<&2, Model.EmittedPage>) -> Type:
  match xs:
    case Nil{}: Unit
    case +h <> t: {Model.pages_all_resolve(ps, fps) == True{} : Bool}

def snc_par_disc(+fps: List<&2, Model.EmittedPage>, +ps: List<&2, Model.EmittedPage>,
  m: Maybe<&2, List<&2, Model.EmittedPage>>) -> Type:
  match m:
    case None{}: Unit
    case Some{+xs}: xsnil_par(fps, ps, xs)

def par_tl_tr(+fps: List<&2, Model.EmittedPage>, +rest: List<&2, Model.EmittedPage>,
  +ptl: List<&2, Model.EmittedPage>,
  e: {rest == ptl : List<&2, Model.EmittedPage>},
  ev: {Model.pages_all_resolve(rest, fps) == True{} : Bool}) ->
  {Model.pages_all_resolve(ptl, fps) == True{} : Bool}:
  %e : {Model.pages_all_resolve(_, fps) == True{} : Bool}
  ev

# The worker.  fpps/ids/fps are the FULL prep/id/emitted sets, constant
# through the recursion; x/xt are the current head/tail of the prep walk.
def lem_ea(+fpps: List<&2, Graph.GraphNode>, +fps: List<&2, Model.EmittedPage>,
  +eve: {C.emit_all(fpps, fpps) == Some{fps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  xt: List<&2, Graph.GraphNode>, +x: Graph.GraphNode,
  m1: Maybe<&2, Model.EmittedPage>, mrest: Maybe<&2, List<&2, Model.EmittedPage>>,
  ps: List<&2, Model.EmittedPage>,
  +e1: {C.emit_cons(m1, mrest) == Some{ps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  +ev1: {C.emit_one(fpps, x) == m1 : Maybe<&2, Model.EmittedPage>},
  +evrest: {C.emit_all(fpps, xt) == mrest : Maybe<&2, List<&2, Model.EmittedPage>>}) ->
  {Model.pages_all_resolve(ps, fps) == True{} : Bool}:
  match xt:
    case Nil{}:
      match m1:
        case None{}:
          %e1 : meps_par2(fps, ps, _)
          Unit{}
        case Some{+ep}:
          match mrest:
            case None{}:
              %e1 : meps_par2(fps, ps, _)
              Unit{}
            case Some{+rest}:
              match rest:
                case Nil{}:
                  match ps:
                    case Nil{}:
                      %e1 : ldp_disc(fps, uneps(Nil{}, _))
                      Unit{}
                    case +phd <> +ptl:
                      match phd:
                        case Model.EmittedPage{+peid, +plinks, +phtml}:
                          +epeq = cons_hd_eq(ep, Nil{},
                            Model.EmittedPage{peid, plinks, phtml}, ptl, e1)
                          +rteq = cons_tl_eq(ep, Nil{},
                            Model.EmittedPage{peid, plinks, phtml}, ptl, e1)
                          par_cons(fps, ptl, Model.links_all_resolve(fps, plinks),
                            lem_elinks(x, Model.EmittedPage{peid, plinks, phtml},
                              fpps, fps, eve,
                              ep_tr(fpps, x, ep, Model.EmittedPage{peid, plinks, phtml}, epeq, ev1)),
                            par_tl_tr(fps, Nil{}, ptl, rteq, {==}))
                case +r2 <> +rt2:
                  %evrest : snc_par_disc(fps, ps, _)
                  Unit{}
    case +x2 <> +xt2:
      match m1:
        case None{}:
          %e1 : meps_par2(fps, ps, _)
          Unit{}
        case Some{+ep}:
          match mrest:
            case None{}:
              %e1 : meps_par2(fps, ps, _)
              Unit{}
            case Some{+rest}:
              match ps:
                case Nil{}:
                  %e1 : ldp_disc(fps, uneps(Nil{}, _))
                  Unit{}
                case +phd <> +ptl:
                  match phd:
                    case Model.EmittedPage{+peid, +plinks, +phtml}:
                      +epeq = cons_hd_eq(ep, rest,
                        Model.EmittedPage{peid, plinks, phtml}, ptl, e1)
                      +rteq = cons_tl_eq(ep, rest,
                        Model.EmittedPage{peid, plinks, phtml}, ptl, e1)
                      par_cons(fps, ptl, Model.links_all_resolve(fps, plinks),
                        lem_elinks(x, Model.EmittedPage{peid, plinks, phtml},
                          fpps, fps, eve,
                          ep_tr(fpps, x, ep, Model.EmittedPage{peid, plinks, phtml}, epeq, ev1)),
                        par_tl_tr(fps, rest, ptl, rteq,
                          lem_ea(fpps, fps, eve, xt2, x2,
                            C.emit_one(fpps, x2), C.emit_all(fpps, xt2), rest,
                            evrest, {==}, {==})))

def lem_emit_all(+fpps: List<&2, Graph.GraphNode>, +fps: List<&2, Model.EmittedPage>,
  +eve: {C.emit_all(fpps, fpps) == Some{fps} : Maybe<&2, List<&2, Model.EmittedPage>>},
  xs: List<&2, Graph.GraphNode>, +ps: List<&2, Model.EmittedPage>,
  +e1: {C.emit_all(fpps, xs) == Some{ps} : Maybe<&2, List<&2, Model.EmittedPage>>}) ->
  {Model.pages_all_resolve(ps, fps) == True{} : Bool}:
  match xs:
    case Nil{}:
      %e1 : {Model.pages_all_resolve(uneps(Nil{}, _), fps) == True{} : Bool}
      {==}
    case +x <> +xt:
      lem_ea(fpps, fps, eve, xt, x, C.emit_one(fpps, x), C.emit_all(fpps, xt), ps,
        e1, {==}, {==})

# --- gate elimination -----------------------------------------------------------

def li_gate(v: Maybe<&2, Graph.ValidatedGraph>, e: Maybe<&2, List<&2, Model.EmittedPage>>,
  +pub: Model.Publication,
  +eve: {C.emit_validated(v) == e : Maybe<&2, List<&2, Model.EmittedPage>>},
  +ev: {C.compile_gate(v, e) == Some{pub} : Maybe<&2, Model.Publication>}) ->
  {Model.publication_links_resolve(pub) == True{} : Bool}:
  match v:
    case None{}:
      %ev : mpub_par(pub, _)
      Unit{}
    case Some{+g}:
      match g:
        case Graph.ValidatedGraph{+nodes}:
          match e:
            case None{}:
              %ev : mpub_par(pub, _)
              Unit{}
            case Some{+ps}:
              %ev : {Model.publication_links_resolve(unpub_m(pub, _)) == True{} : Bool}
              lem_emit_all(nodes, ps, eve, nodes, ps, eve)

def li_step(+config: Model.Config, +pages: List<&2, Model.SourcePage>,
  prepped: Maybe<&2, List<&2, Graph.RawNode>>, +pub: Model.Publication,
  +evp: {C.prep_all(pages) == prepped : Maybe<&2, List<&2, Graph.RawNode>>},
  +ev: {C.compile_step(prepped) == Some{pub} : Maybe<&2, Model.Publication>}) ->
  {Model.publication_links_resolve(pub) == True{} : Bool}:
  match prepped:
    case None{}:
      %ev : mpub_par(pub, _)
      Unit{}
    case Some{+nodes}:
      li_gate(Graph.validate(nodes), C.emit_validated(Graph.validate(nodes)), pub, {==}, ev)

def Laws.link_integrity(config, pages, pub, ev):
  li_step(config, pages, C.prep_all(pages), pub, {==}, ev)
