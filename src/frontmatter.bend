import Base
import ../engine/src/text.bend as Text

# Frontmatter parsing — the closed grammar of docs/v0-spec.md §3.
#
#   - Optional.  If present it is the very first thing in the file: a line
#     exactly "---", then zero or more "key: value" lines, then a closing
#     line exactly "---".
#   - Keys: lowercase ASCII letters and hyphens only.
#   - Values: the remainder of the line after "key:", trimmed.
#   - Closed key set: title / parent / status.  Any other key is an error.
#   - Duplicate keys, unknown keys, and malformed delimiter or line
#     structure are all errors — fail-loud, never warnings.
#
# The parser is a total function: errors are values, never exceptions, and
# every error carries a 1-based line and column.  The "file" component of a
# diagnostic is supplied by the caller (it knows the page id); line/col are
# relative to the start of the source.
#
# Scope: this stage is syntactic plus the per-key value constraints the
# spec states in the key table (title non-empty, status in
# {published, draft}).  A non-empty `parent` value is enforced here (an
# empty string can never name a page id); whether that parent resolves to
# an existing page and creates no cycle is the graph validator's job.

# Boolean eliminator (the pattern every module uses: a match cannot
# scrutinize a computed Bool, so branching routes through this helper
# whose parameter is matched).
def ifs(-A: Type, z: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match z:
    case True{}:
      yes(Unit{})
    case False{}:
      no(Unit{})

type FmStatus is Data:
  FmPublished{}
  FmDraft{}

# What a page's frontmatter says.  title/parent absent = None; status
# absent = FmPublished (the spec's defaults).
type FmMeta is Data:
  FmMeta{title: Maybe<&2, String>, parent: Maybe<&2, String>, status: FmStatus}

# The diagnostic classes of the closed grammar, one per spec rule:
# malformed delimiter/line structure, unknown key, duplicate key, status
# value outside {published, draft}, and an empty value where a non-empty
# one is required.
type FmErrKind is Data:
  FmMalformed{}
  FmUnknownKey{}
  FmDupKey{}
  FmBadStatus{}
  FmEmptyValue{}

type FmError is Data:
  FmError{kind: FmErrKind, line: Nat, col: Nat, detail: String}

# Parse result: the metadata when a well-formed block was found, the body
# (everything after the closing "---", or the whole input when no block is
# present), and every error found in line order.  A block with errors
# reports meta = None; the caller treats any non-empty errors as fatal.
type FmResult is Data:
  FmResult{meta: Maybe<&2, FmMeta>, body: String, errors: List<&2, FmError>}

# --- small factories (constructors inside complex expressions can fail
# inference, so construction routes through tiny typed helpers) -----------

def fm_err(kind: FmErrKind, +line: Nat, +col: Nat, +detail: String) -> FmError:
  FmError{kind, line, col, detail}

def fm_some_str(+s: String) -> Maybe<&2, String>:
  Some{s}

def fm_st_some(st: FmStatus) -> Maybe<&2, FmStatus>:
  Some{st}

# Placeholder recorded for a bad status value: it only marks the key as
# seen so a repeat reports a duplicate; the error already recorded makes
# the value unreachable.
def fm_status_mark() -> Maybe<&2, FmStatus>:
  Some{FmPublished{}}

def fm_meta_some(+m: FmMeta) -> Maybe<&2, FmMeta>:
  Some{m}

def fm_no_meta() -> Maybe<&2, FmMeta>:
  None{}

def fm_nat_some(+n: Nat) -> Maybe<&2, Nat>:
  Some{n}

def fm_hit(+key: String, +rest: String) -> FmKeyScan:
  FmKeyHit{key, rest}

def fm_scan_ok(acc: FmAcc, +line: Nat) -> FmScan:
  FmScan{acc, fm_nat_some(line), line}

def fm_scan_unclosed(acc: FmAcc, +line: Nat) -> FmScan:
  FmScan{acc, None{}, line}

# --- scanning state --------------------------------------------------------

# Accumulator for the key/value lines of a block.  Errors accumulate
# newest-first and are reversed once at the end.
type FmAcc is Data:
  FmAcc{title: Maybe<&2, String>, parent: Maybe<&2, String>,
    status: Maybe<&2, FmStatus>, errs: List<&2, FmError>}

def fm_acc_new(t: Maybe<&2, String>, p: Maybe<&2, String>,
  s: Maybe<&2, FmStatus>, e: List<&2, FmError>) -> FmAcc:
  FmAcc{t, p, s, e}

def fm_acc_blank() -> FmAcc:
  fm_acc_new(None{}, None{}, None{}, [])

# The outcome of scanning the block interior: `close` is the 1-based line
# of the closing delimiter when found; `last` is the last line consumed
# (the file's end when unclosed), used to position the unclosed-block
# diagnostic.
type FmScan is Data:
  FmScan{acc: FmAcc, close: Maybe<&2, Nat>, last: Nat}

def fm_push_err(acc: FmAcc, e: FmError) -> FmAcc:
  match acc:
    case FmAcc{title, parent, status, errs}:
      fm_acc_new(title, parent, status, e <> errs)

# --- key line parsing ------------------------------------------------------

# A "key:" line is a run of [a-z-] characters terminated by ':'.  The scan
# returns the split (key text, rest of line) or the 1-based column of the
# offending character; end-of-line means a missing colon, reported at the
# column where ':' was expected.
type FmKeyScan is Data:
  FmKeyHit{key: String, rest: String}
  FmKeyBad{col: Nat}

def fm_key_char(+c: Char) -> Bool:
  Bool.or(Char.is_eq(c, '-'), Char.is_lower(c))

def fm_key_go(s: String, +acc: String, +col: Nat) -> FmKeyScan:
  match s:
    case SNil{}:
      FmKeyBad{col}
    case SCon{':', t}:
      fm_hit(String.reverse(acc), t)
    case SCon{+h, t}:
      ifs(FmKeyScan, fm_key_char(h),
        u => fm_key_go(t, SCon{h, acc}, Nat.add(col, 1n)),
        u => FmKeyBad{col})

def fm_scan_key(+line: String) -> FmKeyScan:
  fm_key_go(line, "", 1n)

# --- the closed key set ----------------------------------------------------

type FmKey is Data:
  FmKTitle{}
  FmKParent{}
  FmKStatus{}
  FmKUnknown{key: String}

def fm_key_some(+key: String) -> FmKey:
  FmKUnknown{key}

def fm_key_of(+key: String) -> FmKey:
  ifs(FmKey, String.eq(key, "title"),
    u => FmKTitle{},
    u => ifs(FmKey, String.eq(key, "parent"),
      v => FmKParent{},
      v => ifs(FmKey, String.eq(key, "status"),
        w => FmKStatus{},
        w => fm_key_some(key))))

# --- per-key application ---------------------------------------------------

def fm_set_title(acc: FmAcc, +value: String, +line: Nat) -> FmAcc:
  match acc:
    case FmAcc{title, parent, status, errs}:
      match title:
        case Some{+old}:
          fm_acc_new(fm_some_str(old), parent, status,
            fm_err(FmDupKey{}, line, 1n, "title") <> errs)
        case None{}:
          fm_acc_new(fm_some_str(value), parent, status, errs)

def fm_set_parent(acc: FmAcc, +value: String, +line: Nat) -> FmAcc:
  match acc:
    case FmAcc{title, parent, status, errs}:
      match parent:
        case Some{+old}:
          fm_acc_new(title, fm_some_str(old), status,
            fm_err(FmDupKey{}, line, 1n, "parent") <> errs)
        case None{}:
          fm_acc_new(title, fm_some_str(value), status, errs)

def fm_set_status(acc: FmAcc, st: FmStatus, +line: Nat) -> FmAcc:
  match acc:
    case FmAcc{title, parent, status, errs}:
      match status:
        case Some{old}:
          fm_acc_new(title, parent, fm_st_some(old),
            fm_err(FmDupKey{}, line, 1n, "status") <> errs)
        case None{}:
          fm_acc_new(title, parent, fm_st_some(st), errs)

# A status line holding an unrecognized value: BadStatus when the key is
# fresh (the key is still marked seen), DupKey on a repeat.
def fm_apply_status_bad(acc: FmAcc, +line: Nat) -> FmAcc:
  match acc:
    case FmAcc{title, parent, status, errs}:
      match status:
        case Some{old}:
          fm_acc_new(title, parent, fm_st_some(old),
            fm_err(FmDupKey{}, line, 1n, "status") <> errs)
        case None{}:
          fm_acc_new(title, parent, fm_status_mark(),
            fm_err(FmBadStatus{}, line, 1n, "status") <> errs)

def fm_apply_status(+acc: FmAcc, +value: String, +line: Nat) -> FmAcc:
  ifs(FmAcc, String.eq(value, "published"),
    u => fm_set_status(acc, FmPublished{}, line),
    u => ifs(FmAcc, String.eq(value, "draft"),
      v => fm_set_status(acc, FmDraft{}, line),
      v => fm_apply_status_bad(acc, line)))

# title and parent require non-empty values.  The value is still recorded,
# so a repeat reports a duplicate as the spec requires.
def fm_err_if_empty(+acc: FmAcc, +value: String, +line: Nat) -> FmAcc:
  ifs(FmAcc, String.is_empty(value),
    u => fm_push_err(acc, fm_err(FmEmptyValue{}, line, 1n, "empty value")),
    u => acc)

def fm_apply_key(+acc: FmAcc, key: FmKey, +value: String, +line: Nat) -> FmAcc:
  match key:
    case FmKTitle{}:
      fm_err_if_empty(fm_set_title(acc, value, line), value, line)
    case FmKParent{}:
      fm_err_if_empty(fm_set_parent(acc, value, line), value, line)
    case FmKStatus{}:
      fm_apply_status(acc, value, line)
    case FmKUnknown{+key}:
      fm_push_err(acc, fm_err(FmUnknownKey{}, line, 1n, key))

# One interior line of the block: split "key: value" then apply it.  An
# empty key (a leading ':') is malformed rather than an unknown key.
def fm_entry_keyed.fin(+acc: FmAcc, +key: String, +rest: String, +line: Nat, empty: Bool) -> FmAcc:
  match empty:
    case True{}:
      fm_push_err(acc, fm_err(FmMalformed{}, line, 1n, key))
    case False{}:
      fm_apply_key(acc, fm_key_of(key), String.trim(rest), line)

def fm_entry_keyed(+acc: FmAcc, +key: String, +rest: String, +line: Nat) -> FmAcc:
  fm_entry_keyed.fin(acc, key, rest, line, String.is_empty(key))

def fm_entry_go(+acc: FmAcc, +line_text: String, +line: Nat, ks: FmKeyScan) -> FmAcc:
  match ks:
    case FmKeyHit{+key, +rest}:
      fm_entry_keyed(acc, key, rest, line)
    case FmKeyBad{+col}:
      fm_push_err(acc, fm_err(FmMalformed{}, line, col, line_text))

def fm_entry(+acc: FmAcc, +line_text: String, +line: Nat) -> FmAcc:
  fm_entry_go(acc, line_text, line, fm_scan_key(line_text))

# --- block scan -------------------------------------------------------------

# The delimiter is a line exactly "---" (three hyphens, nothing else).
def fm_is_close(+line: String) -> Bool:
  String.eq(line, "---")

def fm_scan_go(lines: List<&2, String>, +line: Nat, +acc: FmAcc) -> FmScan:
  match lines:
    case Nil{}:
      fm_scan_unclosed(acc, Nat.sub(line, 1n))
    case +h <> t:
      ifs(FmScan, fm_is_close(h),
        u => fm_scan_ok(acc, line),
        u => fm_scan_go(t, Nat.add(line, 1n), fm_entry(acc, h, line)))

# --- body extraction ---------------------------------------------------------

# Drop one line: everything up to and including the next '\n'; a line
# without a terminator drops to end of input.
def fm_drop_line(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{'\n', t}:
      t
    case SCon{h, t}:
      fm_drop_line(t)

# Drop n lines.  The Nat parameter decreases, so the recursion is
# structural even though the string argument shrinks freely.
def fm_drop_lines(+n: Nat, s: String) -> String:
  match n:
    case 0n:
      s
    case 1n+p:
      fm_drop_lines(p, fm_drop_line(s))

# --- top level ----------------------------------------------------------------

# Build the FmMeta from a clean accumulator.  Only called when the error
# list is empty, so a recorded status is always a recognized value.
def fm_meta_of(+title: Maybe<&2, String>, +parent: Maybe<&2, String>, status: Maybe<&2, FmStatus>) -> FmMeta:
  match status:
    case None{}:
      FmMeta{title, parent, FmPublished{}}
    case Some{+st}:
      FmMeta{title, parent, st}

def fm_result_ok(+meta: FmMeta, +body: String) -> FmResult:
  FmResult{fm_meta_some(meta), body, []}

def fm_result_errs(+body: String, errs: List<&2, FmError>) -> FmResult:
  FmResult{fm_no_meta(), body, errs}

# Assemble the result once the scan finished.  On success (closing line
# found, no errors) meta is present and body is everything after the
# closing line.  On any error meta is None and errors are reported in line
# order; a missing closing delimiter is a malformed-structure error
# positioned at the last line consumed.
def fm_errs_rev(+errs: List<&2, FmError>) -> List<&2, FmError>:
  List.reverse(&2, FmError, errs)

def fm_unclosed_tail(+last: Nat) -> List<&2, FmError>:
  fm_err(FmMalformed{}, last, 1n, "unclosed frontmatter block") <> []

def fm_unclosed_errs(+src: String, +errs: List<&2, FmError>, +last: Nat) -> FmResult:
  fm_result_errs(src,
    List.append(&2, FmError, fm_errs_rev(errs), fm_unclosed_tail(last)))

# es arrives as a parameter, so matching it here is a plain scrutinee
# (match order follows binder order; routing through a helper keeps the
# outer matches in destructure order).
def fm_finish_line(+src: String, +title: Maybe<&2, String>, +parent: Maybe<&2, String>,
  +status: Maybe<&2, FmStatus>, +line: Nat, es: List<&2, FmError>) -> FmResult:
  match es:
    case Nil{}:
      fm_result_ok(fm_meta_of(title, parent, status), fm_drop_lines(line, src))
    case +h <> +t:
      fm_result_errs(src, fm_errs_rev(h <> t))

def fm_finish(+src: String, scan: FmScan) -> FmResult:
  match scan:
    case FmScan{acc, close, +last}:
      match acc:
        case FmAcc{+title, +parent, +status, +errs}:
          match close:
            case Some{+line}:
              fm_finish_line(src, title, parent, status, line, errs)
            case None{}:
              fm_unclosed_errs(src, errs, last)

# A file has a frontmatter block iff its first line is exactly "---".
# Anything else (including "---" with surrounding whitespace) is not
# frontmatter, and the whole file is body.
def fm_open.fin(+src: String, rest: List<&2, String>, is_open: Bool) -> FmResult:
  match is_open:
    case True{}:
      fm_finish(src, fm_scan_go(rest, 2n, fm_acc_blank()))
    case False{}:
      FmResult{fm_no_meta(), src, []}

def fm_open(+src: String, lines: List<&2, String>) -> FmResult:
  match lines:
    case Nil{}:
      FmResult{fm_no_meta(), src, []}
    case +h <> t:
      fm_open.fin(src, t, fm_is_close(h))

# Parse a page source.  Newlines are normalized first so "---" detection
# and line numbers are consistent across LF/CRLF/CR inputs; the returned
# body is the normalized remainder.
def parse_frontmatter(+source: String) -> FmResult:
  +norm = Text.normalize_newlines(source)
  fm_open(norm, String.lines(norm))
