import Base
import ./harness.bend as H
import ../src/model.bend as Model
import ../src/compile.bend as C
import ../src/frontmatter.bend as Fm
import ../src/graph.bend as G
import ../src/links.bend as L
import ../src/rewrite.bend as Rw
import ../engine/src/ast.bend as Ast
import ../engine/src/document_links.bend as DocumentLinks

# Smoke harness for the pure compile pipeline over constructed in-memory
# pages (Track A step 6 — the corpus is built concurrently, so this file
# is the permanent executable spec of the pipeline).  The law predicate
# Model.publication_links_resolve runs directly on emitted publications:
# every successful build's emitted link lists resolve, by construction.

def cfg() -> Model.Config:
  Model.Config{}

def page(+id: String, +body: String) -> Model.SourcePage:
  Model.SourcePage{id, body}

def fm0(+body: String) -> String:
  String.append("---\nstatus: published\n---\n", body)

def ls(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}: ""
    case +h <> t: String.append(h, String.append(";", ls(t)))

def ep_str(ep: Model.EmittedPage) -> String:
  match ep:
    case Model.EmittedPage{+id, +links, html}:
      String.append(id, String.append(":[", String.append(ls(links), "],")))

def pages_str(pages: List<&2, Model.EmittedPage>) -> String:
  match pages:
    case Nil{}: ""
    case +h <> t:
      String.append(ep_str(h), pages_str(t))

def pub_state(m: Maybe<&2, Model.Publication>) -> String:
  match m:
    case None{}:
      "INVALID"
    case Some{+p}:
      match p:
        case Model.Publication{+pages}:
          pages_str(pages)

def law_holds(m: Maybe<&2, Model.Publication>) -> Bool:
  match m:
    case None{}: False{}
    case Some{+p}: Model.publication_links_resolve(p)

def find_html(+id: String, pages: List<&2, Model.EmittedPage>) -> String:
  match pages:
    case Nil{}: "?"
    case +h <> t:
      match h:
        case Model.EmittedPage{+hid, links, +html}:
          Model.ifs(String, String.eq(id, hid),
            u => html,
            u => find_html(id, t))

def html_of(+id: String, m: Maybe<&2, Model.Publication>) -> String:
  match m:
    case None{}: "INVALID"
    case Some{+p}:
      match p:
        case Model.Publication{+pages}:
          find_html(id, pages)


def shell(+title: String, +nav: String, +main: String) -> String:
  "<!doctype html>\n<html lang=\"en\">\n<head><meta charset=\"utf-8\"><title>" ++ title ++
    "</title></head>\n<body><nav class=\"pubend-nav\">" ++ nav ++ "</nav><main>" ++ main ++
    "</main></body>\n</html>\n"

def shell0(+title: String, +main: String) -> String:
  shell(title, "<ul class=\"pubend-children\"></ul>", main)

def case_pub(+name: String, pages: List<&2, Model.SourcePage>, +want: String) -> H.Check:
  H.chk(name, pub_state(C.compile(cfg(), pages)), want)

def case_law(+name: String, pages: List<&2, Model.SourcePage>, want: Bool) -> H.Check:
  H.chkb(name, law_holds(C.compile(cfg(), pages)), want)

def case_html(+name: String, pages: List<&2, Model.SourcePage>, +id: String, +want: String) -> H.Check:
  H.chk(name, html_of(id, C.compile(cfg(), pages)), want)


def fm_kind_name(k: Fm.FmErrKind) -> String:
  match k:
    case Fm.FmMalformed{}: "malformed"
    case Fm.FmUnknownKey{}: "unknown-key"
    case Fm.FmDupKey{}: "dup-key"
    case Fm.FmBadStatus{}: "bad-status"
    case Fm.FmEmptyValue{}: "empty-value"

def graph_kind_name(k: G.DiagKind) -> String:
  match k:
    case G.DDupId{}: "dup-id"
    case G.DDupIdCase{}: "dup-id-case"
    case G.DDangling{}: "dangling"
    case G.DSelfParent{}: "self-parent"
    case G.DCycle{}: "cycle"

def link_kind_name(k: L.LinkErrKind) -> String:
  match k:
    case L.LErrQuery{}: "query"
    case L.LErrEscape{}: "escape"
    case L.LErrDangling{}: "dangling"
    case L.LErrMalformedPercent{}: "malformed-percent"
    case L.LErrInvalidPercentUtf8{}: "invalid-percent-utf8"

def dl_kind_name(k: DocumentLinks.DocumentLinkKind) -> String:
  match k:
    case DocumentLinks.DocumentLinkInline{}: "inline"
    case DocumentLinks.DocumentLinkAutolink{}: "autolink"
    case DocumentLinks.DocumentLinkImage{}: "image"

def maybe_str(m: Maybe<&2, String>) -> String:
  match m:
    case None{}: "-"
    case Some{+s}: s

def span_str(m: Maybe<&2, Ast.Span>) -> String:
  match m:
    case None{}: "nospan"
    case Some{+sp}:
      match sp:
        case Ast.Span{+start, +end}:
          U32.show(start) ++ "-" ++ U32.show(end)

def dl_kind_str(m: Maybe<&2, DocumentLinks.DocumentLinkKind>) -> String:
  match m:
    case None{}: "nokind"
    case Some{+k}: dl_kind_name(k)

def diag_str(d: C.CompileDiagnostic) -> String:
  match d:
    case C.CDFrontmatter{+page, +error}:
      match error:
        case Fm.FmError{+kind, line, col, detail}:
          "fm:" ++ fm_kind_name(kind) ++ ":" ++ page
    case C.CDGraph{+error}:
      match error:
        case G.Diag{+kind, +id, +other}:
          "graph:" ++ graph_kind_name(kind) ++ ":" ++ id ++ ":" ++ maybe_str(other)
    case C.CDLink{+error}:
      match error:
        case L.LinkError{+source, +target, +kind, +span, +link_kind}:
          "link:" ++ link_kind_name(kind) ++ ":" ++ source ++ ":" ++ target ++ ":" ++
            dl_kind_str(link_kind) ++ ":" ++ span_str(span)

def diags_str(xs: List<&2, C.CompileDiagnostic>) -> String:
  match xs:
    case Nil{}: ""
    case +h <> t: diag_str(h) ++ ";" ++ diags_str(t)

def report_state(r: C.CompileResult) -> String:
  match r:
    case C.CompileOk{publication}:
      "OK"
    case C.CompileErr{+diagnostics}:
      "ERR:" ++ diags_str(diagnostics)

def case_report(+name: String, pages: List<&2, Model.SourcePage>, +want: String) -> H.Check:
  H.chk(name, report_state(C.compile_report(cfg(), pages)), want)


def rw_span() -> Ast.Span:
  Ast.span_empty()

def rw_no_text() -> Maybe<&2, String>:
  None{}

def rw_no_attrs() -> List<&2, Ast.Attr>:
  Nil{}

def rw_text(+text: String) -> Ast.Inline:
  Ast.IText{text, rw_span()}

def rw_link(+label: String, +href: String) -> Ast.Inline:
  Ast.ILink{[rw_text(label)], href, rw_no_text(), rw_span()}

def rw_par(xs: List<&2, Ast.Inline>) -> Ast.Block:
  Ast.BParagraph{xs, rw_no_attrs(), rw_span()}

def rw_cell(x: Ast.Inline) -> Ast.TableCell:
  Ast.TableCell{False{}, Ast.AlignNone{}, 1, 1, [x], rw_no_attrs(), rw_span()}

# A hand-built typed AST covering inline containers, link children, images,
# autolinks, quote/list/table recursion, and a raw-HTML leaf.  The autolink is
# intentionally internal even though markdown autolink syntax normally accepts
# only scheme-like destinations: rewrite_one is target/classification driven,
# not syntax driven.
def rw_doc() -> Ast.Document:
  Ast.Document{[
    rw_par([
      rw_link("A", "a.md"),
      Ast.IEmph{[rw_link("B", "b.md#frag")], rw_span()},
      Ast.IImage{"img.md", "alt", rw_no_text(), rw_span()},
      Ast.IAutolink{"auto.md", "auto label", rw_span()},
      Ast.IRawHtml{"<b>raw</b>", rw_span()}
    ]),
    Ast.BBlockQuote{[rw_par([rw_link("Up", "../up.md")])], rw_no_attrs(), rw_no_text(), rw_span()},
    Ast.BList{False{}, 1, True{}, [
      Ast.ListItem{[rw_par([rw_link("List", "list.md")])], rw_span()}
    ], rw_span()},
    Ast.BTable{[Ast.AlignNone{}], [
      Ast.TableRow{[rw_cell(rw_link("Table", "table.md"))], rw_no_attrs(), rw_span()}
    ], rw_span()}
  ]}

def rw_ids() -> List<&2, String>:
  "deep/a" <> "deep/b" <> "deep/img" <> "deep/auto" <> "up" <> "deep/list" <> "deep/table" <> Nil{}

def rewritten_targets() -> String:
  ls(DocumentLinks.document_link_targets(Rw.rewrite_document("deep/root", rw_ids(), rw_doc())))

def checks() -> List<&2, H.Check>:
  # --- the whole pipeline, end to end ---
  case_pub("empty", Nil{}, "") <>
  case_pub("one",
    page("index", fm0("# Home\n")) <> Nil{},
    "index:[],") <>
  case_pub("two-linked",
    page("index", fm0("[Go](a.md)\n")) <>
    page("a", fm0("[Back](index.md)\n")) <> Nil{},
    "index:[a;],a:[index;],") <>
  case_pub("three-tree",
    page("index", fm0("[A](a.md) [B](b.md)\n")) <>
    page("a", fm0("[Home](index.md) [deep](deep/c.md)\n")) <>
    page("b", fm0("[Home](index.md)\n")) <>
    page("deep/c", fm0("[Up](../a.md)\n")) <> Nil{},
    "index:[a;b;],a:[index;deep/c;],b:[index;],deep/c:[a;],") <>
  case_pub("parents",
    page("index", "---\ntitle: Home\nstatus: published\n---\nRoot\n") <>
    page("guide", "---\ntitle: G\nparent: index\nstatus: published\n---\n[G](sub.md)\n") <>
    page("sub", "---\nparent: guide\nstatus: draft\n---\n") <> Nil{},
    "index:[],guide:[sub;],sub:[],") <>
  case_pub("no-frontmatter",
    page("index", "# Plain\n[Self](index.md)\n") <> Nil{},
    "index:[index;],") <>
  case_pub("ext-and-anchor",
    page("index", fm0("[X](https://x.com/p) [A](#top) [B](b.md)\n")) <>
    page("b", fm0("text\n")) <> Nil{},
    "index:[b;],b:[],") <>
  case_pub("fragment-ok",
    page("index", fm0("[A](a.md#sec)\n")) <>
    page("a", fm0("x\n")) <> Nil{},
    "index:[a;],a:[],") <>
  case_pub("dup-targets",
    page("index", fm0("[A](a.md) [A2](a.md)\n")) <>
    page("a", fm0("x\n")) <> Nil{},
    "index:[a;a;],a:[],") <>
  # --- the law predicate, executed on real publications ---
  case_law("law-two",
    page("index", fm0("[Go](a.md)\n")) <>
    page("a", fm0("[Back](index.md)\n")) <> Nil{}, True{}) <>
  case_law("law-tree",
    page("index", fm0("[A](a.md) [B](b.md)\n")) <>
    page("a", fm0("[Home](index.md) [deep](deep/c.md)\n")) <>
    page("b", fm0("[Home](index.md)\n")) <>
    page("deep/c", fm0("[Up](../a.md)\n")) <> Nil{}, True{}) <>
  case_law("law-mixed",
    page("index", fm0("[X](https://x.com) [A](#t) [B](b.md#s)\n")) <>
    page("b", fm0("[H](index.md)\n")) <> Nil{}, True{}) <>
  # --- link errors veto the build ---
  case_pub("dangling-link",
    page("index", fm0("[Gone](zzz.md)\n")) <> Nil{},
    "INVALID") <>
  case_pub("query-link",
    page("index", fm0("[Q](x.md?y=1)\n")) <>
    page("x", fm0("x\n")) <> Nil{},
    "INVALID") <>
  case_pub("escape-link",
    page("index", fm0("[E](../x.md)\n")) <> Nil{},
    "INVALID") <>
  case_pub("mixed-one-bad",
    page("index", fm0("[A](a.md) [Bad](zzz.md)\n")) <>
    page("a", fm0("x\n")) <> Nil{},
    "INVALID") <>
  # --- graph errors veto the build ---
  case_pub("dangling-parent",
    page("index", "---\nparent: zzz\nstatus: published\n---\n") <> Nil{},
    "INVALID") <>
  case_pub("cycle",
    page("a", "---\nparent: b\nstatus: published\n---\n") <>
    page("b", "---\nparent: a\nstatus: published\n---\n") <> Nil{},
    "INVALID") <>
  case_pub("self-parent",
    page("a", "---\nparent: a\nstatus: published\n---\n") <> Nil{},
    "INVALID") <>
  case_pub("dup-id",
    page("a", fm0("one\n")) <>
    page("a", fm0("two\n")) <> Nil{},
    "INVALID") <>
  # --- frontmatter errors veto the build ---
  case_pub("fm-unknown-key",
    page("index", "---\nlayout: x\nstatus: published\n---\n") <> Nil{},
    "INVALID") <>
  case_pub("fm-dup-key",
    page("index", "---\ntitle: a\ntitle: b\n---\n") <> Nil{},
    "INVALID") <>
  case_pub("fm-bad-status",
    page("index", "---\nstatus: weird\n---\n") <> Nil{},
    "INVALID") <>
  # --- html actually renders through the engine ---
  case_html("html-heading",
    page("index", fm0("# Hello\n")) <> Nil{},
    "index", shell0("Hello", "<h1>Hello</h1>\n")) <>
  case_html("html-link",
    page("index", fm0("[A](a.md)\n")) <>
    page("a", fm0("x\n")) <> Nil{},
    "index", shell0("index", "<p><a href=\"a.html\">A</a></p>\n")) <>
  case_html("html-nested-rewrites",
    page("index", fm0("home\n")) <>
    page("deep/a", fm0("[Home](../index.md) [B](b.md#sec)\n")) <>
    page("deep/b", fm0("b\n")) <> Nil{},
    "deep/a", shell0("deep/a", "<p><a href=\"../index.html\">Home</a> <a href=\"b.html#sec\">B</a></p>\n")) <>
  case_html("html-external-anchor-passthrough",
    page("index", fm0("[X](https://x.com/p.md) [A](#top) [F](file.txt) [Abs](/x.md)\n")) <> Nil{},
    "index", shell0("index", "<p><a href=\"https://x.com/p.md\">X</a> <a href=\"#top\">A</a> <a href=\"file.txt\">F</a> <a href=\"/x.md\">Abs</a></p>\n")) <>
  case_html("html-image-rewrite",
    page("index", fm0("![alt](img.md)\n")) <>
    page("img", fm0("img\n")) <> Nil{},
    "index", shell0("index", "<p><img src=\"img.html\" alt=\"alt\" /></p>\n")) <>
  case_html("html-duplicate-targets",
    page("index", fm0("[A](a.md) [A2](a.md)\n")) <>
    page("a", fm0("x\n")) <> Nil{},
    "index", shell0("index", "<p><a href=\"a.html\">A</a> <a href=\"a.html\">A2</a></p>\n")) <>
  case_html("html-raw-html-untouched",
    page("index", fm0("<span class=\"x\">raw</span>\n")) <> Nil{},
    "index", shell0("index", "<p><span class=\"x\">raw</span></p>\n")) <>
  case_html("html-encoded-space-target",
    page("index", fm0("[S](sp%20ace.md)\n")) <>
    page("sp ace", fm0("space\n")) <> Nil{},
    "index", shell0("index", "<p><a href=\"sp ace.html\">S</a></p>\n")) <>
  case_html("html-empty-id-target",
    page("", fm0("[self](.md)\n")) <>
    page("index", fm0("[empty](.md)\n")) <> Nil{},
    "index", shell0("index", "<p><a href=\".html\">empty</a></p>\n")) <>
  case_html("nav-children-draft-excluded",
    page("index", "---\ntitle: Root Title\nstatus: published\n---\nroot\n") <>
    page("draft", "---\ntitle: Draft Title\nparent: index\nstatus: draft\n---\ndraft\n") <>
    page("pub", "---\ntitle: Pub Title\nparent: index\nstatus: published\n---\npub\n") <> Nil{},
    "index", shell("Root Title", "<ul class=\"pubend-children\"><li><a href=\"pub.html\">Pub Title</a></li></ul>", "<p>root</p>\n")) <>
  case_html("nav-parent-link",
    page("index", "---\ntitle: Root Title\nstatus: published\n---\nroot\n") <>
    page("pub", "---\ntitle: Pub Title\nparent: index\nstatus: published\n---\npub\n") <> Nil{},
    "pub", shell("Pub Title", "<a href=\"index.html\">Root Title</a><ul class=\"pubend-children\"></ul>", "<p>pub</p>\n")) <>
  case_html("nav-draft-parent-excluded",
    page("draft", "---\ntitle: Draft Parent\nstatus: draft\n---\ndraft\n") <>
    page("pub", "---\ntitle: Pub Title\nparent: draft\nstatus: published\n---\npub\n") <> Nil{},
    "pub", shell("Pub Title", "<ul class=\"pubend-children\"></ul>", "<p>pub</p>\n")) <>
  case_html("layout-escapes-title",
    page("index", "---\ntitle: A&B <Q>\nstatus: published\n---\nbody\n") <> Nil{},
    "index", shell0("A&amp;B &lt;Q&gt;", "<p>body</p>\n")) <>
  H.chk("rewrite-typed-recursion", rewritten_targets(), "a.html;b.html#frag;img.html;auto.html;../up.html;list.html;table.html;") <>
  case_report("report-ok",
    page("index", fm0("ok\n")) <> Nil{},
    "OK") <>
  case_report("report-fm-aggregate",
    page("a", "---\nfoo: x\n---\nbody\n") <>
    page("b", "---\nbar: y\n---\nbody\n") <> Nil{},
    "ERR:fm:unknown-key:a;fm:unknown-key:b;") <>
  case_report("report-graph-aggregate",
    page("a", "---\nparent: missing1\nstatus: published\n---\na\n") <>
    page("b", "---\nparent: missing2\nstatus: published\n---\nb\n") <> Nil{},
    "ERR:graph:dangling:a:missing1;graph:dangling:b:missing2;") <>
  case_report("report-link-span-kind",
    page("index", fm0("[Bad](missing.md)\n")) <> Nil{},
    "ERR:link:dangling:index:missing.md:inline:0-17;") <>
  case_report("report-image-span-kind",
    page("index", fm0("![Alt](missing.md)\n")) <> Nil{},
    "ERR:link:dangling:index:missing.md:image:0-18;") <>
  case_report("report-malformed-percent",
    page("index", fm0("[Bad](bad%.md)\n")) <> Nil{},
    "ERR:link:malformed-percent:index:bad%.md:inline:0-14;") <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
