import Base
import ./frontmatter.bend as Fm
import ./graph.bend as G
import ./paths.bend as P
import ../engine/src/ast.bend as Ast
import ../engine/src/render/html.bend as Html

# The fixed v0 publication layout (docs/v0-spec.md §7).
#
# The markdown fragment is entirely bendown-rendered.  This module owns only
# the publication shell around it: document title, parent link, child nav, and
# HTML escaping of layout-controlled text and attributes.  Every input to those
# decisions is read from validated graph nodes.

# --- textual content for the title fallback ------------------------------------

type InlineTextWork is Data:
  ItwInline{one: Ast.Inline}
  ItwInlines{xs: List<&2, Ast.Inline>}

def inline_text_work(+fuel: Nat, work: InlineTextWork) -> String:
  match fuel:
    case 0n:
      ""
    case 1n++f:
      match work:
        case ItwInlines{xs}:
          match xs:
            case Nil{}:
              ""
            case h <> t:
              inline_text_work(f, ItwInline{h}) ++ inline_text_work(f, ItwInlines{t})
        case ItwInline{one}:
          match one:
            case Ast.IText{text, span}:
              text
            case Ast.ICode{text, span}:
              text
            case Ast.IEmph{children, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.IStrong{children, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.IBold{children, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.IItalic{children, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.IDeleted{children, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.IInserted{children, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.ISuperscript{children, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.ISubscript{children, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.ISpan{children, attrs, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.ILink{children, href, title, span}:
              inline_text_work(f, ItwInlines{children})
            case Ast.IImage{src, alt, title, span}:
              alt
            case Ast.IAutolink{href, label, span}:
              label
            case Ast.IRawHtml{text, span}:
              ""
            case Ast.ISoftBreak{span}:
              " "
            case Ast.IHardBreak{span}:
              " "
            case Ast.IFootnoteRef{+number, span}:
              U32.show(number)

def inline_text_fuel() -> Nat:
  4294967295n

def inline_text(xs: List<&2, Ast.Inline>) -> String:
  inline_text_work(inline_text_fuel(), ItwInlines{xs})

# --- first level-one heading -----------------------------------------------------

type H1Work is Data:
  H1Blocks{xs: List<&2, Ast.Block>}
  H1Block{one: Ast.Block}
  H1Items{xs: List<&2, Ast.ListItem>}

def h1_some(+text: String) -> Maybe<&2, String>:
  Some{text}

def h1_none() -> Maybe<&2, String>:
  None{}

def h1_or(first: Maybe<&2, String>, rest: Maybe<&2, String>) -> Maybe<&2, String>:
  match first:
    case Some{+text}:
      h1_some(text)
    case None{}:
      rest

def h1_heading(children: List<&2, Ast.Inline>, is_one: Bool) -> Maybe<&2, String>:
  match is_one:
    case True{}:
      h1_some(inline_text(children))
    case False{}:
      h1_none()

def h1_work(+fuel: Nat, work: H1Work) -> Maybe<&2, String>:
  match fuel:
    case 0n:
      h1_none()
    case 1n++f:
      match work:
        case H1Blocks{xs}:
          match xs:
            case Nil{}:
              h1_none()
            case h <> t:
              h1_or(h1_work(f, H1Block{h}), h1_work(f, H1Blocks{t}))
        case H1Block{one}:
          match one:
            case Ast.BHeading{+level, children, attrs, span}:
              h1_heading(children, U32.is_eq(level, 1))
            case Ast.BBlockQuote{blocks, attrs, cite, span}:
              h1_work(f, H1Blocks{blocks})
            case Ast.BList{ordered, start, tight, items, span}:
              h1_work(f, H1Items{items})
            case u:
              h1_none()
        case H1Items{xs}:
          match xs:
            case Nil{}:
              h1_none()
            case Ast.ListItem{blocks, span} <> t:
              h1_or(h1_work(f, H1Blocks{blocks}), h1_work(f, H1Items{t}))

def h1_fuel() -> Nat:
  4294967295n

def first_h1_text(doc: Ast.Document) -> Maybe<&2, String>:
  match doc:
    case Ast.Document{blocks}:
      h1_work(h1_fuel(), H1Blocks{blocks})

# --- titles and navigation ---------------------------------------------------------

def title_or_id(+id: String, h1: Maybe<&2, String>) -> String:
  match h1:
    case Some{+text}:
      text
    case None{}:
      id

# frontmatter title -> first H1 text -> id.
def display_title(+id: String, title: Maybe<&2, String>, +doc: Ast.Document) -> String:
  match title:
    case Some{+text}:
      text
    case None{}:
      title_or_id(id, first_h1_text(doc))

def node_display_title(n: G.GraphNode) -> String:
  match n:
    case G.GraphNode{+id, parent, depth, +title, status, +document}:
      display_title(id, title, document)

def status_published(status: Fm.FmStatus) -> Bool:
  match status:
    case Fm.FmPublished{}:
      True{}
    case Fm.FmDraft{}:
      False{}

def parent_is(+id: String, parent: Maybe<&2, String>) -> Bool:
  match parent:
    case None{}:
      False{}
    case Some{+p}:
      String.eq(p, id)

def esc(+s: String) -> String:
  Html.escape_html(s)

def child_item(+source: String, +id: String, title: Maybe<&2, String>, +doc: Ast.Document) -> String:
  +href = P.path_relative_html(source, id, "")
  +text = display_title(id, title, doc)
  "<li><a href=\"" ++ esc(href) ++ "\">" ++ esc(text) ++ "</a></li>"

def child_nav_fin(+source: String, +id: String, title: Maybe<&2, String>, +doc: Ast.Document,
  +rest: String, include: Bool) -> String:
  match include:
    case True{}:
      child_item(source, id, title, doc) ++ rest
    case False{}:
      rest

# Scan the validated node list in emitted-page order, keeping only direct
# published children of source.  Draft children render as pages but are absent
# here, as required by §7; draft parents are likewise absent from parent links.
def child_nav_go(+source: String, xs: List<&2, G.GraphNode>) -> String:
  match xs:
    case Nil{}:
      ""
    case +h <> t:
      match h:
        case G.GraphNode{+id, +parent, depth, +title, +status, +document}:
          child_nav_fin(source, id, title, document, child_nav_go(source, t),
            Bool.and(parent_is(source, parent), status_published(status)))

def parent_link_published(+source: String, +pid: String, +text: String) -> String:
  +href = P.path_relative_html(source, pid, "")
  "<a href=\"" ++ esc(href) ++ "\">" ++ esc(text) ++ "</a>"

def parent_link_status(+source: String, +pid: String, +text: String, status: Fm.FmStatus) -> String:
  match status:
    case Fm.FmPublished{}:
      parent_link_published(source, pid, text)
    case Fm.FmDraft{}:
      ""

def parent_link_node(+source: String, +pid: String, n: G.GraphNode) -> String:
  match n:
    case G.GraphNode{+id, parent, depth, +title, +status, +document}:
      parent_link_status(source, pid, display_title(id, title, document), status)

def parent_link_found(+source: String, +pid: String, found: Maybe<&2, G.GraphNode>) -> String:
  match found:
    case None{}:
      ""
    case Some{+n}:
      parent_link_node(source, pid, n)

def parent_link_some(+source: String, +pid: String, +nodes: List<&2, G.GraphNode>) -> String:
  parent_link_found(source, pid, G.find_gnode(pid, nodes))

def parent_link(+source: String, +nodes: List<&2, G.GraphNode>, parent: Maybe<&2, String>) -> String:
  match parent:
    case None{}:
      ""
    case Some{+pid}:
      parent_link_some(source, pid, nodes)

# The fixed shell.  Head contains exactly the charset meta and title elements;
# body contains the nav followed by main around the already-rendered engine
# fragment.  Layout-controlled text and href attributes are escaped here;
# fragment raw HTML remains bendown-owned behavior.
def render_page(+nodes: List<&2, G.GraphNode>, +id: String, parent: Maybe<&2, String>,
  title: Maybe<&2, String>, +doc: Ast.Document, +fragment: String) -> String:
  +page_title = display_title(id, title, doc)
  "<!doctype html>\n<html lang=\"en\">\n" ++
  "<head><meta charset=\"utf-8\"><title>" ++ esc(page_title) ++ "</title></head>\n" ++
  "<body><nav class=\"pubend-nav\">" ++ parent_link(id, nodes, parent) ++
  "<ul class=\"pubend-children\">" ++ child_nav_go(id, nodes) ++ "</ul></nav>" ++
  "<main>" ++ fragment ++ "</main></body>\n</html>\n"
