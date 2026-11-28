import Base
import ./model.bend as Model
import ./frontmatter.bend as Fm
import ./paths.bend as P
import ./graph.bend as G
import ./links.bend as L
import ./rewrite.bend as Rw
import ./layout.bend as Layout
import ../engine/src/ast.bend as Ast
import ../engine/src/parser/markdown.bend as Markdown
import ../engine/src/render/html.bend as Html
import ../engine/src/document_links.bend as DocumentLinks

# The pure compile pipeline (docs/v0-spec.md §6).  IO stays outside this
# module.  Frontmatter and markdown are parsed per page before validation;
# validation then carries the parsed artifacts inside ValidatedGraph, and all
# link resolution, target rewriting, layout, and emission consume only that
# validated graph (or fields extracted from it).  The pre-validation batch is
# never used as an emission input after the join.

# --- structured diagnostics and results --------------------------------------

type CompileDiagnostic is Data:
  CDFrontmatter{page: String, error: Fm.FmError}
  CDGraph{error: G.Diag}
  CDLink{error: L.LinkError}

type CompileResult is Data:
  CompileOk{publication: Model.Publication}
  CompileErr{diagnostics: List<&2, CompileDiagnostic>}

# --- small factories ---------------------------------------------------------

def ms_none() -> Maybe<&2, String>:
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

def cd_fm_one(+page: String, e: Fm.FmError) -> CompileDiagnostic:
  CDFrontmatter{page, e}

def cd_graph_one(e: G.Diag) -> CompileDiagnostic:
  CDGraph{e}

def cd_link_one(e: L.LinkError) -> CompileDiagnostic:
  CDLink{e}

def compile_ok(+publication: Model.Publication) -> CompileResult:
  CompileOk{publication}

def compile_err(+diagnostics: List<&2, CompileDiagnostic>) -> CompileResult:
  CompileErr{diagnostics}

# --- stage 1: frontmatter + markdown parse per page -----------------------------

type PrepOne is Data:
  PrepOne{node: G.RawNode, errors: List<&2, CompileDiagnostic>}

type PrepBatch is Data:
  PrepBatch{nodes: List<&2, G.RawNode>, errors: List<&2, CompileDiagnostic>}

def prep_one(+node: G.RawNode, +errors: List<&2, CompileDiagnostic>) -> PrepOne:
  PrepOne{node, errors}

def prep_batch(+nodes: List<&2, G.RawNode>, +errors: List<&2, CompileDiagnostic>) -> PrepBatch:
  PrepBatch{nodes, errors}

def cd_fms_go(+page: String, xs: List<&2, Fm.FmError>) -> List<&2, CompileDiagnostic>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      cd_fm_one(page, h) <> cd_fms_go(page, t)

# Even a page with frontmatter errors receives a best-effort raw node so the
# batch shape stays total.  compile_report stops before graph validation when
# the error half is non-empty, so those defaults never become publication
# semantics; they only keep aggregation and the proof-facing prep shape simple.
def prep_node_meta(+id: String, +body: String, m: Maybe<&2, Fm.FmMeta>) -> G.RawNode:
  match m:
    case None{}:
      G.g_raw(id, ms_none(), ms_none(), Fm.FmPublished{}, Markdown.parse_markdown(body))
    case Some{+fm}:
      match fm:
        case Fm.FmMeta{+title, +parent, +status}:
          G.g_raw(id, parent, title, status, Markdown.parse_markdown(body))

def prep_page_fin(+id: String, r: Fm.FmResult) -> PrepOne:
  match r:
    case Fm.FmResult{+meta, +body, +errors}:
      prep_one(prep_node_meta(id, body, meta), cd_fms_go(id, errors))

def prep_page_one(p: Model.SourcePage) -> PrepOne:
  match p:
    case Model.SourcePage{+id, +body}:
      prep_page_fin(id, Fm.parse_frontmatter(body))

def prep_batch_cons(one: PrepOne, rest: PrepBatch) -> PrepBatch:
  match one:
    case PrepOne{+node, +errors}:
      match rest:
        case PrepBatch{+nodes, +errors2}:
          prep_batch(node <> nodes,
            List.append(&2, CompileDiagnostic, errors, errors2))

def prep_batch_all(pages: List<&2, Model.SourcePage>) -> PrepBatch:
  match pages:
    case Nil{}:
      prep_batch(Nil{}, Nil{})
    case +h <> t:
      prep_batch_cons(prep_page_one(h), prep_batch_all(t))

def prep_all_gate(+nodes: List<&2, G.RawNode>, errors: List<&2, CompileDiagnostic>, clean: Bool) ->
  Maybe<&2, List<&2, G.RawNode>>:
  match clean:
    case False{}:
      None{}
    case True{}:
      Some{nodes}

# The proof-facing prep endpoint: all per-page parses succeeded, or no batch.
def prep_all_batch(batch: PrepBatch) -> Maybe<&2, List<&2, G.RawNode>>:
  match batch:
    case PrepBatch{+nodes, +errors}:
      prep_all_gate(nodes, errors, List.is_empty(&2, CompileDiagnostic, errors))

def prep_all(pages: List<&2, Model.SourcePage>) -> Maybe<&2, List<&2, G.RawNode>>:
  prep_all_batch(prep_batch_all(pages))

# --- stage 3: resolve links, rewrite targets, render, and lay out --------------

# One total HTML-rendering helper keeps the proof surface small: the exact
# rewrite/render/layout composition is named once rather than repeated through
# emission lemmas.
def render_node_html(+all: List<&2, G.GraphNode>, +id: String,
  parent: Maybe<&2, String>, title: Maybe<&2, String>, +document: Ast.Document) -> String:
  +ids = G.graph_ids_go(all)
  Layout.render_page(all, id, parent, title, document,
    Html.render_document(Rw.rewrite_document(id, ids, document)))

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

# One validated graph node through resolution, typed AST rewriting, bendown
# rendering, and the v0 layout.  The node being emitted and the graph context
# both come from ValidatedGraph-extracted data.
def emit_one(+all: List<&2, G.GraphNode>, n: G.GraphNode) ->
  Maybe<&2, Model.EmittedPage>:
  match n:
    case G.GraphNode{+id, +parent, depth, +title, status, +document}:
      +ids = G.graph_ids_go(all)
      emit_fin(id, render_node_html(all, id, parent, title, document),
        L.resolve_page_links(id, DocumentLinks.document_link_targets(document), ids))

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

def emit_all(+all: List<&2, G.GraphNode>, xs: List<&2, G.GraphNode>) ->
  Maybe<&2, List<&2, Model.EmittedPage>>:
  match xs:
    case Nil{}:
      eps_nil()
    case +h <> t:
      emit_cons(emit_one(all, h), emit_all(all, t))

# Emission starts only after validation.  Node order is the validated input
# order, which is also emitted-page order; nothing sorts or reorders pages.
def emit_graph(g: G.ValidatedGraph) -> Maybe<&2, List<&2, Model.EmittedPage>>:
  match g:
    case G.ValidatedGraph{+nodes}:
      emit_all(nodes, nodes)

def emit_validated(v: Maybe<&2, G.ValidatedGraph>) -> Maybe<&2, List<&2, Model.EmittedPage>>:
  match v:
    case None{}:
      eps_none()
    case Some{+g}:
      emit_graph(g)

# --- the join and the proof-facing pipeline --------------------------------------

# The join: the validated graph must exist AND every page must have emitted.
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

def compile_stage(+nodes: List<&2, G.RawNode>) -> Maybe<&2, Model.Publication>:
  +v = G.validate(nodes)
  compile_gate(v, emit_validated(v))

def compile_step(prepped: Maybe<&2, List<&2, G.RawNode>>) -> Maybe<&2, Model.Publication>:
  match prepped:
    case None{}:
      pub_none()
    case Some{+nodes}:
      compile_stage(nodes)

# The pipeline LAWS.bend quantifies over.  config is the stable v0 parameter —
# there is no configuration surface yet.
def compile(config: Model.Config, pages: List<&2, Model.SourcePage>) -> Maybe<&2, Model.Publication>:
  compile_step(prep_all(pages))

# --- detailed compile_report API --------------------------------------------------

def cd_graphs_go(xs: List<&2, G.Diag>) -> List<&2, CompileDiagnostic>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      cd_graph_one(h) <> cd_graphs_go(t)

def cd_links_go(xs: List<&2, L.LinkError>) -> List<&2, CompileDiagnostic>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      cd_link_one(h) <> cd_links_go(t)

def link_diags_node(+ids: List<&2, String>, n: G.GraphNode) -> List<&2, CompileDiagnostic>:
  match n:
    case G.GraphNode{+id, parent, depth, title, status, +document}:
      cd_links_go(L.resolution_errors(
        L.resolve_page_document_links(id, DocumentLinks.document_links(document), ids)))

def link_diags_go(+ids: List<&2, String>, xs: List<&2, G.GraphNode>) -> List<&2, CompileDiagnostic>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      List.append(&2, CompileDiagnostic, link_diags_node(ids, h), link_diags_go(ids, t))

# Detailed link diagnostics are extracted from the validated graph and use
# bendown's DocumentLink values, so errors carry the engine-normalized target
# plus span/kind provenance where the engine exposes it.
def link_diagnostics(g: G.ValidatedGraph) -> List<&2, CompileDiagnostic>:
  match g:
    case G.ValidatedGraph{+nodes}:
      link_diags_go(G.graph_ids_go(nodes), nodes)

def report_emit_pages(+diagnostics: List<&2, CompileDiagnostic>,
  e: Maybe<&2, List<&2, Model.EmittedPage>>) -> CompileResult:
  match e:
    case None{}:
      compile_err(diagnostics)
    case Some{+ps}:
      compile_ok(Model.Publication{ps})

def report_emit_gate(+diagnostics: List<&2, CompileDiagnostic>,
  e: Maybe<&2, List<&2, Model.EmittedPage>>, clean: Bool) -> CompileResult:
  match clean:
    case False{}:
      compile_err(diagnostics)
    case True{}:
      report_emit_pages(diagnostics, e)

def report_valid(+g: G.ValidatedGraph) -> CompileResult:
  +ds = link_diagnostics(g)
  report_emit_gate(ds, emit_graph(g), List.is_empty(&2, CompileDiagnostic, ds))

def report_validation(v: G.Validation) -> CompileResult:
  match v:
    case G.Valid{+g}:
      report_valid(g)
    case G.Invalid{+errors}:
      compile_err(cd_graphs_go(errors))

def report_prep_gate(+nodes: List<&2, G.RawNode>, +diagnostics: List<&2, CompileDiagnostic>,
  clean: Bool) -> CompileResult:
  match clean:
    case False{}:
      compile_err(diagnostics)
    case True{}:
      report_validation(G.validate_full(nodes))

# Detailed compilation result.  Diagnostics aggregate every frontmatter error
# across the batch; when frontmatter is clean, every graph diagnostic; and when
# the graph validates, every link diagnostic in emitted-page/target order.  A
# later stage is not interpreted when an earlier stage failed because the v0
# pipeline deliberately has no validated graph in that world.
def report_prep_batch(batch: PrepBatch) -> CompileResult:
  match batch:
    case PrepBatch{+nodes, +errors}:
      report_prep_gate(nodes, errors, List.is_empty(&2, CompileDiagnostic, errors))

def compile_report(config: Model.Config, pages: List<&2, Model.SourcePage>) -> CompileResult:
  report_prep_batch(prep_batch_all(pages))
