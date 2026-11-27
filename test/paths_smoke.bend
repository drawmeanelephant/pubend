import Base
import ./harness.bend as H
import ../src/paths.bend as P

# Smoke tests for the lexical path algebra (docs/v0-spec.md §5.2): join,
# dot-segment normalization, root-escape detection, dirname, and the link
# convenience helpers.  Corner cases are the point: ".." past the root,
# redundant ".", duplicate slashes, deep nesting, and look-alike segments.

def show_result(r: P.PathResult) -> String:
  match r:
    case P.PathOk{+path}:
      H.q(path)
    case P.PathEscape{}:
      "ESC"

def case_norm(+name: String, +s: String, +want: String) -> H.Check:
  H.chk(name, show_result(P.path_normalize(s)), want)

def case_dir(+name: String, +id: String, +want: String) -> H.Check:
  H.chk(name, H.q(P.path_dirname(id)), want)

def case_join(+name: String, +dir: String, +t: String, +want: String) -> H.Check:
  H.chk(name, show_result(P.path_normalize(P.path_join(dir, t))), want)

def case_frag(+name: String, +s: String, +want: String) -> H.Check:
  H.chk(name, H.q(P.path_strip_fragment(s)), want)

def case_q(+name: String, +s: String, want: Bool) -> H.Check:
  H.chkb(name, P.path_has_query(s), want)

def case_md(+name: String, +s: String, want: Bool) -> H.Check:
  H.chkb(name, P.path_ends_md(s), want)

def case_stripsfx(+name: String, +s: String, +want: String) -> H.Check:
  H.chk(name, H.q(P.path_strip_md(s)), want)

def case_relhtml(+name: String, +source: String, +target: String, +fragment: String, +want: String) -> H.Check:
  H.chk(name, H.q(P.path_relative_html(source, target, fragment)), want)

def case_fragsuf(+name: String, +s: String, +want: String) -> H.Check:
  H.chk(name, H.q(P.path_fragment_suffix(s)), want)

def checks() -> List<&2, H.Check>:
  case_norm("plain", "a/b/c.md", "\"a/b/c.md\"") <>
  case_norm("deep", "a/b/c/d/e/f/g/h.md", "\"a/b/c/d/e/f/g/h.md\"") <>
  case_norm("dot", "a/./b/./c.md", "\"a/b/c.md\"") <>
  case_norm("dot-first", "./x.md", "\"x.md\"") <>
  case_norm("dot-only", ".", "\"\"") <>
  case_norm("dup-slashes", "a//b//c.md", "\"a/b/c.md\"") <>
  case_norm("lead-slash", "/a/b.md", "\"a/b.md\"") <>
  case_norm("trail-slash", "a/b/", "\"a/b\"") <>
  case_norm("many-slash", "///a///b///c.md", "\"a/b/c.md\"") <>
  case_norm("pop-one", "a/b/../c.md", "\"a/c.md\"") <>
  case_norm("pop-two", "a/b/../../c.md", "\"c.md\"") <>
  case_norm("pop-mixed", "a/./../b.md", "\"b.md\"") <>
  case_norm("pop-deep", "a/b/c/../d/../e.md", "\"a/b/e.md\"") <>
  case_norm("escape-1", "../x.md", "ESC") <>
  case_norm("escape-2", "a/../../x.md", "ESC") <>
  case_norm("escape-3", "a/b/../../../x.md", "ESC") <>
  case_norm("escape-mid", "a/../b/../../c.md", "ESC") <>
  case_norm("at-root", "a/../x.md", "\"x.md\"") <>
  case_norm("root-then-in", "a/b/../../c/d.md", "\"c/d.md\"") <>
  case_norm("ddx", "..x/y.md", "\"..x/y.md\"") <>
  case_norm("xdd", "x../y.md", "\"x../y.md\"") <>
  case_norm("dots", ".../y.md", "\".../y.md\"") <>
  case_norm("dots4", "a/..../b.md", "\"a/..../b.md\"") <>
  case_norm("empty", "", "\"\"") <>
  case_norm("slash-only", "/", "\"\"") <>
  case_dir("dir-root", "index", "\"\"") <>
  case_dir("dir-one", "a/b", "\"a\"") <>
  case_dir("dir-two", "a/b/c", "\"a/b\"") <>
  case_dir("dir-deep", "a/b/c/d.md", "\"a/b/c\"") <>
  case_join("join-plain", "guides", "x.md", "\"guides/x.md\"") <>
  case_join("join-up", "guides", "../index.md", "\"index.md\"") <>
  case_join("join-up2", "guides/deep", "../../x.md", "\"x.md\"") <>
  case_join("join-emptydir", "", "a.md", "\"a.md\"") <>
  case_join("join-escape", "guides", "../../x.md", "ESC") <>
  case_join("join-root-escape", "", "../x.md", "ESC") <>
  case_join("join-dot", "a/b", "./../c.md", "\"a/c.md\"") <>
  case_frag("frag-mid", "x.md#sec", "\"x.md\"") <>
  case_frag("frag-only", "#sec", "\"\"") <>
  case_frag("frag-none", "x.md", "\"x.md\"") <>
  case_frag("frag-two", "x.md#a#b", "\"x.md\"") <>
  case_q("query-yes", "x.md?a=1", True{}) <>
  case_q("query-no", "x.md", False{}) <>
  case_md("md-yes", "a/b.md", True{}) <>
  case_md("md-no", "a/b.mdx", False{}) <>
  case_md("md-dir", "a.md/b", False{}) <>
  case_stripsfx("strip", "a/b/c.md", "\"a/b/c\"") <>
  case_stripsfx("strip-root", "index.md", "\"index\"") <>
  case_relhtml("rel-root-to-root", "index", "a", "", "\"a.html\"") <>
  case_relhtml("rel-root-to-deep", "index", "deep/page", "#x", "\"deep/page.html#x\"") <>
  case_relhtml("rel-deep-to-root", "deep/page", "index", "", "\"../index.html\"") <>
  case_relhtml("rel-sibling", "deep/a", "deep/b", "", "\"b.html\"") <>
  case_relhtml("rel-cousin", "deep/a", "other/b", "#frag", "\"../other/b.html#frag\"") <>
  case_relhtml("rel-deeper-cousin", "deep/nested/a", "other/deep/b", "", "\"../../other/deep/b.html\"") <>
  case_relhtml("rel-file-dir-collision", "a/b", "a", "", "\"../a.html\"") <>
  case_relhtml("rel-self", "a", "a", "#self", "\"a.html#self\"") <>
  case_relhtml("rel-empty-target-root", "index", "", "", "\".html\"") <>
  case_relhtml("rel-empty-target-deep", "deep/page", "", "#x", "\"../.html#x\"") <>
  case_relhtml("rel-empty-self", "", "", "", "\".html\"") <>
  case_fragsuf("fragsuf-none", "x.md", "\"\"") <>
  case_fragsuf("fragsuf-one", "x.md#sec", "\"#sec\"") <>
  case_fragsuf("fragsuf-two", "x.md#a#b", "\"#a#b\"") <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
