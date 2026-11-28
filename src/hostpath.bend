import Base

# POSIX path algebra over filesystem-boundary byte strings (List U32), not
# Unicode Strings.  Only bytes 47 (`/`) and 46 (`.`) are structural; every
# other byte, including non-UTF-8 bytes, is opaque path text.  This matches the
# POSIX boundary pubend's native host must preserve: Node's reference host used
# JS strings, but the filesystem itself is byte-oriented and NUL is rejected by
# the IO boundary rather than by this algebra.
#
# The public functions mirror node:path.posix as used by tools/pubend.mjs:
#   * normalize is purely lexical, removes dot/empty segments, resolves `..`
#     without touching the filesystem, clamps `..` at an absolute root, and
#     preserves one trailing slash (except for the root and the `./` case);
#   * join ignores empty parts and concatenates the rest with `/` before
#     normalize.  An absolute right-hand part does NOT reset the accumulation;
#   * resolve scans parts right-to-left until an absolute part, prepends the
#     explicit cwd when no absolute part is found, normalizes absolutely, and
#     strips trailing slashes.  Unlike Node's ambient process.cwd(), the cwd is
#     a parameter so the function remains pure;
#   * dirname and basename follow Node's non-normalizing byte-slice semantics,
#     including dirname's surprising preservation of repeated leading slashes;
#   * relative resolves both inputs first.  *_resolved variants are for the
#     host's canonical absolute paths and avoid supplying cwd again;
#   * the containment predicates implement tools/pubend.mjs's pathEscape test:
#     path.relative(parent, child) must neither be absolute nor be nor start
#     with `..` as a complete first segment.  Strict containment additionally
#     rejects equality (the empty relative path).

def ifs(-A: Type, z: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match z:
    case True{}:
      yes(Unit{})
    case False{}:
      no(Unit{})

# --- byte constants and small byte-list utilities ----------------------------

def hostpath_empty_bytes() -> List<&2, U32>:
  Nil{}

def hostpath_slash() -> U32:
  47

def hostpath_dot() -> U32:
  46

def hostpath_is_slash(+b: U32) -> Bool:
  U32.is_eq(b, hostpath_slash())

def hostpath_is_dot(+b: U32) -> Bool:
  U32.is_eq(b, hostpath_dot())

def hostpath_slash_bytes() -> List<&2, U32>:
  hostpath_slash() <> Nil{}

def hostpath_dot_bytes() -> List<&2, U32>:
  hostpath_dot() <> Nil{}

def hostpath_dotdot_bytes() -> List<&2, U32>:
  hostpath_dot() <> hostpath_dot() <> Nil{}

def hostpath_dotdotslash_bytes() -> List<&2, U32>:
  hostpath_dot() <> hostpath_dot() <> hostpath_slash() <> Nil{}

def hostpath_dotslash_bytes() -> List<&2, U32>:
  hostpath_dot() <> hostpath_slash() <> Nil{}

def hostpath_slashslash_bytes() -> List<&2, U32>:
  hostpath_slash() <> hostpath_slash() <> Nil{}

def hostpath_bytes_empty(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      False{}

def hostpath_bytes_append(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> hostpath_bytes_append(t, ys)

def hostpath_bytes_reverse.go(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      hostpath_bytes_reverse.go(t, h <> acc)

def hostpath_bytes_reverse(xs: List<&2, U32>) -> List<&2, U32>:
  hostpath_bytes_reverse.go(xs, Nil{})

def hostpath_bytes_eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case xh <> xt yh <> yt:
      ifs(Bool, U32.is_eq(xh, yh),
        u => hostpath_bytes_eq(xt, yt),
        u => False{})
    case x y:
      False{}

def hostpath_bytes_starts_with.go(p: List<&2, U32>, s: List<&2, U32>) -> Bool:
  match p s:
    case Nil{} x:
      True{}
    case ph <> pt Nil{}:
      False{}
    case ph <> pt sh <> st:
      ifs(Bool, U32.is_eq(ph, sh),
        u => hostpath_bytes_starts_with.go(pt, st),
        u => False{})

def hostpath_bytes_starts_with(+s: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  hostpath_bytes_starts_with.go(p, s)

def hostpath_last_byte(xs: List<&2, U32>) -> Maybe<&2, U32>:
  match xs:
    case Nil{}:
      None{}
    case +h <> Nil{}:
      Some{h}
    case h <> t:
      hostpath_last_byte(t)

def hostpath_last_is_slash(m: Maybe<&2, U32>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{+x}:
      hostpath_is_slash(x)

def hostpath_is_absolute(+path: List<&2, U32>) -> Bool:
  match path:
    case Nil{}:
      False{}
    case +h <> t:
      hostpath_is_slash(h)

def hostpath_has_trailing_slash(+path: List<&2, U32>) -> Bool:
  hostpath_last_is_slash(hostpath_last_byte(path))

# Split at byte 47, preserving empty segments exactly like String.split does
# for text.  Examples: "" -> [""], "/" -> ["", ""], "a//b" -> ["a","","b"].
def hostpath_split_push(+x: U32, ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      (x <> Nil{}) <> Nil{}
    case h <> t:
      (x <> h) <> t

def hostpath_split_fin(+x: U32, r: List<&2, List<&2, U32>>, cut: Bool) ->
  List<&2, List<&2, U32>>:
  match cut:
    case False{}:
      hostpath_split_push(x, r)
    case True{}:
      hostpath_empty_bytes() <> r

def hostpath_split(xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      hostpath_empty_bytes() <> Nil{}
    case +h <> t:
      hostpath_split_fin(h, hostpath_split(t), hostpath_is_slash(h))

def hostpath_segments_empty(xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      False{}

def hostpath_segments_append(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      h <> hostpath_segments_append(t, ys)

def hostpath_segments_reverse.go(xs: List<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      hostpath_segments_reverse.go(t, h <> acc)

def hostpath_segments_reverse(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  hostpath_segments_reverse.go(xs, Nil{})

def hostpath_segments_length(xs: List<&2, List<&2, U32>>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      1n+hostpath_segments_length(t)

# Join already-split segments with single byte-47 separators.  This helper does
# not normalize; it is just the inverse of split for a nonempty segment list.
def hostpath_join_segments.go(rest: List<&2, List<&2, U32>>, +h: List<&2, U32>) -> List<&2, U32>:
  match rest:
    case Nil{}:
      h
    case +h2 <> t:
      hostpath_bytes_append(h,
        hostpath_bytes_append(hostpath_slash_bytes(), hostpath_join_segments.go(t, h2)))

def hostpath_join_segments(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      hostpath_empty_bytes()
    case +h <> t:
      hostpath_join_segments.go(t, h)

# --- lexical normalization ----------------------------------------------------

type HostPathSeg is Data:
  HpSegSkip{}
  HpSegPop{}
  HpSegName{name: List<&2, U32>}

def hp_seg_skip() -> HostPathSeg:
  HpSegSkip{}

def hp_seg_pop() -> HostPathSeg:
  HpSegPop{}

def hp_seg_name(+name: List<&2, U32>) -> HostPathSeg:
  HpSegName{name}

def hp_classify(+seg: List<&2, U32>) -> HostPathSeg:
  ifs(HostPathSeg, hostpath_bytes_empty(seg),
    u => hp_seg_skip(),
    u => ifs(HostPathSeg, hostpath_bytes_eq(seg, hostpath_dot_bytes()),
      v => hp_seg_skip(),
      v => ifs(HostPathSeg, hostpath_bytes_eq(seg, hostpath_dotdot_bytes()),
        w => hp_seg_pop(),
        w => hp_seg_name(seg))))

def hp_norm_pop_empty(allow: Bool) -> List<&2, List<&2, U32>>:
  match allow:
    case True{}:
      hostpath_dotdot_bytes() <> Nil{}
    case False{}:
      Nil{}

def hp_norm_pop_nonempty(+h: List<&2, U32>, t: List<&2, List<&2, U32>>, isdotdot: Bool, +allow: Bool) ->
  List<&2, List<&2, U32>>:
  match isdotdot:
    case False{}:
      t
    case True{}:
      match allow:
        case True{}:
          hostpath_dotdot_bytes() <> (h <> t)
        case False{}:
          h <> t

def hp_norm_apply(seg: HostPathSeg, stack: List<&2, List<&2, U32>>, +allow: Bool) ->
  List<&2, List<&2, U32>>:
  match seg:
    case HpSegSkip{}:
      stack
    case HpSegName{+name}:
      name <> stack
    case HpSegPop{}:
      match stack:
        case Nil{}:
          hp_norm_pop_empty(allow)
        case +h <> t:
          hp_norm_pop_nonempty(h, t, hostpath_bytes_eq(h, hostpath_dotdot_bytes()), allow)

# The stack is reversed output: its head is the deepest-pushed segment.  As in
# Node's normalizeString, a `..` pops one ordinary name; it is retained only
# when allowAboveRoot is true and no ordinary name is available.  Absolute
# public normalization and resolve pass False, so `/../../x` becomes `/x`.
def hp_norm_go(segs: List<&2, List<&2, U32>>, stack: List<&2, List<&2, U32>>, +allow: Bool) ->
  List<&2, List<&2, U32>>:
  match segs:
    case Nil{}:
      stack
    case +h <> t:
      hp_norm_go(t, hp_norm_apply(hp_classify(h), stack, allow), allow)

def hp_normalize_core(+path: List<&2, U32>, +allow: Bool) -> List<&2, U32>:
  +stack = hp_norm_go(hostpath_split(path), Nil{}, allow)
  hostpath_join_segments(hostpath_segments_reverse(stack))

def hp_norm_empty_fin(absolute: Bool, trailing: Bool) -> List<&2, U32>:
  match absolute trailing:
    case True{} x:
      hostpath_slash_bytes()
    case False{} True{}:
      hostpath_dotslash_bytes()
    case False{} False{}:
      hostpath_dot_bytes()

def hp_norm_base(+core: List<&2, U32>, absolute: Bool) -> List<&2, U32>:
  match absolute:
    case True{}:
      hostpath_bytes_append(hostpath_slash_bytes(), core)
    case False{}:
      core

def hp_norm_trailing(+base: List<&2, U32>, trailing: Bool) -> List<&2, U32>:
  match trailing:
    case True{}:
      hostpath_bytes_append(base, hostpath_slash_bytes())
    case False{}:
      base

def hp_norm_fin(+core: List<&2, U32>, absolute: Bool, trailing: Bool, empty: Bool) -> List<&2, U32>:
  match empty:
    case True{}:
      hp_norm_empty_fin(absolute, trailing)
    case False{}:
      hp_norm_trailing(hp_norm_base(core, absolute), trailing)

def hostpath_normalize_gate(+path: List<&2, U32>, empty: Bool) -> List<&2, U32>:
  match empty:
    case True{}:
      hostpath_dot_bytes()
    case False{}:
      +absolute = hostpath_is_absolute(path)
      +trailing = hostpath_has_trailing_slash(path)
      +allow = Bool.not(absolute)
      +core = hp_normalize_core(path, allow)
      hp_norm_fin(core, absolute, trailing, hostpath_bytes_empty(core))

# node:path.posix.normalize.  This is lexical only: no symlink or filesystem
# lookup is implied, and absolute inputs clamp leading `..` at `/`.
def hostpath_normalize(+path: List<&2, U32>) -> List<&2, U32>:
  hostpath_normalize_gate(path, hostpath_bytes_empty(path))

# --- resolve ------------------------------------------------------------------

type HostPathResolveAcc is Data:
  HpResolveAcc{path: List<&2, U32>, absolute: Bool}

def hp_resolve_acc(+path: List<&2, U32>, absolute: Bool) -> HostPathResolveAcc:
  HpResolveAcc{path, absolute}

def hp_prepend_part_gate(+piece: List<&2, U32>, +acc: List<&2, U32>, acc_empty: Bool) -> List<&2, U32>:
  match acc_empty:
    case True{}:
      piece
    case False{}:
      hostpath_bytes_append(piece, hostpath_bytes_append(hostpath_slash_bytes(), acc))

def hp_prepend_part(+piece: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  hp_prepend_part_gate(piece, acc, hostpath_bytes_empty(acc))

# Scan right-to-left.  The first absolute byte string stops the scan and every
# part to its left is discarded, exactly like path.posix.resolve.  `next` is
# built before the empty-part gate because Bend has no mutual recursion; for an
# empty part it is simply discarded.
def hp_resolve_go(parts: List<&2, List<&2, U32>>, +acc: List<&2, U32>, +absolute: Bool) ->
  HostPathResolveAcc:
  match parts:
    case Nil{}:
      hp_resolve_acc(acc, absolute)
    case +h <> +t:
      +next = hp_prepend_part(h, acc)
      ifs(HostPathResolveAcc, hostpath_bytes_empty(h),
        u => hp_resolve_go(t, acc, absolute),
        u => ifs(HostPathResolveAcc, hostpath_is_absolute(h),
          v => hp_resolve_acc(next, True{}),
          v => hp_resolve_go(t, next, absolute)))

def hp_resolved_base(+core: List<&2, U32>, absolute: Bool) -> List<&2, U32>:
  match absolute:
    case True{}:
      hostpath_bytes_append(hostpath_slash_bytes(), core)
    case False{}:
      core

def hp_resolve_norm_fin(+core: List<&2, U32>, empty: Bool, absolute: Bool) -> List<&2, U32>:
  match empty:
    case True{}:
      match absolute:
        case True{}:
          hostpath_slash_bytes()
        case False{}:
          hostpath_dot_bytes()
    case False{}:
      hp_resolved_base(core, absolute)

# resolve uses normalizeString with trailing separators stripped rather than
# public normalize's trailing-separator preservation.
def hp_normalize_for_resolve(+path: List<&2, U32>, +absolute: Bool) -> List<&2, U32>:
  +core = hp_normalize_core(path, Bool.not(absolute))
  hp_resolve_norm_fin(core, hostpath_bytes_empty(core), absolute)

def hp_resolve_finish_abs(+path: List<&2, U32>) -> List<&2, U32>:
  hp_normalize_for_resolve(path, True{})

def hp_resolve_finish_cwd(+cwd: List<&2, U32>, +path: List<&2, U32>) -> List<&2, U32>:
  +joined = hp_prepend_part(cwd, path)
  hp_normalize_for_resolve(joined, hostpath_is_absolute(cwd))

def hp_resolve_finish(+cwd: List<&2, U32>, acc: HostPathResolveAcc) -> List<&2, U32>:
  match acc:
    case HpResolveAcc{+path, +absolute}:
      match absolute:
        case True{}:
          hp_resolve_finish_abs(path)
        case False{}:
          hp_resolve_finish_cwd(cwd, path)

def hp_some_bytes(+path: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  Some{path}

def hp_no_bytes() -> Maybe<&2, List<&2, U32>>:
  None{}

def hp_fast_fin(+cwd: List<&2, U32>, cwdabs: Bool, simple: Bool) -> Maybe<&2, List<&2, U32>>:
  match cwdabs simple:
    case True{} True{}:
      hp_some_bytes(cwd)
    case x y:
      hp_no_bytes()

def hp_fastcase(+parts: List<&2, List<&2, U32>>, +cwd: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match parts:
    case Nil{}:
      hp_fast_fin(cwd, hostpath_is_absolute(cwd), True{})
    case +h <> Nil{}:
      +simple = Bool.or(hostpath_bytes_empty(h), hostpath_bytes_eq(h, hostpath_dot_bytes()))
      hp_fast_fin(cwd, hostpath_is_absolute(cwd), simple)
    case x:
      hp_no_bytes()

def hp_resolve_slow(+cwd: List<&2, U32>, +parts: List<&2, List<&2, U32>>) -> List<&2, U32>:
  hp_resolve_finish(cwd, hp_resolve_go(hostpath_segments_reverse(parts), hostpath_empty_bytes(), False{}))

def hostpath_resolve_gate(+cwd: List<&2, U32>, +parts: List<&2, List<&2, U32>>,
  fast: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match fast:
    case Some{+path}:
      path
    case None{}:
      hp_resolve_slow(cwd, parts)

# Pure analogue of path.posix.resolve(...parts): cwd is explicit.  With an
# absolute canonical cwd this is byte-for-byte Node's behavior, including the
# no-effective-input fast path that returns cwd exactly.
def hostpath_resolve(+cwd: List<&2, U32>, +parts: List<&2, List<&2, U32>>) -> List<&2, U32>:
  hostpath_resolve_gate(cwd, parts, hp_fastcase(parts, cwd))

def hostpath_resolve1(+cwd: List<&2, U32>, +part: List<&2, U32>) -> List<&2, U32>:
  hostpath_resolve(cwd, part <> Nil{})

# --- join ---------------------------------------------------------------------

def hp_join_cons_nonempty(+h: List<&2, U32>, rest: Maybe<&2, List<&2, U32>>) ->
  Maybe<&2, List<&2, U32>>:
  match rest:
    case None{}:
      hp_some_bytes(h)
    case Some{+r}:
      hp_some_bytes(hostpath_bytes_append(h, hostpath_bytes_append(hostpath_slash_bytes(), r)))

def hp_join_cons(+h: List<&2, U32>, rest: Maybe<&2, List<&2, U32>>, empty: Bool) ->
  Maybe<&2, List<&2, U32>>:
  match empty:
    case True{}:
      rest
    case False{}:
      hp_join_cons_nonempty(h, rest)

def hp_join_go(parts: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match parts:
    case Nil{}:
      hp_no_bytes()
    case +h <> t:
      hp_join_cons(h, hp_join_go(t), hostpath_bytes_empty(h))

def hostpath_join_gate(joined: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match joined:
    case None{}:
      hostpath_dot_bytes()
    case Some{+path}:
      hostpath_normalize(path)

# path.posix.join(...parts).  Empty parts are ignored.  Absolute later parts do
# not reset earlier ones: join('/a', '/b') is '/a/b'.
def hostpath_join(+parts: List<&2, List<&2, U32>>) -> List<&2, U32>:
  hostpath_join_gate(hp_join_go(parts))

def hostpath_join2(+a: List<&2, U32>, +b: List<&2, U32>) -> List<&2, U32>:
  hostpath_join(a <> b <> Nil{})

# --- dirname and basename -------------------------------------------------------

type HostPathDirScan is Data:
  HpDirNone{}
  HpDirFound{prefixrev: List<&2, U32>}

def hp_dir_none() -> HostPathDirScan:
  HpDirNone{}

def hp_dir_found(+prefixrev: List<&2, U32>) -> HostPathDirScan:
  HpDirFound{prefixrev}

# Scan the reversed input.  A slash is a dirname delimiter only after a
# non-slash byte has been seen; the final reverse element (original byte 0) is
# never a delimiter.  When the delimiter is found, its tail is already the
# reversed prefix that dirname must return, which avoids index arithmetic.
def hp_dir_scan(rev: List<&2, U32>, +matched: Bool) -> HostPathDirScan:
  match rev:
    case Nil{}:
      hp_dir_none()
    case +h <> +t:
      ifs(HostPathDirScan, hostpath_bytes_empty(t),
        z => hp_dir_none(),
        z => ifs(HostPathDirScan, hostpath_is_slash(h),
          u => ifs(HostPathDirScan, matched,
            v => hp_dir_scan(t, True{}),
            v => hp_dir_found(t)),
          u => hp_dir_scan(t, False{})))

def hp_dir_fallback(hasroot: Bool) -> List<&2, U32>:
  match hasroot:
    case True{}:
      hostpath_slash_bytes()
    case False{}:
      hostpath_dot_bytes()

def hp_dir_found_fin(+prefixrev: List<&2, U32>, hasroot: Bool, lenone: Bool) -> List<&2, U32>:
  match hasroot lenone:
    case True{} True{}:
      hostpath_slashslash_bytes()
    case x y:
      hostpath_bytes_reverse(prefixrev)

def hp_dir_finish(scan: HostPathDirScan, hasroot: Bool) -> List<&2, U32>:
  match scan:
    case HpDirNone{}:
      hp_dir_fallback(hasroot)
    case HpDirFound{+prefixrev}:
      hp_dir_found_fin(prefixrev, hasroot,
        Nat.is_eq(List.length(&2, U32, prefixrev), 1n))

def hostpath_dirname_gate(+path: List<&2, U32>, empty: Bool) -> List<&2, U32>:
  match empty:
    case True{}:
      hostpath_dot_bytes()
    case False{}:
      hp_dir_finish(hp_dir_scan(hostpath_bytes_reverse(path), True{}), hostpath_is_absolute(path))

# path.posix.dirname, not normalized dirname.  Interior duplicate separators
# are preserved ('a//b' -> 'a/'), and Node's leading-slash quirk is preserved
# exactly ('//a' -> '//', '///a' -> '//', '////a' -> '///').
def hostpath_dirname(+path: List<&2, U32>) -> List<&2, U32>:
  hostpath_dirname_gate(path, hostpath_bytes_empty(path))

def hp_drop_rev_slashes(rev: List<&2, U32>) -> List<&2, U32>:
  match rev:
    case Nil{}:
      Nil{}
    case +h <> +t:
      ifs(List<&2, U32>, hostpath_is_slash(h),
        u => hp_drop_rev_slashes(t),
        u => h <> t)

def hp_take_rev_name(xs: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case +h <> +t:
      ifs(List<&2, U32>, hostpath_is_slash(h),
        u => acc,
        u => hp_take_rev_name(t, h <> acc))

# path.posix.basename without the optional suffix parameter (the reference
# host never uses that parameter).  Trailing slashes are ignored; an all-slash
# path has an empty basename.
def hostpath_basename(+path: List<&2, U32>) -> List<&2, U32>:
  hp_take_rev_name(hp_drop_rev_slashes(hostpath_bytes_reverse(path)), Nil{})

# --- relative and containment ---------------------------------------------------

def hostpath_nonempty_segments(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      ifs(List<&2, List<&2, U32>>, hostpath_bytes_empty(h),
        u => hostpath_nonempty_segments(t),
        u => h <> hostpath_nonempty_segments(t))

type HostPathSegPair is Data:
  HpSegPair{source: List<&2, List<&2, U32>>, target: List<&2, List<&2, U32>>}

def hp_seg_pair(source: List<&2, List<&2, U32>>, target: List<&2, List<&2, U32>>) -> HostPathSegPair:
  HpSegPair{source, target}

def hp_common_go(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) -> HostPathSegPair:
  match xs:
    case Nil{}:
      hp_seg_pair(xs, ys)
    case +xh <> +xt:
      match ys:
        case Nil{}:
          hp_seg_pair(xh <> xt, ys)
        case +yh <> +yt:
          ifs(HostPathSegPair, hostpath_bytes_eq(xh, yh),
            u => hp_common_go(xt, yt),
            u => hp_seg_pair(xh <> xt, yh <> yt))

def hp_ups(n: Nat) -> List<&2, List<&2, U32>>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      hostpath_dotdot_bytes() <> hp_ups(p)

def hp_relative_fin(pair: HostPathSegPair) -> List<&2, U32>:
  match pair:
    case HpSegPair{+source, +target}:
      hostpath_join_segments(hostpath_segments_append(hp_ups(hostpath_segments_length(source)), target))

# Relative algebra for two already-resolved absolute canonical paths.  Resolved
# paths contain no empty or dot segments and no trailing slash except root, so
# segment-wise longest-common-prefix algebra is exactly Node's slash-scanning
# algorithm.  Prefix traps are segment-based: '/a' to '/ab' is '../ab'.
def hostpath_relative_resolved(+from: List<&2, U32>, +to: List<&2, U32>) -> List<&2, U32>:
  +fromsegs = hostpath_nonempty_segments(hostpath_split(from))
  +tosegs = hostpath_nonempty_segments(hostpath_split(to))
  hp_relative_fin(hp_common_go(fromsegs, tosegs))

# path.posix.relative(from, to), with explicit cwd for purity.
def hostpath_relative(+cwd: List<&2, U32>, +from: List<&2, U32>, +to: List<&2, U32>) -> List<&2, U32>:
  hostpath_relative_resolved(hostpath_resolve1(cwd, from), hostpath_resolve1(cwd, to))

def hp_escape_gate(escape: Bool) -> Bool:
  match escape:
    case True{}:
      True{}
    case False{}:
      False{}

# tools/pubend.mjs pathEscape: exactly '..', a leading '../' segment, or an
# absolute relative result.  The final clause is defensive for resolved inputs;
# ordinary absolute-from/absolute-to relative results are never absolute.
def hostpath_escape(+rel: List<&2, U32>) -> Bool:
  hp_escape_gate(Bool.or(hostpath_bytes_eq(rel, hostpath_dotdot_bytes()),
    Bool.or(hostpath_bytes_starts_with(rel, hostpath_dotdotslash_bytes()),
      hostpath_is_absolute(rel))))

def hp_strict_gate(empty: Bool, escape: Bool) -> Bool:
  match empty escape:
    case False{} False{}:
      True{}
    case x y:
      False{}

# Containment over already canonical/resolved paths, in the argument order used
# by tools/pubend.mjs: isXInside(child, parent).
def hostpath_is_strictly_inside_resolved(+child: List<&2, U32>, +parent: List<&2, U32>) -> Bool:
  +rel = hostpath_relative_resolved(parent, child)
  hp_strict_gate(hostpath_bytes_empty(rel), hostpath_escape(rel))

def hp_inside_gate(escape: Bool) -> Bool:
  match escape:
    case True{}:
      False{}
    case False{}:
      True{}

def hostpath_is_inside_or_equal_resolved(+child: List<&2, U32>, +parent: List<&2, U32>) -> Bool:
  hp_inside_gate(hostpath_escape(hostpath_relative_resolved(parent, child)))

# Exact pure analogues of the Node-host predicates for unresolved inputs.  The
# explicit cwd participates in path.relative's initial resolve of both sides.
def hostpath_is_strictly_inside(+cwd: List<&2, U32>, +child: List<&2, U32>, +parent: List<&2, U32>) -> Bool:
  +rel = hostpath_relative(cwd, parent, child)
  hp_strict_gate(hostpath_bytes_empty(rel), hostpath_escape(rel))

def hostpath_is_inside_or_equal(+cwd: List<&2, U32>, +child: List<&2, U32>, +parent: List<&2, U32>) -> Bool:
  hp_inside_gate(hostpath_escape(hostpath_relative(cwd, parent, child)))
