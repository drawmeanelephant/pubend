import Base
import ../engine/src/text.bend as Text

# Percent decoding of internal-link path text (docs/v0-spec.md §5.2).
#
# Percent encoding is byte-oriented even though Bend String is already a
# Unicode scalar sequence.  This decoder therefore treats contiguous %XX
# triplets as byte input that must form well-formed UTF-8, while ordinary
# non-'%' characters are already decoded text and pass through as themselves.
# A literal character never joins a pending percent-encoded UTF-8 sequence:
# "%E2x%82%AC" is invalid because the percent bytes are incomplete before the
# literal x.  Decoding happens exactly once; in particular, %25 produces the
# text character '%' and is never reinterpreted as a new escape introducer.

def ifs(-A: Type, z: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match z:
    case True{}:
      yes(Unit{})
    case False{}:
      no(Unit{})

type PercentResult is Data:
  PercentOk{text: String}
  PercentMalformed{}
  PercentInvalidUtf8{}

type PercentError is Data:
  PdMalformed{}
  PdInvalidUtf8{}

type PdState is Data:
  PdState{outrev: String, bytesrev: List<&2, U32>, error: Maybe<&2, PercentError>}

# --- small factories ---------------------------------------------------------

def p_ok(+text: String) -> PercentResult:
  PercentOk{text}

def p_malformed() -> PercentResult:
  PercentMalformed{}

def p_invalid() -> PercentResult:
  PercentInvalidUtf8{}

def p_err_malformed() -> Maybe<&2, PercentError>:
  Some{PdMalformed{}}

def p_err_invalid() -> Maybe<&2, PercentError>:
  Some{PdInvalidUtf8{}}

def p_no_error() -> Maybe<&2, PercentError>:
  None{}

def pd_state(outrev: String, bytesrev: List<&2, U32>, error: Maybe<&2, PercentError>) -> PdState:
  PdState{outrev, bytesrev, error}

def pd_state_new() -> PdState:
  pd_state("", Nil{}, p_no_error())

def some_u32(+x: U32) -> Maybe<&2, U32>:
  Some{x}

def no_u32() -> Maybe<&2, U32>:
  None{}

# --- hex triplet parsing -------------------------------------------------------

def hex_val(c: Char) -> Maybe<&2, U32>:
  +x = Char.to_u32(c)
  ifs(Maybe<&2, U32>, Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57)),
    u => some_u32(U32.sub(x, 48)),
    u => ifs(Maybe<&2, U32>, Bool.and(U32.is_ge(x, 65), U32.is_le(x, 70)),
      v => some_u32(U32.sub(x, 55)),
      v => ifs(Maybe<&2, U32>, Bool.and(U32.is_ge(x, 97), U32.is_le(x, 102)),
        w => some_u32(U32.sub(x, 87)),
        w => no_u32())))

def hex_pair_go(hi: Maybe<&2, U32>, lo: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match hi:
    case None{}:
      no_u32()
    case Some{+h}:
      match lo:
        case None{}:
          no_u32()
        case Some{+l}:
          some_u32(U32.add(U32.mul(h, 16), l))

def hex_pair(+a: Char, +b: Char) -> Maybe<&2, U32>:
  hex_pair_go(hex_val(a), hex_val(b))

# --- UTF-8 decoding of complete percent-byte chunks ------------------------------

type Utf8Result is Data:
  Utf8Ok{text: String}
  Utf8Invalid{}

type Utf8Class is Data:
  U8Ascii{}
  U8Two{}
  U8Three{}
  U8Four{}
  U8Bad{}

type Utf8Work is Data:
  U8Next{xs: List<&2, U32>}
  U8Classed{class: Utf8Class, b: U32, xs: List<&2, U32>}

def u8_ok(+text: String) -> Utf8Result:
  Utf8Ok{text}

def u8_bad() -> Utf8Result:
  Utf8Invalid{}

def u8_cons_char(+cp: U32, rest: Utf8Result) -> Utf8Result:
  match rest:
    case Utf8Invalid{}:
      u8_bad()
    case Utf8Ok{+text}:
      u8_ok(SCon{Char.from_u32(cp), text})

def u8_cont(+b: U32) -> Bool:
  Bool.and(U32.is_ge(b, 128), U32.is_le(b, 191))

def u8_cont_val(+b: U32) -> U32:
  U32.sub(b, 128)

def u8_class_of(+b: U32) -> Utf8Class:
  ifs(Utf8Class, U32.is_le(b, 127),
    u => U8Ascii{},
    u => ifs(Utf8Class, Bool.and(U32.is_ge(b, 194), U32.is_le(b, 223)),
      v => U8Two{},
      v => ifs(Utf8Class, Bool.and(U32.is_ge(b, 224), U32.is_le(b, 239)),
        w => U8Three{},
        w => ifs(Utf8Class, Bool.and(U32.is_ge(b, 240), U32.is_le(b, 244)),
          x => U8Four{},
          x => U8Bad{}))))

def u8_code2(+b: U32, +b2: U32) -> U32:
  U32.add(U32.shln(U32.sub(b, 192), 6n), u8_cont_val(b2))

def u8_code3(+b: U32, +b2: U32, +b3: U32) -> U32:
  U32.add(U32.shln(U32.sub(b, 224), 12n),
    U32.add(U32.shln(u8_cont_val(b2), 6n), u8_cont_val(b3)))

def u8_code4(+b: U32, +b2: U32, +b3: U32, +b4: U32) -> U32:
  U32.add(U32.shln(U32.sub(b, 240), 18n),
    U32.add(U32.shln(u8_cont_val(b2), 12n),
      U32.add(U32.shln(u8_cont_val(b3), 6n), u8_cont_val(b4))))

# RFC 3629 constraints: no overlong forms, no UTF-16 surrogates, and no scalar
# above U+10FFFF.  These are expressed as tighter second-byte ranges for E0,
# ED, F0, and F4 rather than as a post-hoc range repair.
def u8_valid2(+b: U32, +b2: U32) -> Bool:
  u8_cont(b2)

def u8_valid3(+b: U32, +b2: U32, +b3: U32) -> Bool:
  Bool.and(u8_cont(b2), Bool.and(u8_cont(b3),
    Bool.and(Bool.or(U32.is_ne(b, 224), U32.is_ge(b2, 160)),
      Bool.or(U32.is_ne(b, 237), U32.is_le(b2, 159)))))

def u8_valid4(+b: U32, +b2: U32, +b3: U32, +b4: U32) -> Bool:
  Bool.and(u8_cont(b2), Bool.and(u8_cont(b3), Bool.and(u8_cont(b4),
    Bool.and(Bool.or(U32.is_ne(b, 240), U32.is_ge(b2, 144)),
      Bool.or(U32.is_ne(b, 244), U32.is_le(b2, 143))))))

def u8_fin2(+b: U32, +b2: U32, valid: Bool, rest: Utf8Result) -> Utf8Result:
  match valid:
    case False{}:
      u8_bad()
    case True{}:
      u8_cons_char(u8_code2(b, b2), rest)

def u8_fin3(+b: U32, +b2: U32, +b3: U32, valid: Bool, rest: Utf8Result) -> Utf8Result:
  match valid:
    case False{}:
      u8_bad()
    case True{}:
      u8_cons_char(u8_code3(b, b2, b3), rest)

def u8_fin4(+b: U32, +b2: U32, +b3: U32, +b4: U32, valid: Bool, rest: Utf8Result) -> Utf8Result:
  match valid:
    case False{}:
      u8_bad()
    case True{}:
      u8_cons_char(u8_code4(b, b2, b3, b4), rest)

# One fueled dispatcher handles both "classify the next byte" and "decode a
# classified sequence" work items.  This is the standard Bend replacement for
# mutual recursion; every step spends fuel and each decoded sequence consumes
# at least one input byte.
def utf8_decode_work(+fuel: Nat, work: Utf8Work) -> Utf8Result:
  match fuel:
    case 0n:
      u8_bad()
    case 1n++f:
      match work:
        case U8Next{xs}:
          match xs:
            case Nil{}:
              u8_ok("")
            case +b <> t:
              utf8_decode_work(f, U8Classed{u8_class_of(b), b, t})
        case U8Classed{class, +b, xs}:
          match class:
            case U8Ascii{}:
              u8_cons_char(b, utf8_decode_work(f, U8Next{xs}))
            case U8Two{}:
              match xs:
                case Nil{}:
                  u8_bad()
                case +b2 <> rest:
                  u8_fin2(b, b2, u8_valid2(b, b2), utf8_decode_work(f, U8Next{rest}))
            case U8Three{}:
              match xs:
                case Nil{}:
                  u8_bad()
                case +b2 <> t2:
                  match t2:
                    case Nil{}:
                      u8_bad()
                    case +b3 <> rest:
                      u8_fin3(b, b2, b3, u8_valid3(b, b2, b3), utf8_decode_work(f, U8Next{rest}))
            case U8Four{}:
              match xs:
                case Nil{}:
                  u8_bad()
                case +b2 <> t2:
                  match t2:
                    case Nil{}:
                      u8_bad()
                    case +b3 <> t3:
                      match t3:
                        case Nil{}:
                          u8_bad()
                        case +b4 <> rest:
                          u8_fin4(b, b2, b3, b4, u8_valid4(b, b2, b3, b4),
                            utf8_decode_work(f, U8Next{rest}))
            case U8Bad{}:
              u8_bad()

def utf8_decode_fuel() -> Nat:
  4294967295n

def utf8_decode_bytes_go(xs: List<&2, U32>) -> Utf8Result:
  utf8_decode_work(utf8_decode_fuel(), U8Next{xs})

def utf8_decode_bytes(bytesrev: List<&2, U32>) -> Utf8Result:
  utf8_decode_bytes_go(List.reverse(&2, U32, bytesrev))

# --- scanner state ---------------------------------------------------------------

# outrev is the already emitted output in reverse.  Appending a correctly
# ordered piece therefore means prepending reverse(piece) to outrev.
def pd_out_append(+outrev: String, +piece: String) -> String:
  String.append(String.reverse(piece), outrev)

def pd_mark_error(+outrev: String, +bytesrev: List<&2, U32>, error: Maybe<&2, PercentError>,
  e: Maybe<&2, PercentError>) -> PdState:
  match error:
    case Some{x}:
      pd_state(outrev, bytesrev, error)
    case None{}:
      pd_state(outrev, bytesrev, e)

def pd_mark(+st: PdState, e: Maybe<&2, PercentError>) -> PdState:
  match st:
    case PdState{+outrev, +bytesrev, +error}:
      pd_mark_error(outrev, bytesrev, error, e)

def pd_add_percent_open(+outrev: String, bytesrev: List<&2, U32>, +b: U32,
  error: Maybe<&2, PercentError>) -> PdState:
  match error:
    case Some{e}:
      pd_state(outrev, bytesrev, error)
    case None{}:
      pd_state(outrev, b <> bytesrev, p_no_error())

def pd_add_bad_percent(+outrev: String, +bytesrev: List<&2, U32>, error: Maybe<&2, PercentError>) -> PdState:
  match error:
    case Some{x}:
      pd_state(outrev, bytesrev, error)
    case None{}:
      pd_state(outrev, bytesrev, p_err_malformed())

def pd_add_percent_maybe(+outrev: String, bytesrev: List<&2, U32>, byte: Maybe<&2, U32>,
  error: Maybe<&2, PercentError>) -> PdState:
  match byte:
    case None{}:
      pd_add_bad_percent(outrev, bytesrev, error)
    case Some{+b}:
      pd_add_percent_open(outrev, bytesrev, b, error)

def pd_add_percent(st: PdState, byte: Maybe<&2, U32>) -> PdState:
  match st:
    case PdState{+outrev, +bytesrev, +error}:
      pd_add_percent_maybe(outrev, bytesrev, byte, error)

def pd_char_flushed(+outrev: String, bytesrev: List<&2, U32>, +c: Char, decoded: Utf8Result) -> PdState:
  match decoded:
    case Utf8Invalid{}:
      pd_state(outrev, bytesrev, p_err_invalid())
    case Utf8Ok{+chunk}:
      pd_state(pd_out_append(pd_out_append(outrev, chunk), Text.char_string(c)), Nil{}, p_no_error())

def pd_add_char_plain(+outrev: String, +bytesrev: List<&2, U32>, +c: Char) -> PdState:
  pd_char_flushed(outrev, bytesrev, c, utf8_decode_bytes(bytesrev))

def pd_add_char_error(+outrev: String, +bytesrev: List<&2, U32>, +c: Char,
  error: Maybe<&2, PercentError>) -> PdState:
  match error:
    case Some{e}:
      pd_state(outrev, bytesrev, error)
    case None{}:
      pd_add_char_plain(outrev, bytesrev, c)

def pd_add_char(st: PdState, +c: Char) -> PdState:
  match st:
    case PdState{+outrev, +bytesrev, +error}:
      pd_add_char_error(outrev, bytesrev, c, error)

def pd_scan_hex(+st: PdState, +a: Char, +b: Char) -> PdState:
  pd_add_percent(st, hex_pair(a, b))

# The scan is structurally recursive over the input string.  Once an error is
# recorded the state stops changing; scanning the remaining input is harmless
# and keeps the function total without exceptions.
def pd_scan(s: String, st: PdState) -> PdState:
  match s:
    case SNil{}:
      st
    case SCon{'%', t1}:
      match t1:
        case SNil{}:
          pd_mark(st, p_err_malformed())
        case SCon{+a, t2}:
          match t2:
            case SNil{}:
              pd_mark(st, p_err_malformed())
            case SCon{+b, t3}:
              pd_scan(t3, pd_scan_hex(st, a, b))
    case SCon{+h, t}:
      pd_scan(t, pd_add_char(st, h))

def pd_error_result(e: PercentError) -> PercentResult:
  match e:
    case PdMalformed{}:
      p_malformed()
    case PdInvalidUtf8{}:
      p_invalid()

def pd_finish_flushed(+outrev: String, decoded: Utf8Result) -> PercentResult:
  match decoded:
    case Utf8Invalid{}:
      p_invalid()
    case Utf8Ok{+chunk}:
      p_ok(String.reverse(pd_out_append(outrev, chunk)))

def pd_finish_error(+outrev: String, bytesrev: List<&2, U32>, error: Maybe<&2, PercentError>) -> PercentResult:
  match error:
    case Some{+e}:
      pd_error_result(e)
    case None{}:
      pd_finish_flushed(outrev, utf8_decode_bytes(bytesrev))

def pd_finish(st: PdState) -> PercentResult:
  match st:
    case PdState{+outrev, +bytesrev, +error}:
      pd_finish_error(outrev, bytesrev, error)

# Decode one internal-link path portion exactly once.  The caller must split
# literal '#' and '?' delimiters before calling this function.
def percent_decode(+s: String) -> PercentResult:
  pd_finish(pd_scan(s, pd_state_new()))
