import Base
import ./harness.bend as H
import ../src/model.bend as Model
import ../src/compile.bend as C

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

def case_pub(+name: String, pages: List<&2, Model.SourcePage>, +want: String) -> H.Check:
  H.chk(name, pub_state(C.compile(cfg(), pages)), want)

def case_law(+name: String, pages: List<&2, Model.SourcePage>, want: Bool) -> H.Check:
  H.chkb(name, law_holds(C.compile(cfg(), pages)), want)

def case_html(+name: String, pages: List<&2, Model.SourcePage>, +id: String, +want: String) -> H.Check:
  H.chk(name, html_of(id, C.compile(cfg(), pages)), want)

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
    "index", "<h1>Hello</h1>\n") <>
  case_html("html-link",
    page("index", fm0("[A](a.md)\n")) <>
    page("a", fm0("x\n")) <> Nil{},
    "index", "<p><a href=\"a.md\">A</a></p>\n") <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
