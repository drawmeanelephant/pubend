import Base
import ./harness.bend as H
import ../src/links.bend as L
import ../src/graph.bend as G

# Smoke tests for link classification (spec §5.1) and resolution (§5.2):
# external/passthrough boundaries, fragment/query handling, root escape,
# dangling targets, and per-page aggregation.

def class_name(c: L.LinkClass) -> String:
  match c:
    case L.LExternal{}: "ext"
    case L.LInternal{}: "int"
    case L.LPassthrough{}: "pass"

def case_class(+name: String, +t: String, +want: String) -> H.Check:
  H.chk(name, class_name(L.classify_link(t)), want)

# --- the page id set resolution runs against ------------------------------------

def ids() -> List<&2, String>:
  "index" <> "guides/a" <> "guides/b" <> "guides/deep/c" <> "top" <> Nil{}

def kind_name(k: L.LinkErrKind) -> String:
  match k:
    case L.LErrQuery{}: "query"
    case L.LErrEscape{}: "escape"
    case L.LErrDangling{}: "dangling"

def err_str(e: L.LinkError) -> String:
  match e:
    case L.LinkError{+source, +target, +kind}:
      String.append(kind_name(kind), String.append(":", target))

def outcome_str(o: L.LinkOutcome) -> String:
  match o:
    case L.LinkPass{}: "pass"
    case L.LinkOk{+id}: String.append("ok:", id)
    case L.LinkErr{+e}: err_str(e)

def case_res(+name: String, +src: String, +t: String, +want: String) -> H.Check:
  H.chk(name, outcome_str(L.resolve_one(src, t, ids())), want)

# --- per-page resolution --------------------------------------------------------

def idl(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}: ""
    case +h <> t: String.append(h, String.append(",", idl(t)))

def errl(xs: List<&2, L.LinkError>) -> String:
  match xs:
    case Nil{}: ""
    case +h <> t: String.append(err_str(h), String.append(",", errl(t)))

def res_str(r: L.LinkResolution) -> String:
  match r:
    case L.LinkResolution{+ids, +errors}:
      String.append(idl(ids), String.append("|", errl(errors)))

def case_page(+name: String, +src: String, ts: List<&2, String>, +want: String) -> H.Check:
  H.chk(name, res_str(L.resolve_page_links(src, ts, ids())), want)

def checks() -> List<&2, H.Check>:
  # --- classification ---
  case_class("cls-http", "http://a.com/x", "ext") <>
  case_class("cls-https-md", "https://a.com/x.md", "ext") <>
  case_class("cls-mailto", "mailto:a@b.c", "ext") <>
  case_class("cls-md", "x.md", "int") <>
  case_class("cls-md-dir", "a/b/c.md", "int") <>
  case_class("cls-md-frag", "a/b.md#sec", "int") <>
  case_class("cls-md-query", "a/b.md?x=1", "int") <>
  case_class("cls-anchor", "#sec", "pass") <>
  case_class("cls-abs-md", "/x/y.md", "pass") <>
  case_class("cls-txt", "a/b.txt", "pass") <>
  case_class("cls-mdx", "a/b.mdx", "pass") <>
  case_class("cls-empty", "", "pass") <>
  case_class("cls-mailto-md", "mailto:x.md", "ext") <>
  # --- resolution: internal happy paths ---
  case_res("res-sibling", "guides/a", "b.md", "ok:guides/b") <>
  case_res("res-sibling-frag", "guides/a", "b.md#sec", "ok:guides/b") <>
  case_res("res-up", "guides/a", "../index.md", "ok:index") <>
  case_res("res-up2", "guides/deep/c", "../../top.md", "ok:top") <>
  case_res("res-rootdir", "index", "top.md", "ok:top") <>
  case_res("res-dot", "guides/a", "./b.md", "ok:guides/b") <>
  case_res("res-dotslash", "guides/a", "./../top.md", "ok:top") <>
  case_res("res-dups", "guides/a", ".//b.md", "ok:guides/b") <>
  case_res("res-self", "guides/a", "a.md", "ok:guides/a") <>
  # --- resolution: errors ---
  case_res("res-query", "guides/a", "b.md?x=1", "query:b.md?x=1") <>
  case_res("res-query-frag", "guides/a", "b.md?x=1#s", "query:b.md?x=1#s") <>
  case_res("res-escape", "guides/a", "../../x.md", "escape:../../x.md") <>
  case_res("res-escape-root", "index", "../x.md", "escape:../x.md") <>
  case_res("res-dangling", "guides/a", "zzz.md", "dangling:zzz.md") <>
  case_res("res-dangling-up", "guides/a", "../zzz.md", "dangling:../zzz.md") <>
  case_res("res-dangling-dir", "guides/a", "deep/zzz.md", "dangling:deep/zzz.md") <>
  # --- resolution: passthroughs contribute nothing ---
  case_res("res-ext", "guides/a", "https://x.com/p.md", "pass") <>
  case_res("res-anchor", "guides/a", "#sec", "pass") <>
  case_res("res-abs", "guides/a", "/b.md", "pass") <>
  case_res("res-txt", "guides/a", "data.txt", "pass") <>
  # --- per-page aggregation ---
  case_page("page-clean", "guides/a",
    "b.md" <> "../index.md" <> "https://x.com" <> Nil{},
    "guides/b,index,|") <>
  case_page("page-errors", "guides/a",
    "b.md" <> "zzz.md" <> "../q.md" <> "c.md?y" <> Nil{},
    "guides/b,|dangling:zzz.md,dangling:../q.md,query:c.md?y,") <>
  case_page("page-none", "guides/a", Nil{}, "|") <>
  case_page("page-root", "top",
    "index.md" <> "guides/b.md" <> Nil{},
    "index,guides/b,|") <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
