import Base

# Path algebra — lexical join and dot-segment normalization of
# docs/v0-spec.md §5.2.  Pure, total, no filesystem: everything here is
# string surgery on paths relative to the content root, written with
# forward slashes.  The correctness core of link resolution lives here, so
# the corner cases matter: ".." past the root, redundant "." segments,
# duplicate slashes, deep nesting, and segment names that merely look like
# dot segments ("..x", "x..", "...").

def ifs(-A: Type, z: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match z:
    case True{}:
      yes(Unit{})
    case False{}:
      no(Unit{})

# --- segment algebra ------------------------------------------------------

# One path segment as the normalizer sees it.  "" (from duplicate or
# leading/trailing slashes) and "." both skip; ".." pops one segment or
# records a root escape; everything else is a name — including names that
# only resemble dot segments ("..x", "x..", "...").
type PathSeg is Data:
  PsSkip{}
  PsPop{}
  PsName{name: String}

def path_seg_name(+seg: String) -> PathSeg:
  PsName{seg}

def path_seg_of(+seg: String) -> PathSeg:
  ifs(PathSeg, String.is_empty(seg),
    u => PsSkip{},
    u => ifs(PathSeg, String.eq(seg, "."),
      v => PsSkip{},
      v => ifs(PathSeg, String.eq(seg, ".."),
        w => PsPop{},
        w => path_seg_name(seg))))

# The stack is the reversed output path: its head is the deepest-pushed
# (last) segment.  ".." may only ever sit at the bottom of the stack — it
# is pushed only onto an empty stack or onto another "..", so any ".." in
# the final stack is a contiguous leading run of escapes in the result.
def path_pop.go(+h: String, t: List<&2, String>, under: Bool) -> List<&2, String>:
  match under:
    case True{}:
      ".." <> h <> t
    case False{}:
      t

def path_apply(s: PathSeg, stack: List<&2, String>) -> List<&2, String>:
  match s stack:
    case PsSkip{} _:
      stack
    case PsName{+name} _:
      name <> stack
    case PsPop{} Nil{}:
      ".." <> Nil{}
    case PsPop{} +h <> t:
      path_pop.go(h, t, String.eq(h, ".."))

def path_norm_go(segs: List<&2, String>, stack: List<&2, String>) -> List<&2, String>:
  match segs:
    case Nil{}:
      stack
    case +h <> t:
      path_norm_go(t, path_apply(path_seg_of(h), stack))

# A ".." survives in the stack iff the path escapes the root (they can only
# be the bottom contiguous prefix, but checking membership is simpler and
# equivalent here).
def path_escaped(stack: List<&2, String>) -> Bool:
  match stack:
    case Nil{}:
      False{}
    case +h <> t:
      ifs(Bool, String.eq(h, ".."),
        u => True{},
        u => path_escaped(t))

# The result of lexical normalization: the normalized relative path, or an
# escape marker when ".." climbs past the content root.  Escaping is a
# content error in the spec, so the distinction is a value, not a crash.
type PathResult is Data:
  PathOk{path: String}
  PathEscape{}

def path_ok(+path: String) -> PathResult:
  PathOk{path}

def path_result_fin(stack: List<&2, String>, escaped: Bool) -> PathResult:
  match escaped:
    case True{}:
      PathEscape{}
    case False{}:
      path_ok(String.join(List.reverse(&2, String, stack), "/"))

# Lexically normalize a slash-joined relative path: "." and empty segments
# drop, ".." pops a name or records a root escape.
def path_normalize(+s: String) -> PathResult:
  +stack = path_norm_go(String.split(s, '/'), [])
  path_result_fin(stack, path_escaped(stack))

# --- joining ---------------------------------------------------------------

# Join a target written in page `from`'s directory against that directory.
# The raw concat is enough: a following normalize already treats the join
# slash and an empty dir correctly ("guides" + "x.md" -> "guides/x.md";
# "" + "x.md" -> "x.md").
def path_join(+dir: String, +target: String) -> String:
  dir ++ "/" ++ target

# The directory portion of a page id: everything before the last '/'.
# "guides/getting-started" -> "guides"; "index" -> "" (the content root).
def path_dirname(+id: String) -> String:
  +segs = String.split(id, '/')
  +len = List.length(&2, String, segs)
  String.join(List.take(&2, String, segs, Nat.sub(len, 1n)), "/")

# --- convenience --------------------------------------------------------------

# Everything after the first '#', stripped: the fragment-free base of a
# link target.  With no '#' the target is unchanged (String.split always
# yields at least the head).
def path_frag_of(parts: List<&2, String>) -> String:
  match parts:
    case Nil{}:
      ""
    case +h <> t:
      h

def path_strip_fragment(+s: String) -> String:
  path_frag_of(String.split(s, '#'))

def path_has_query(+s: String) -> Bool:
  String.contains(s, "?")

def path_ends_md(+s: String) -> Bool:
  String.ends_with(s, ".md")

# Strip a trailing ".md" (callers gate on path_ends_md first).  ".md" is
# three characters, and String.take counts characters.
def path_strip_md(+s: String) -> String:
  String.take(s, Nat.sub(String.length(s), 3n))

type PathSegPair is Data:
  PathSegPair{source: List<&2, String>, target: List<&2, String>}

def path_seg_pair(xs: List<&2, String>, ys: List<&2, String>) -> PathSegPair:
  PathSegPair{xs, ys}

def path_nonempty_segs.go(xs: List<&2, String>, empty: Bool) -> List<&2, String>:
  match empty:
    case True{}:
      Nil{}
    case False{}:
      xs

def path_nonempty_segs(+s: String) -> List<&2, String>:
  path_nonempty_segs.go(String.split(s, '/'), String.is_empty(s))

def path_html_segs(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> Nil{}:
      String.append(h, ".html") <> Nil{}
    case +h <> t:
      h <> path_html_segs(t)

def path_common_go(xs: List<&2, String>, ys: List<&2, String>) -> PathSegPair:
  match xs:
    case Nil{}:
      path_seg_pair(xs, ys)
    case +xh <> +xt:
      match ys:
        case Nil{}:
          path_seg_pair(xh <> xt, ys)
        case +yh <> +yt:
          ifs(PathSegPair, String.eq(xh, yh),
            u => path_common_go(xt, yt),
            u => path_seg_pair(xh <> xt, yh <> yt))

def path_repeated_ups(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+p:
      "../" ++ path_repeated_ups(p)

# --- generated URL output encoding -------------------------------------------
#
# Generated href paths must be valid URL text even when page filenames contain
# spaces, percent signs, delimiters, or Unicode.  The encoder is deliberately
# stricter than the engine's input normalizer: `%` itself is encoded because
# these are freshly generated output references, not author-supplied URI text.
# `/` remains structural.  Dot characters are unreserved, so `..` navigation
# and the `.html` suffix are unchanged.

def uri_hex_digit(+x: U32) -> String:
  ifs(String, U32.is_le(x, 9),
    u => SCon{Char.from_u32(U32.add(x, 48)), SNil{}},
    u => SCon{Char.from_u32(U32.add(x, 55)), SNil{}})

def uri_percent_byte(+x: U32) -> String:
  "%" ++ uri_hex_digit(U32.div(x, 16)) ++ uri_hex_digit(U32.mod(x, 16))

def uri_percent_codepoint(+x: U32) -> String:
  ifs(String, U32.is_lt(x, 128),
    u => uri_percent_byte(x),
    u =>
      ifs(String, U32.is_lt(x, 2048),
        v =>
          uri_percent_byte(U32.add(192, U32.shrn(x, 6n))) ++
            uri_percent_byte(U32.add(128, U32.and(x, 63))),
        v =>
          ifs(String, U32.is_lt(x, 65536),
            w =>
              uri_percent_byte(U32.add(224, U32.shrn(x, 12n))) ++
                uri_percent_byte(U32.add(128, U32.and(U32.shrn(x, 6n), 63))) ++
                uri_percent_byte(U32.add(128, U32.and(x, 63))),
            w =>
              uri_percent_byte(U32.add(240, U32.shrn(x, 18n))) ++
                uri_percent_byte(U32.add(128, U32.and(U32.shrn(x, 12n), 63))) ++
                uri_percent_byte(U32.add(128, U32.and(U32.shrn(x, 6n), 63))) ++
                uri_percent_byte(U32.add(128, U32.and(x, 63))))))

def uri_output_path_char(+c: Char) -> Bool:
  Char.is_alpha(c) || Char.is_digit(c) ||
    Char.is_eq(c, '-') || Char.is_eq(c, '.') || Char.is_eq(c, '_') ||
    Char.is_eq(c, '~') || Char.is_eq(c, '/')

def uri_encode_output_path(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      ifs(String, uri_output_path_char(h),
        u => SCon{h, uri_encode_output_path(t)},
        u => uri_percent_codepoint(Char.to_u32(h)) ++ uri_encode_output_path(t))

def path_relative_html_fin(pair: PathSegPair, +fragment: String) -> String:
  match pair:
    case PathSegPair{+source, +target}:
      +raw = path_repeated_ups(List.length(&2, String, source)) ++ String.join(target, "/")
      uri_encode_output_path(raw) ++ fragment

def path_target_html(+target_id: String, empty: Bool) -> List<&2, String>:
  match empty:
    case True{}:
      ".html" <> Nil{}
    case False{}:
      path_html_segs(path_nonempty_segs(target_id))

def path_relative_html(+source_id: String, +target_id: String, +fragment: String) -> String:
  +source_dir = path_nonempty_segs(path_dirname(source_id))
  +target_out = path_target_html(target_id, String.is_empty(target_id))
  path_relative_html_fin(path_common_go(source_dir, target_out), fragment)

def path_frag_index(s: String, +idx: Nat) -> Maybe<&2, Nat>:
  match s:
    case SNil{}:
      None{}
    case SCon{'#', t}:
      Some{idx}
    case SCon{h, t}:
      path_frag_index(t, Nat.add(idx, 1n))

def path_fragment_suffix.fin(+s: String, m: Maybe<&2, Nat>) -> String:
  match m:
    case None{}:
      ""
    case Some{+idx}:
      String.drop(s, idx)

def path_fragment_suffix(+s: String) -> String:
  path_fragment_suffix.fin(s, path_frag_index(s, 0n))
