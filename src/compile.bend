import Base
import ./model.bend as Model
import ./frontmatter.bend as Fm
import ./paths.bend as P
import ./graph.bend as G
import ./links.bend as L
import ../engine/src/parser/markdown.bend as Markdown
import ../engine/src/render/html.bend as Html
import ../engine/src/parallel/engine.bend as Eng

# The real compile pipeline (docs/v0-spec.md §6), pure over pre-loaded
# pages.  IO — discovery, reading, writing — stays outside in the shell.
#
#   per page: frontmatter parse (spec §3)         — any error kills the build
#   join:     graph validation over derived nodes — the sequential join;
#                 every downstream stage consumes the ValidatedGraph verdict
#   per page: engine markdown parse → link targets → §5 resolution
#             → engine HTML render → EmittedPage
#   publish:  Publication over the emitted pages
#
# The signature is the stable contract LAWS.bend quantifies over:
#
#   compile is pure.  IO happens outside it.  What is proved about compile
#   therefore never depends on the filesystem.
#
# As everywhere in this codebase, every branch point is a named helper
# matching on a parameter — prep_gate on the frontmatter-error Bool,
# emit_gate on the link-error Bool, compile_gate/compile_step on the Maybe
# results — so the laws can quantify over the scrutinees instead of
# fighting stuck eliminations.

# The per-page intermediate: frontmatter-checked, markdown-body carrying.
# This is the forked unit of per-page work the pipeline maps over.
type PagePrep is Data:
  PagePrep{id: String, parent: Maybe<&2, String>, title: Maybe<&2, String>, body: String}

# --- small factories ---------------------------------------------------------

def pp_some(+id: String, p: Maybe<&2, String>, t: Maybe<&2, String>, +b: String) -> Maybe<&2, PagePrep>:
  Some{PagePrep{id, p, t, b}}

def pp_none() -> Maybe<&2, PagePrep>:
  None{}

def ms_none() -> Maybe<&2, String>:
  None{}

def pps_cons(+h: PagePrep, +t: List<&2, PagePrep>) -> Maybe<&2, List<&2, PagePrep>>:
  Some{h <> t}

def pps_nil() -> Maybe<&2, List<&2, PagePrep>>:
  Some{Nil{}}

def pps_none() -> Maybe<&2, List<&2, PagePrep>>:
  None{}

def emit_some(+id: String, +links: List<&2, String>, +html: String) -> Maybe<&2, Model.EmittedPage>:
  Some{Model.EmittedPage{id, links, html}}

def emit_none() -> Maybe<&2, Model.EmittedPage>:
  None{}

def eps_cons(+h: Model.EmittedPage, +t: List<&2, Model.EmittedPage>) -> Maybe<&2, List<&2, Model.EmittedPage>>:
  Some{h <> t}

def eps_nil() -> Maybe<&2, List<&2, Model.EmittedPage>>:
  Some{Nil{}}

def eps_none() -> Maybe<&2, List<&2, Model.EmittedPage>>:
  None{}

def pub_of(+ps: List<&2, Model.EmittedPage>) -> Maybe<&2, Model.Publication>:
  Some{Model.Publication{ps}}

def pub_none() -> Maybe<&2, Model.Publication>:
  None{}

# --- stage 1: frontmatter parse per page -------------------------------------

# Frontmatter is optional (spec §3): no block means a root page with no
# title — defaults, not a failure.  Errors alone veto, via prep_gate.
def prep_meta(+id: String, +body: String, m: Maybe<&2, Fm.FmMeta>) -> Maybe<&2, PagePrep>:
  match m:
    case None{}:
      pp_some(id, ms_none(), ms_none(), body)
    case Some{+fm}:
      match fm:
        case Fm.FmMeta{+title, +parent, status}:
          pp_some(id, parent, title, body)

# Frontmatter errors veto the page — the closed grammar is enforced here.
def prep_gate(+id: String, +body: String, m: Maybe<&2, Fm.FmMeta>, clean: Bool) -> Maybe<&2, PagePrep>:
  match clean:
    case False{}:
      pp_none()
    case True{}:
      prep_meta(id, body, m)

def prep_fin(+id: String, r: Fm.FmResult) -> Maybe<&2, PagePrep>:
  match r:
    case Fm.FmResult{+meta, +body, +errors}:
      prep_gate(id, body, meta, List.is_empty(&2, Fm.FmError, errors))

def prep_page(p: Model.SourcePage) -> Maybe<&2, PagePrep>:
  match p:
    case Model.SourcePage{+id, +body}:
      prep_fin(id, Fm.parse_frontmatter(body))

def prep_cons(m: Maybe<&2, PagePrep>, rest: Maybe<&2, List<&2, PagePrep>>) -> Maybe<&2, List<&2, PagePrep>>:
  match m:
    case None{}:
      pps_none()
    case Some{+p}:
      match rest:
        case None{}:
          pps_none()
        case Some{+ps}:
          pps_cons(p, ps)

# The parallel per-page stage as a sequential pure fold (parallel and
# sequential are the same function's two evaluation strategies — spec §6).
def prep_all(pages: List<&2, Model.SourcePage>) -> Maybe<&2, List<&2, PagePrep>>:
  match pages:
    case Nil{}:
      pps_nil()
    case +h <> t:
      prep_cons(prep_page(h), prep_all(t))

# --- projections over the prepped pages -----------------------------------------

def prep_ids_go(pps: List<&2, PagePrep>) -> List<&2, String>:
  match pps:
    case Nil{}:
      Nil{}
    case +h <> t:
      match h:
        case PagePrep{+id, parent, title, body}:
          id <> prep_ids_go(t)

# The id set link resolution checks against: the pages themselves, in
# order.  This is deliberately the same list the emit stage walks — the
# correspondence is definitional, which is what makes link_integrity a
# theorem rather than an audit.
def prep_ids(+pps: List<&2, PagePrep>) -> List<&2, String>:
  prep_ids_go(pps)

def node_of(pp: PagePrep) -> G.RawNode:
  match pp:
    case PagePrep{+id, +parent, title, body}:
      G.RawNode{id, parent}

def nodes_go(pps: List<&2, PagePrep>) -> List<&2, G.RawNode>:
  match pps:
    case Nil{}:
      Nil{}
    case +h <> t:
      node_of(h) <> nodes_go(t)

def prep_nodes(+pps: List<&2, PagePrep>) -> List<&2, G.RawNode>:
  nodes_go(pps)

# --- stage 3: resolve links + render per page ---------------------------------

# The emitted links gate: link resolution errors veto the page.
def emit_gate(+id: String, +lids: List<&2, String>, +html: String, clean: Bool) -> Maybe<&2, Model.EmittedPage>:
  match clean:
    case False{}:
      emit_none()
    case True{}:
      emit_some(id, lids, html)

def emit_fin(+id: String, +html: String, r: L.LinkResolution) -> Maybe<&2, Model.EmittedPage>:
  match r:
    case L.LinkResolution{+lids, +errors}:
      emit_gate(id, lids, html, List.is_empty(&2, L.LinkError, errors))

# One page through the bendown engine: markdown parse, link-target
# extraction, §5 resolution, HTML render.  The emitted `links` field is
# exactly the membership-verified resolved ids.
def emit_one(+ids: List<&2, String>, pp: PagePrep) -> Maybe<&2, Model.EmittedPage>:
  match pp:
    case PagePrep{+id, parent, title, +body}:
      +doc = Markdown.parse_markdown(body)
      emit_fin(id, Html.render_document(doc),
        L.resolve_page_links(id, Eng.document_link_targets(doc), ids))

def emit_cons(m: Maybe<&2, Model.EmittedPage>, rest: Maybe<&2, List<&2, Model.EmittedPage>>) ->
  Maybe<&2, List<&2, Model.EmittedPage>>:
  match m:
    case None{}:
      eps_none()
    case Some{+p}:
      match rest:
        case None{}:
          eps_none()
        case Some{+ps}:
          eps_cons(p, ps)

def emit_all(+ids: List<&2, String>, pps: List<&2, PagePrep>) -> Maybe<&2, List<&2, Model.EmittedPage>>:
  match pps:
    case Nil{}:
      eps_nil()
    case +h <> t:
      emit_cons(emit_one(ids, h), emit_all(ids, t))

# --- the join and the pipeline ----------------------------------------------------

# The join: the validated graph must exist AND every page must have
# emitted.  Both gate the publication — validation is the sequential join
# phase; nothing reaches the output unvalidated.
def compile_gate(v: Maybe<&2, G.ValidatedGraph>, e: Maybe<&2, List<&2, Model.EmittedPage>>) ->
  Maybe<&2, Model.Publication>:
  match v:
    case None{}:
      pub_none()
    case Some{+g}:
      match e:
        case None{}:
          pub_none()
        case Some{+ps}:
          pub_of(ps)

def compile_stage(+pps: List<&2, PagePrep>) -> Maybe<&2, Model.Publication>:
  +ids = prep_ids(pps)
  compile_gate(G.validate(nodes_go(pps)), emit_all(ids, pps))

def compile_step(prepped: Maybe<&2, List<&2, PagePrep>>) -> Maybe<&2, Model.Publication>:
  match prepped:
    case None{}:
      pub_none()
    case Some{+pps}:
      compile_stage(pps)

# The pipeline.  config is the stable v0 parameter — there is no
# configuration surface yet.
def compile(config: Model.Config, pages: List<&2, Model.SourcePage>) -> Maybe<&2, Model.Publication>:
  compile_step(prep_all(pages))
