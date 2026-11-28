import Base
import ./harness.bend as H
import ../src/hostpath.bend as P

# Edge-case smoke tests for POSIX byte-path algebra.  Expected values are the
# node:path.posix semantics specified by Node's lib/path.js implementation;
# where the local Bun facade disagreed with that source for resolve of relative
# inputs, the Node source semantics are the oracle.  Inputs are converted to
# UTF-8 byte lists here only for test ergonomics: hostpath itself is opaque-byte
# algebra and never validates UTF-8.

def ifs(-A: Type, z: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match z:
    case True{}:
      yes(Unit{})
    case False{}:
      no(Unit{})

def utf8_cont(+x: U32) -> U32:
  U32.add(128, U32.and(x, 63))

def utf8_cp(+x: U32) -> List<&2, U32>:
  ifs(List<&2, U32>, U32.is_lt(x, 128),
    u => x <> Nil{},
    u => ifs(List<&2, U32>, U32.is_lt(x, 2048),
      v =>
        U32.add(192, U32.shrn(x, 6n)) <>
        utf8_cont(x) <> Nil{},
      v => ifs(List<&2, U32>, U32.is_lt(x, 65536),
        w =>
          U32.add(224, U32.shrn(x, 12n)) <>
          utf8_cont(U32.shrn(x, 6n)) <>
          utf8_cont(x) <> Nil{},
        w =>
          U32.add(240, U32.shrn(x, 18n)) <>
          utf8_cont(U32.shrn(x, 12n)) <>
          utf8_cont(U32.shrn(x, 6n)) <>
          utf8_cont(x) <> Nil{})))

def utf8_encode(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{+h, t}:
      P.hostpath_bytes_append(utf8_cp(Char.to_u32(h)), utf8_encode(t))

def p(+s: String) -> List<&2, U32>:
  utf8_encode(s)

def hex_digit(+x: U32) -> String:
  ifs(String, U32.is_le(x, 9),
    u => SCon{Char.from_u32(U32.add(x, 48)), SNil{}},
    u => SCon{Char.from_u32(U32.add(x, 87)), SNil{}})

def hex_byte(+x: U32) -> String:
  hex_digit(U32.div(x, 16)) ++ hex_digit(U32.mod(x, 16))

def show_bytes(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case +h <> t:
      hex_byte(h) ++ show_bytes(t)

def chkbts(+name: String, +got: List<&2, U32>, +want: List<&2, U32>) -> H.Check:
  H.chk(name, show_bytes(got), show_bytes(want))

def case_norm(+name: String, +s: String, +want: String) -> H.Check:
  chkbts("norm-" ++ name, P.hostpath_normalize(p(s)), p(want))

def case_join2(+name: String, +a: String, +b: String, +want: String) -> H.Check:
  chkbts("join-" ++ name, P.hostpath_join2(p(a), p(b)), p(want))

def case_join3(+name: String, +a: String, +b: String, +c: String, +want: String) -> H.Check:
  chkbts("join-" ++ name, P.hostpath_join(p(a) <> p(b) <> p(c) <> Nil{}), p(want))

def case_join0(+name: String, +want: String) -> H.Check:
  chkbts("join-" ++ name, P.hostpath_join(Nil{}), p(want))

def case_dir(+name: String, +s: String, +want: String) -> H.Check:
  chkbts("dir-" ++ name, P.hostpath_dirname(p(s)), p(want))

def case_base(+name: String, +s: String, +want: String) -> H.Check:
  chkbts("base-" ++ name, P.hostpath_basename(p(s)), p(want))

def cwd() -> List<&2, U32>:
  p("/private/tmp")

def ps1(+a: List<&2, U32>) -> List<&2, List<&2, U32>>:
  a <> Nil{}

def ps2(+a: List<&2, U32>, +b: List<&2, U32>) -> List<&2, List<&2, U32>>:
  a <> b <> Nil{}

def ps3(+a: List<&2, U32>, +b: List<&2, U32>, +c: List<&2, U32>) -> List<&2, List<&2, U32>>:
  a <> b <> c <> Nil{}

def case_resolve1(+name: String, +a: String, +want: String) -> H.Check:
  chkbts("resolve-" ++ name, P.hostpath_resolve(cwd(), ps1(p(a))), p(want))

def case_resolve2(+name: String, +a: String, +b: String, +want: String) -> H.Check:
  chkbts("resolve-" ++ name, P.hostpath_resolve(cwd(), ps2(p(a), p(b))), p(want))

def case_resolve3(+name: String, +a: String, +b: String, +c: String, +want: String) -> H.Check:
  chkbts("resolve-" ++ name, P.hostpath_resolve(cwd(), ps3(p(a), p(b), p(c))), p(want))

def case_resolve0(+name: String, +want: String) -> H.Check:
  chkbts("resolve-" ++ name, P.hostpath_resolve(cwd(), Nil{}), p(want))

def case_relabs(+name: String, +from: String, +to: String, +want: String) -> H.Check:
  chkbts("rel-" ++ name, P.hostpath_relative(cwd(), p(from), p(to)), p(want))

def case_strict(+name: String, +child: String, +parent: String, want: Bool) -> H.Check:
  H.chkb("strict-" ++ name, P.hostpath_is_strictly_inside_resolved(p(child), p(parent)), want)

def case_insideeq(+name: String, +child: String, +parent: String, want: Bool) -> H.Check:
  H.chkb("insideeq-" ++ name, P.hostpath_is_inside_or_equal_resolved(p(child), p(parent)), want)

def case_strict_cwd(+name: String, +child: String, +parent: String, want: Bool) -> H.Check:
  H.chkb("strictcwd-" ++ name, P.hostpath_is_strictly_inside(cwd(), p(child), p(parent)), want)

def checks() -> List<&2, H.Check>:
  # normalize: dot/empty removal, trailing-slash preservation, root clamping,
  # and look-alike dot segments.
  case_norm("empty", "", ".") <>
  case_norm("dot", ".", ".") <>
  case_norm("dotdot", "..", "..") <>
  case_norm("root", "/", "/") <>
  case_norm("double-root", "//", "/") <>
  case_norm("triple-root", "///", "/") <>
  case_norm("plain", "a", "a") <>
  case_norm("trailing", "a/", "a/") <>
  case_norm("trailing-many", "a//", "a/") <>
  case_norm("abs-trailing-many", "/a//", "/a/") <>
  case_norm("inner-dot", "a/./b", "a/b") <>
  case_norm("inner-empty", "a//b", "a/b") <>
  case_norm("lead-dot", "./a", "a") <>
  case_norm("dot-slash", "./", "./") <>
  case_norm("dotdot-slash", "../", "../") <>
  case_norm("dotdot-a", "../a", "../a") <>
  case_norm("pop-to-dot", "a/..", ".") <>
  case_norm("pop-to-dotslash", "a/../", "./") <>
  case_norm("abs-pop-root", "/a/..", "/") <>
  case_norm("abs-pop-rootslash", "/a/../", "/") <>
  case_norm("rel-two-pops", "a/../..", "..") <>
  case_norm("abs-clamp", "/a/../..", "/") <>
  case_norm("escape-then-reenter", "/../../a", "/a") <>
  case_norm("rel-escape-reenter", "a/../../b", "../b") <>
  case_norm("deep-pops", "/a/b/../../c", "/c") <>
  case_norm("lookalikes", "a/..../b", "a/..../b") <>
  case_norm("redundant-pop", "a//..//b", "b") <>
  case_norm("leading-redundant", "//a//b//", "/a/b/") <>
  case_norm("unicode-opaque", "/café/./😀", "/café/😀") <>

  # join: absolute right-hand sides concatenate rather than resetting.
  case_join0("noargs", ".") <>
  case_join2("absolute-rhs", "/a", "/b", "/a/b") <>
  case_join3("absolute-rhs-multi", "/a", "/b", "/c", "/a/b/c") <>
  case_join2("empty-rhs", "a", "", "a") <>
  case_join2("empty-lhs", "", "a", "a") <>
  case_join2("both-empty", "", "", ".") <>
  case_join2("left-trailing", "/a/", "b", "/a/b") <>
  case_join2("redundant", "/a//", "//b//", "/a/b/") <>
  case_join2("pop", "a", "..", ".") <>
  case_join2("escape-relative", "a", "../..", "..") <>
  case_join2("escape-absolute", "/a", "../..", "/") <>
  case_join2("escape-reenter", "/a", "/../../b", "/b") <>
  case_join2("absolute-pop-relative", "a", "/..", ".") <>
  case_join2("absolute-rhs-relative", "a", "/b", "a/b") <>
  case_join2("roots", "/", "/", "/") <>
  case_join2("right-trailing", "a", "b/", "a/b/") <>

  # resolve: right-to-left absolute reset, explicit cwd, clamped '..', and no
  # trailing slash in the result.  The '..../a' case is the genuine Node-source
  # behavior (/a), not the nonconformant Bun-facade result observed locally.
  case_resolve0("noargs", "/private/tmp") <>
  case_resolve1("empty", "", "/private/tmp") <>
  case_resolve1("dot", ".", "/private/tmp") <>
  case_resolve1("relative", "a", "/private/tmp/a") <>
  case_resolve1("relative-clamped", "../../../a", "/a") <>
  case_resolve2("empty-first", "", "a", "/private/tmp/a") <>
  case_resolve2("empty-last", "a", "", "/private/tmp/a") <>
  case_resolve2("abs-first", "/a", "b", "/a/b") <>
  case_resolve2("abs-reset", "/a", "/b", "/b") <>
  case_resolve3("abs-reset-mid", "/a", "/b", "c", "/b/c") <>
  case_resolve3("pop-first", "/a", "..", "b", "/b") <>
  case_resolve1("root", "/", "/") <>
  case_resolve1("double-root", "//", "/") <>
  case_resolve1("redundant", "//a//b//", "/a/b") <>
  case_resolve1("root-dotdot", "/..", "/") <>
  case_resolve1("trailing", "/a/", "/a") <>
  case_resolve1("pop", "/a/b/..", "/a") <>
  case_resolve2("abs-clamp", "/a", "../..", "/") <>
  case_resolve1("escape-reenter", "/../../b", "/b") <>
  case_resolve2("rhs-trailing", "/a", "b/", "/a/b") <>

  # dirname: intentionally not normalized.  These cover repeated separators,
  # trailing slashes, and Node's surprising leading-double-slash quirk.
  case_dir("empty", "", ".") <>
  case_dir("dot", ".", ".") <>
  case_dir("dotdot", "..", ".") <>
  case_dir("root", "/", "/") <>
  case_dir("double-root", "//", "/") <>
  case_dir("plain", "a", ".") <>
  case_dir("plain-trailing", "a/", ".") <>
  case_dir("plain-trailing2", "a//", ".") <>
  case_dir("abs-one", "/a", "/") <>
  case_dir("abs-one-trailing", "/a/", "/") <>
  case_dir("abs-two", "/a/b", "/a") <>
  case_dir("abs-two-trailing", "/a/b/", "/a") <>
  case_dir("rel-two", "a/b", "a") <>
  case_dir("rel-two-trailing", "a/b/", "a") <>
  case_dir("duplicate-inner", "a//b", "a/") <>
  case_dir("triple-inner", "a///b", "a//") <>
  case_dir("dot-leading", "./a", ".") <>
  case_dir("dotdot-leading", "../a", "..") <>
  case_dir("unreduced-dots", "/a/../b", "/a/..") <>
  case_dir("deep-trailing", "a/b/c//", "a/b") <>
  case_dir("lead2-one", "//a", "//") <>
  case_dir("lead3-one", "///a", "//") <>
  case_dir("lead4-one", "////a", "///") <>
  case_dir("lead2-two", "//a/b", "//a") <>
  case_dir("lead3-two", "///a/b", "///a") <>
  case_dir("lead2-innerdup", "//a//b", "//a/") <>

  # basename: trailing slashes ignored, interior redundant slashes irrelevant,
  # root/all-slash basename empty.
  case_base("empty", "", "") <>
  case_base("dot", ".", ".") <>
  case_base("dotdot", "..", "..") <>
  case_base("root", "/", "") <>
  case_base("double-root", "//", "") <>
  case_base("plain", "a", "a") <>
  case_base("plain-trailing", "a//", "a") <>
  case_base("multi-char", "ab", "ab") <>
  case_base("multi-char-deep", "/a/basename", "basename") <>
  case_base("abs-one", "/a", "a") <>
  case_base("abs-two", "/a/b", "b") <>
  case_base("abs-two-trailing", "/a/b//", "b") <>
  case_base("duplicate-inner", "a//b", "b") <>
  case_base("deep-trailing", "a/b/c//", "c") <>
  chkbts("base-invalid-byte-opaque", P.hostpath_basename(47 <> 255 <> Nil{}), 255 <> Nil{}) <>
  case_base("unicode", "/café/😀", "😀") <>

  # relative over absolute inputs.  Includes equality, parent/child in both
  # directions, root cases, redundant input spelling, dot-target resolution,
  # and the '/a' versus '/ab' prefix trap.
  case_relabs("same", "/a", "/a", "") <>
  case_relabs("child", "/a", "/a/b", "b") <>
  case_relabs("parent", "/a/b", "/a", "..") <>
  case_relabs("same-nested", "/a/b", "/a/b", "") <>
  case_relabs("prefix-forward", "/a", "/ab", "../ab") <>
  case_relabs("prefix-back", "/ab", "/a", "../a") <>
  case_relabs("root-to-child", "/", "/a", "a") <>
  case_relabs("child-to-root", "/a", "/", "..") <>
  case_relabs("deep-child", "/a/b", "/a/b/c/d", "c/d") <>
  case_relabs("cousins", "/a/b/c", "/a/d/e", "../../d/e") <>
  case_relabs("trailing", "/a/", "/a/b/", "b") <>
  case_relabs("redundant", "//a//", "/a/b//", "b") <>
  case_relabs("dots-resolved", "/x/y", "/x/y/z/../w", "w") <>
  case_relabs("relative-inputs", "a", "a/b", "b") <>
  case_relabs("empty-to-absolute", "", "/tmp/a", "../../tmp/a") <>
  case_relabs("absolute-to-empty", "/tmp/a", "", "../../private/tmp") <>
  case_relabs("dotdot-input", "..", "a", "tmp/a") <>

  # containment predicates over canonical paths, exactly the host's central
  # use.  Equality is inside-or-equal but not strictly inside; prefix-only
  # names do not count as containment.
  case_strict("child-in-parent", "/a/b", "/a", True{}) <>
  case_strict("same-not-strict", "/a/b", "/a/b", False{}) <>
  case_insideeq("same-insideeq", "/a/b", "/a/b", True{}) <>
  case_strict("prefix-trap", "/ab", "/a", False{}) <>
  case_insideeq("prefix-trap-eq", "/ab", "/a", False{}) <>
  case_strict("root-child", "/a", "/", True{}) <>
  case_strict("root-same", "/", "/", False{}) <>
  case_insideeq("root-same-eq", "/", "/", True{}) <>
  case_strict("outside", "/outside", "/a", False{}) <>
  case_strict("deep-inside", "/a/b/c/d", "/a/b", True{}) <>
  case_strict("parent-not-inside", "/a", "/a/b", False{}) <>
  case_strict_cwd("unresolved-redundant", "//a//b/", "/a", True{}) <>
  case_strict_cwd("unresolved-prefix", "/ab/../ab", "/a", False{}) <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
