import Base
import ./HostFS.bend as HFS
import ../src/utf8.bend as Utf8
import ../src/hostpath.bend as HP
import ../src/hostjson.bend as HJ

# Shared native-host boundary types, byte/string conversion, diagnostics, and
# the small exception-style IO flow used by the publication host.  This module
# is host-side infrastructure only: publication semantics live in the narrower
# scan/collision/publication modules.

def Bytes() -> Data:
  List<&2, U32>

def HostIOError() -> Type:
  U32 & String

def HStatResult() -> Type:
  Result<&1, &1, HostIOError(), HFS.StatInfo>

def HUnitResult() -> Type:
  Result<&1, &1, HostIOError(), Unit>

def HBytesResult() -> Type:
  Result<&1, &1, HostIOError(), Bytes()>

def HEntriesResult() -> Type:
  Result<&1, &1, HostIOError(), List<&2, HFS.DirInfo>>

# --- byte utilities -----------------------------------------------------------

def byte_cons(b: U32, xs: Bytes()) -> Bytes():
  b <> xs

def bytes_empty() -> Bytes():
  Nil{}

def bytes_append(+xs: Bytes(), +ys: Bytes()) -> Bytes():
  HP.hostpath_bytes_append(xs, ys)

def bytes_eq(+xs: Bytes(), +ys: Bytes()) -> Bool:
  HP.hostpath_bytes_eq(xs, ys)

def bytes_starts_with(+xs: Bytes(), +prefix: Bytes()) -> Bool:
  HP.hostpath_bytes_starts_with(xs, prefix)

def bytes_length(xs: Bytes()) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      1n+bytes_length(t)

def bytes_end_suffix_gate(+xs: Bytes(), +suffix: Bytes(), sameprefix: Bool) -> Bool:
  match sameprefix:
    case True{}:
      True{}
    case False{}:
      False{}

# Bytes endswith, implemented by reversing both inputs.  The inputs are small
# path names or ASCII suffixes; clarity and exactness matter more than the
# extra linear pass here.
def bytes_ends_with(+xs: Bytes(), +suffix: Bytes()) -> Bool:
  HP.hostpath_bytes_starts_with(HP.hostpath_bytes_reverse(xs), HP.hostpath_bytes_reverse(suffix))

def ascii_bytes(s: String) -> Bytes():
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      byte_cons(Char.to_u32(h), ascii_bytes(t))

def ascii_byte_string(xs: Bytes()) -> String:
  match xs:
    case Nil{}:
      ""
    case +h <> t:
      SCon{Char.from_u32(h), ascii_byte_string(t)}

def ascii_join_path(+base: Bytes(), +name: String) -> Bytes():
  HP.hostpath_join2(base, ascii_bytes(name))


def ascii_lower_byte(+b: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_ge(b, 65), U32.is_le(b, 90)), U32.add(b, 32), b)

def ascii_upper_byte(+b: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_ge(b, 97), U32.is_le(b, 122)), U32.sub(b, 32), b)

def ascii_lower_bytes(xs: Bytes()) -> Bytes():
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      ascii_lower_byte(h) <> ascii_lower_bytes(t)

def ascii_upper_bytes(xs: Bytes()) -> Bytes():
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      ascii_upper_byte(h) <> ascii_upper_bytes(t)


# --- UTF-8 conversion -----------------------------------------------------------

type ByteText is Data:
  ByteTextOk{text: String}
  ByteTextInvalid{}

def byte_text_ok(+text: String) -> ByteText:
  ByteTextOk{text}

def byte_text_invalid() -> ByteText:
  ByteTextInvalid{}

def decode_bytes_gate(r: Utf8.Utf8DecodeResult) -> ByteText:
  match r:
    case Utf8.Utf8DecodeOk{+text, codepoints}:
      byte_text_ok(text)
    case Utf8.Utf8DecodeInvalid{offset}:
      byte_text_invalid()

# Strict UTF-8 decode for values that must become Bend strings without lossy
# replacement.  Invalid input is explicit rather than silently repaired.
def decode_bytes_strict(+bytes: Bytes()) -> ByteText:
  decode_bytes_gate(Utf8.utf8_decode(bytes))

def display_char_byte(+b: U32, ascii: Bool) -> String:
  match ascii:
    case True{}:
      SCon{Char.from_u32(b), SNil{}}
    case False{}:
      "�"

def display_bytes_go(xs: Bytes()) -> String:
  match xs:
    case Nil{}:
      ""
    case +h <> t:
      display_char_byte(h, U32.is_le(h, 127)) ++ display_bytes_go(t)

def bytes_display_gate(r: ByteText, +bytes: Bytes()) -> String:
  match r:
    case ByteTextOk{+text}:
      text
    case ByteTextInvalid{}:
      display_bytes_go(bytes)

# Node-facing diagnostics are Unicode strings.  Valid UTF-8 names round-trip
# exactly; invalid POSIX bytes are rendered with U+FFFD for non-ASCII bytes so
# diagnostics remain strict UTF-8 instead of crashing or omitting the path.
def bytes_display(+bytes: Bytes()) -> String:
  bytes_display_gate(decode_bytes_strict(bytes), bytes)

def encode_bytes_gate(r: Utf8.Utf8EncodeResult) -> Maybe<&2, Bytes()>:
  match r:
    case Utf8.Utf8EncodeOk{+bytes}:
      Some{bytes}
    case Utf8.Utf8EncodeInvalid{offset, code}:
      None{}

# Validating UTF-8 encoding.  Real publication strings originate in strict
# UTF-8 input or the pure renderer, so None{} is unreachable in the product
# boundary; callers treat it as a host-error rather than writing corrupt bytes.
def encode_string_bytes(+text: String) -> Maybe<&2, Bytes()>:
  encode_bytes_gate(Utf8.utf8_encode(text))

def utf8_bytes_or_empty_gate(m: Maybe<&2, Bytes()>) -> Bytes():
  match m:
    case Some{+bytes}:
      bytes
    case None{}:
      Nil{}

def utf8_bytes_or_empty(+text: String) -> Bytes():
  utf8_bytes_or_empty_gate(encode_string_bytes(text))

# --- errno and numeric boundaries ------------------------------------------------

def errno_enoent() -> U32:
  2

def errno_enotdir() -> U32:
  20

def errno_eexist() -> U32:
  17

def io_error_code(e: HostIOError()) -> U32:
  (code, message) = e
  code

def io_error_message(e: HostIOError()) -> String:
  (code, +message) = e
  message

def io_error_text(e: HostIOError()) -> String:
  (code, +message) = e
  Bool.pick(String, String.is_empty(message), "errno " ++ U32.show(code), message)

def is_enoent_or_enotdir(e: HostIOError()) -> Bool:
  +code = io_error_code(e)
  Bool.or(U32.is_eq(code, errno_enoent()), U32.is_eq(code, errno_enotdir()))

def u64_parts_eq(a: HFS.U64Parts, b: HFS.U64Parts) -> Bool:
  match a b:
    case HFS.U64Parts{+ahi, +alo} HFS.U64Parts{+bhi, +blo}:
      Bool.and(U32.is_eq(ahi, bhi), U32.is_eq(alo, blo))

# Exact unsigned 64-bit comparison against the 1 MiB input ceiling.
def u64_gt_1mib(size: HFS.U64Parts) -> Bool:
  match size:
    case HFS.U64Parts{+hi, +lo}:
      Bool.or(U32.is_gt(hi, 0), U32.is_gt(lo, 1048576))

def bytes_len_gt_1mib(+xs: Bytes()) -> Bool:
  Nat.is_gt(bytes_length(xs), 1048576n)

# --- diagnostic model -------------------------------------------------------------

type DiagClass is Data:
  DUsageError{}
  DOutputOutsideSite{}
  DOutputForbidden{}
  DInputIo{}
  DCompilerArtifactBuild{}
  DCompilerArtifactInvalid{}
  DCompilerInvocation{}
  DOutputSymlink{}
  DOutputNotDirectory{}
  DOutputParentNotDirectory{}
  DOutputContainment{}
  DOutputPathCollision{}
  DOutputLockExists{}
  DOutputStageInvalid{}
  DOutputBackupConflict{}
  DOutputBackupInvalid{}
  DOutputIo{}
  DOutputPublication{}
  DHostError{}
  DMissingContentDir{}
  DSymlinkedEntry{}
  DNonMdFile{}
  DOversizedPage{}
  DInvalidUtf8{}
  DMalformedFrontmatter{}
  DUnknownFrontmatterKey{}
  DDuplicateFrontmatterKey{}
  DDuplicateId{}
  DDuplicateIdCase{}
  DDanglingParent{}
  DSelfParent{}
  DParentCycle{}
  DLinkQuery{}
  DLinkRootEscape{}
  DLinkNonexistentPage{}
  DLinkMalformedPercent{}
  DLinkInvalidPercentUtf8{}

type HostSpan is Data:
  HostSpan{start: U32, end: U32}

type HostDiag is Data:
  HostDiag{cls: DiagClass, path: Maybe<&2, String>, page: Maybe<&2, String>,
    line: Maybe<&2, Nat>, column: Maybe<&2, Nat>, target: Maybe<&2, String>,
    span: Maybe<&2, HostSpan>, message: String}

type HostFailure is Data:
  HostFailure{exit_code: U32, diagnostics: List<&2, HostDiag>}

def HRes(-A: Type) -> Type:
  Result<&1, &1, HostFailure, A>

# --- small constructors -----------------------------------------------------------

def hs_span(+start: U32, +end: U32) -> HostSpan:
  HostSpan{start, end}

def maybe_string_some(+s: String) -> Maybe<&2, String>:
  Some{s}

def maybe_string_none() -> Maybe<&2, String>:
  None{}

def maybe_nat_some(+n: Nat) -> Maybe<&2, Nat>:
  Some{n}

def maybe_nat_none() -> Maybe<&2, Nat>:
  None{}

def maybe_span_some(+s: HostSpan) -> Maybe<&2, HostSpan>:
  Some{s}

def maybe_span_none() -> Maybe<&2, HostSpan>:
  None{}

def host_diag(cls: DiagClass, path: Maybe<&2, String>, page: Maybe<&2, String>,
  line: Maybe<&2, Nat>, column: Maybe<&2, Nat>, target: Maybe<&2, String>,
  span: Maybe<&2, HostSpan>, +message: String) -> HostDiag:
  HostDiag{cls, path, page, line, column, target, span, message}

def host_diag_simple(cls: DiagClass, +message: String) -> HostDiag:
  host_diag(cls, maybe_string_none(), maybe_string_none(), maybe_nat_none(), maybe_nat_none(),
    maybe_string_none(), maybe_span_none(), message)

def host_diag_path(cls: DiagClass, +path: String, +message: String) -> HostDiag:
  host_diag(cls, maybe_string_some(path), maybe_string_none(), maybe_nat_none(), maybe_nat_none(),
    maybe_string_none(), maybe_span_none(), message)

def host_failure(+exit_code: U32, diagnostics: List<&2, HostDiag>) -> HostFailure:
  HostFailure{exit_code, diagnostics}

def host_failure_one(+exit_code: U32, d: HostDiag) -> HostFailure:
  host_failure(exit_code, d <> Nil{})

def hres_done(-A: Type, x: A) -> HRes(A):
  Done{x}

def hres_fail(-A: Type, +failure: HostFailure) -> HRes(A):
  Fail{failure}

def io_hres_done(-A: Type, x: A) -> IO(HRes(A)):
  IO.pure(HRes(A), hres_done(A, x))

def io_hres_fail(-A: Type, +failure: HostFailure) -> IO(HRes(A)):
  IO.pure(HRes(A), hres_fail(A, failure))

def io_fail_one(-A: Type, +exit_code: U32, d: HostDiag) -> IO(HRes(A)):
  io_hres_fail(A, host_failure_one(exit_code, d))

def io_fail_simple(-A: Type, +exit_code: U32, cls: DiagClass, +message: String) -> IO(HRes(A)):
  io_fail_one(A, exit_code, host_diag_simple(cls, message))

def io_fail_path(-A: Type, +exit_code: U32, cls: DiagClass, +path: String, +message: String) -> IO(HRes(A)):
  io_fail_one(A, exit_code, host_diag_path(cls, path, message))

# Exception-style bind over IO(Result<HostFailure,A>).  Because Bend matches
# cannot appear inside do blocks, this named helper is the control-flow spine
# of the native host.
def flow_result_bind(-A: Type, -B: Type, r: HRes(A), f: A -> IO(HRes(B))) -> IO(HRes(B)):
  match r:
    case Fail{+e}:
      IO.pure(HRes(B), hres_fail(B, e))
    case Done{x}:
      f(x)

def flow_bind(-A: Type, -B: Type, m: IO(HRes(A)), f: A -> IO(HRes(B))) -> IO(HRes(B)):
  IO.bind(HRes(A), HRes(B), m, r => flow_result_bind(A, B, r, f))

def flow_then(-A: Type, -B: Type, m: IO(HRes(A)), next: IO(HRes(B))) -> IO(HRes(B)):
  flow_bind(A, B, m, x => next)

def flow_map_result(-A: Type, -B: Type, r: HRes(A), f: A -> B) -> HRes(B):
  match r:
    case Fail{+e}:
      hres_fail(B, e)
    case Done{x}:
      hres_done(B, f(x))

def flow_map_io(-A: Type, -B: Type, m: IO(HRes(A)), f: A -> B) -> IO(HRes(B)):
  IO.bind(HRes(A), HRes(B), m, r => IO.pure(HRes(B), flow_map_result(A, B, r, f)))

# Convert a HostFS-style result into the host failure result using a caller
# supplied diagnostic constructor.  Pure mapping keeps every syscall's error
# class decision at exactly the same point as the Node reference host.
def lift_io_result(-A: Type, r: Result<&1, &1, HostIOError(), A>,
  make_error: HostIOError() -> HostDiag) -> HRes(A):
  match r:
    case Done{x}:
      hres_done(A, x)
    case Fail{e}:
      hres_fail(A, host_failure_one(3, make_error(e)))

def flow_effect(-A: Type, act: IO(Result<&1, &1, HostIOError(), A>),
  make_error: HostIOError() -> HostDiag) -> IO(HRes(A)):
  IO.bind(Result<&1, &1, HostIOError(), A>, HRes(A), act,
    r => IO.pure(HRes(A), lift_io_result(A, r, make_error)))

# --- compact diagnostic JSON ---------------------------------------------------------

def diag_class_name(cls: DiagClass) -> String:
  match cls:
    case DUsageError{}:
      "usage-error"
    case DOutputOutsideSite{}:
      "output-outside-site"
    case DOutputForbidden{}:
      "output-forbidden"
    case DInputIo{}:
      "input-io"
    case DCompilerArtifactBuild{}:
      "compiler-artifact-build"
    case DCompilerArtifactInvalid{}:
      "compiler-artifact-invalid"
    case DCompilerInvocation{}:
      "compiler-invocation"
    case DOutputSymlink{}:
      "output-symlink"
    case DOutputNotDirectory{}:
      "output-not-directory"
    case DOutputParentNotDirectory{}:
      "output-parent-not-directory"
    case DOutputContainment{}:
      "output-containment"
    case DOutputPathCollision{}:
      "output-path-collision"
    case DOutputLockExists{}:
      "output-lock-exists"
    case DOutputStageInvalid{}:
      "output-stage-invalid"
    case DOutputBackupConflict{}:
      "output-backup-conflict"
    case DOutputBackupInvalid{}:
      "output-backup-invalid"
    case DOutputIo{}:
      "output-io"
    case DOutputPublication{}:
      "output-publication"
    case DHostError{}:
      "host-error"
    case DMissingContentDir{}:
      "missing-content-dir"
    case DSymlinkedEntry{}:
      "symlinked-entry"
    case DNonMdFile{}:
      "non-md-file"
    case DOversizedPage{}:
      "oversized-page"
    case DInvalidUtf8{}:
      "invalid-utf8"
    case DMalformedFrontmatter{}:
      "malformed-frontmatter"
    case DUnknownFrontmatterKey{}:
      "unknown-frontmatter-key"
    case DDuplicateFrontmatterKey{}:
      "duplicate-frontmatter-key"
    case DDuplicateId{}:
      "duplicate-id"
    case DDuplicateIdCase{}:
      "duplicate-id-case"
    case DDanglingParent{}:
      "dangling-parent"
    case DSelfParent{}:
      "self-parent"
    case DParentCycle{}:
      "parent-cycle"
    case DLinkQuery{}:
      "link-query"
    case DLinkRootEscape{}:
      "link-root-escape"
    case DLinkNonexistentPage{}:
      "link-nonexistent-page"
    case DLinkMalformedPercent{}:
      "link-malformed-percent"
    case DLinkInvalidPercentUtf8{}:
      "link-invalid-percent-utf8"


# JSON string escaping is the exact well-formed JSON.stringify-compatible
# escaping implemented by the wave-1 hostjson library.
def diag_json_string(+s: String) -> String:
  HJ.hostjson_string(s)

def diag_json_maybe_string_gate(+none_text: String, m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      none_text
    case Some{+s}:
      diag_json_string(s)

def diag_json_maybe_string(m: Maybe<&2, String>) -> String:
  diag_json_maybe_string_gate("null", m)

def diag_json_maybe_nat(m: Maybe<&2, Nat>) -> String:
  match m:
    case None{}:
      "null"
    case Some{+n}:
      Nat.show(n)

def diag_json_span(s: HostSpan) -> String:
  match s:
    case HostSpan{+start, +end}:
      "{\"start\":" ++ U32.show(start) ++ ",\"end\":" ++ U32.show(end) ++ "}"

def diag_json_maybe_span(m: Maybe<&2, HostSpan>) -> String:
  match m:
    case None{}:
      "null"
    case Some{+s}:
      diag_json_span(s)

# Exact diagnostic object key order:
# class,path,page,line,column,target,span,message.
def diag_json(d: HostDiag) -> String:
  match d:
    case HostDiag{+cls, path, page, line, column, target, span, +message}:
      "{\"class\":" ++ diag_json_string(diag_class_name(cls)) ++
      ",\"path\":" ++ diag_json_maybe_string(path) ++
      ",\"page\":" ++ diag_json_maybe_string(page) ++
      ",\"line\":" ++ diag_json_maybe_nat(line) ++
      ",\"column\":" ++ diag_json_maybe_nat(column) ++
      ",\"target\":" ++ diag_json_maybe_string(target) ++
      ",\"span\":" ++ diag_json_maybe_span(span) ++
      ",\"message\":" ++ diag_json_string(message) ++
      "}"

def diag_json_list(xs: List<&2, HostDiag>) -> String:
  match xs:
    case Nil{}:
      ""
    case +h <> Nil{}:
      diag_json(h)
    case +h <> t:
      diag_json(h) ++ "," ++ diag_json_list(t)

# Compact top-level envelope, exactly one trailing newline is added by
# failure_payload_bytes rather than embedded in the string form here.
def failure_payload_text(+diagnostics: List<&2, HostDiag>) -> String:
  "{\"version\":1,\"status\":\"error\",\"diagnostics\":[" ++
    diag_json_list(diagnostics) ++ "]}\n"

def failure_payload_bytes_gate(+text: String, m: Maybe<&2, Bytes()>) -> Bytes():
  match m:
    case Some{+bytes}:
      bytes
    case None{}:
      utf8_bytes_or_empty(text)

def failure_payload_bytes(f: HostFailure) -> Bytes():
  match f:
    case HostFailure{exit_code, +diagnostics}:
      +text = failure_payload_text(diagnostics)
      failure_payload_bytes_gate(text, encode_string_bytes(text))

def host_failure_exit(f: HostFailure) -> U32:
  match f:
    case HostFailure{+exit_code, diagnostics}:
      exit_code

# Write the exact diagnostic bytes, then terminate with the diagnostic exit
# code.  stderr write failure cannot be usefully reported on the same stream;
# like the reference host's best-effort stream write, the original exit code is
# preserved.
def write_failure_finish(+exit_code: U32, r: Result<&1, &1, HostIOError(), Unit>) -> IO(Unit):
  match r:
    case Done{value}:
      IO.exit(exit_code)
    case Fail{error}:
      IO.exit(exit_code)

def write_failure(+f: HostFailure) -> IO(Unit):
  +exit_code = host_failure_exit(f)
  IO.bind(HUnitResult(), Unit, HFS.write_stderr_bytes(failure_payload_bytes(f)),
    r => write_failure_finish(exit_code, r))
