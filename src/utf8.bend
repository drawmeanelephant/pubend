import Base

# Strict UTF-8 validation, decoding, and encoding.  This module is pure Bend:
# byte inputs are List<&2, U32>, decoded output is both a Bend String and the
# scalar values needed by byte-oriented host code, and encoding validates every
# Char before emitting exact UTF-8 bytes.
#
# Decode rejects the non-shortest forms, UTF-16 surrogate halves, scalar values
# above U+10FFFF, truncated sequences, and stray or misplaced continuation
# bytes.  It does not replace malformed input with U+FFFD.  The failure offset
# is the byte offset of the sequence whose lead byte was being decoded.  Encode
# rejects forged Char values outside the Unicode scalar range; its failure
# offset is a character offset within the input String.

def ifs(-A: Type, z: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match z:
    case True{}:
      yes(Unit{})
    case False{}:
      no(Unit{})

type Utf8DecodeResult is Data:
  Utf8DecodeOk{text: String, codepoints: List<&2, U32>}
  Utf8DecodeInvalid{offset: Nat}

type Utf8EncodeResult is Data:
  Utf8EncodeOk{bytes: List<&2, U32>}
  Utf8EncodeInvalid{offset: Nat, code: U32}

type Utf8Class is Data:
  U8Ascii{}
  U8Two{}
  U8Three{}
  U8Four{}
  U8Bad{}

type Utf8Work is Data:
  U8Next{xs: List<&2, U32>, pos: Nat, rev: List<&2, U32>}
  U8Classed{class: Utf8Class, b: U32, xs: List<&2, U32>, pos: Nat, rev: List<&2, U32>}

type Utf8EncodeClass is Data:
  EncAscii{}
  EncTwo{}
  EncThree{}
  EncFour{}
  EncBad{}

type Utf8EncodeWork is Data:
  U8EncNext{s: String, pos: Nat, rev: List<&2, U32>}
  U8EncClassed{class: Utf8EncodeClass, cp: U32, s: String, pos: Nat, rev: List<&2, U32>}

# --- small factories ---------------------------------------------------------

def utf8_decode_ok(+text: String, +codepoints: List<&2, U32>) -> Utf8DecodeResult:
  Utf8DecodeOk{text, codepoints}

def utf8_decode_invalid(offset: Nat) -> Utf8DecodeResult:
  Utf8DecodeInvalid{offset}

def utf8_encode_ok(+bytes: List<&2, U32>) -> Utf8EncodeResult:
  Utf8EncodeOk{bytes}

def utf8_encode_invalid(offset: Nat, +code: U32) -> Utf8EncodeResult:
  Utf8EncodeInvalid{offset, code}

def u8_next(xs: List<&2, U32>, pos: Nat, rev: List<&2, U32>) -> Utf8Work:
  U8Next{xs, pos, rev}

def u8_classed(class: Utf8Class, +b: U32, xs: List<&2, U32>, pos: Nat, rev: List<&2, U32>) -> Utf8Work:
  U8Classed{class, b, xs, pos, rev}

def u8enc_next(s: String, pos: Nat, rev: List<&2, U32>) -> Utf8EncodeWork:
  U8EncNext{s, pos, rev}

def u8enc_classed(class: Utf8EncodeClass, +cp: U32, s: String, pos: Nat, rev: List<&2, U32>) -> Utf8EncodeWork:
  U8EncClassed{class, cp, s, pos, rev}

def enc_cls_ascii() -> Utf8EncodeClass:
  EncAscii{}

def enc_cls_two() -> Utf8EncodeClass:
  EncTwo{}

def enc_cls_three() -> Utf8EncodeClass:
  EncThree{}

def enc_cls_four() -> Utf8EncodeClass:
  EncFour{}

def enc_cls_bad() -> Utf8EncodeClass:
  EncBad{}

# --- strict decoding -----------------------------------------------------------

def utf8_cps_to_string(cps: List<&2, U32>) -> String:
  match cps:
    case Nil{}:
      ""
    case +cp <> t:
      SCon{Char.from_u32(cp), utf8_cps_to_string(t)}

def utf8_decode_finish(rev: List<&2, U32>) -> Utf8DecodeResult:
  +cps = List.reverse(&2, U32, rev)
  utf8_decode_ok(utf8_cps_to_string(cps), cps)

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
# above U+10FFFF.  These are tighter second-byte ranges for E0, ED, F0, and F4,
# not a post-hoc repair of an already accepted sequence.
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

# One fueled dispatcher handles "classify the next byte" and "decode the
# classified sequence" work items, the standard Bend replacement for mutual
# recursion.  Fuel is derived from the input length below, so exhaustion is an
# unreachable totality fallback rather than a hidden input-size limit.
def utf8_decode_work(+fuel: Nat, work: Utf8Work) -> Utf8DecodeResult:
  match fuel:
    case 0n:
      utf8_decode_invalid(0n)
    case 1n++f:
      match work:
        case U8Next{xs, pos, rev}:
          match xs:
            case Nil{}:
              utf8_decode_finish(rev)
            case +b <> t:
              utf8_decode_work(f, u8_classed(u8_class_of(b), b, t, pos, rev))
        case U8Classed{class, +b, xs, +pos, rev}:
          match class:
            case U8Ascii{}:
              utf8_decode_work(f, u8_next(xs, Nat.add(pos, 1n), b <> rev))
            case U8Two{}:
              match xs:
                case Nil{}:
                  utf8_decode_invalid(pos)
                case +b2 <> rest:
                  ifs(Utf8DecodeResult, u8_valid2(b, b2),
                    u => utf8_decode_work(f,
                      u8_next(rest, Nat.add(pos, 2n), u8_code2(b, b2) <> rev)),
                    u => utf8_decode_invalid(pos))
            case U8Three{}:
              match xs:
                case Nil{}:
                  utf8_decode_invalid(pos)
                case +b2 <> t2:
                  match t2:
                    case Nil{}:
                      utf8_decode_invalid(pos)
                    case +b3 <> rest:
                      ifs(Utf8DecodeResult, u8_valid3(b, b2, b3),
                        u => utf8_decode_work(f,
                          u8_next(rest, Nat.add(pos, 3n), u8_code3(b, b2, b3) <> rev)),
                        u => utf8_decode_invalid(pos))
            case U8Four{}:
              match xs:
                case Nil{}:
                  utf8_decode_invalid(pos)
                case +b2 <> t2:
                  match t2:
                    case Nil{}:
                      utf8_decode_invalid(pos)
                    case +b3 <> t3:
                      match t3:
                        case Nil{}:
                          utf8_decode_invalid(pos)
                        case +b4 <> rest:
                          ifs(Utf8DecodeResult, u8_valid4(b, b2, b3, b4),
                            u => utf8_decode_work(f,
                              u8_next(rest, Nat.add(pos, 4n), u8_code4(b, b2, b3, b4) <> rev)),
                            u => utf8_decode_invalid(pos))
            case U8Bad{}:
              utf8_decode_invalid(pos)

# Every scalar sequence spends at most one U8Next step and one U8Classed step,
# and the final empty input spends one more U8Next step.  The tail-recursive
# count adds two constructor layers per byte directly rather than paying for a
# separate length pass and unary Nat multiplication.
def utf8_decode_fuel_go(xs: List<&2, U32>, acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      utf8_decode_fuel_go(t, 2n+acc)

def utf8_decode_fuel(+bytes: List<&2, U32>) -> Nat:
  utf8_decode_fuel_go(bytes, 1n)

# Strictly decode a byte list.  On success the result carries both text and
# the scalar values in input order; on failure no lossy replacement text is
# produced.
def utf8_decode(+bytes: List<&2, U32>) -> Utf8DecodeResult:
  utf8_decode_work(utf8_decode_fuel(bytes), u8_next(bytes, 0n, Nil{}))

def utf8_valid_result(r: Utf8DecodeResult) -> Bool:
  match r:
    case Utf8DecodeOk{text, codepoints}:
      True{}
    case Utf8DecodeInvalid{offset}:
      False{}

def utf8_valid(bytes: List<&2, U32>) -> Bool:
  utf8_valid_result(utf8_decode(bytes))

# --- validating encoder ----------------------------------------------------------

def utf8_is_surrogate(+cp: U32) -> Bool:
  Bool.and(U32.is_ge(cp, 55296), U32.is_le(cp, 57343))

def utf8_enc_class_of(+cp: U32) -> Utf8EncodeClass:
  ifs(Utf8EncodeClass, utf8_is_surrogate(cp),
    u => enc_cls_bad(),
    u => ifs(Utf8EncodeClass, U32.is_lt(cp, 128),
      v => enc_cls_ascii(),
      v => ifs(Utf8EncodeClass, U32.is_lt(cp, 2048),
        w => enc_cls_two(),
        w => ifs(Utf8EncodeClass, U32.is_lt(cp, 65536),
          x => enc_cls_three(),
          x => ifs(Utf8EncodeClass, U32.is_le(cp, 1114111),
            y => enc_cls_four(),
            y => enc_cls_bad())))))

def enc2_b1(+cp: U32) -> U32:
  U32.add(192, U32.shrn(cp, 6n))

def enc2_b2(+cp: U32) -> U32:
  U32.add(128, U32.and(cp, 63))

def enc3_b1(+cp: U32) -> U32:
  U32.add(224, U32.shrn(cp, 12n))

def enc3_b2(+cp: U32) -> U32:
  U32.add(128, U32.and(U32.shrn(cp, 6n), 63))

def enc3_b3(+cp: U32) -> U32:
  U32.add(128, U32.and(cp, 63))

def enc4_b1(+cp: U32) -> U32:
  U32.add(240, U32.shrn(cp, 18n))

def enc4_b2(+cp: U32) -> U32:
  U32.add(128, U32.and(U32.shrn(cp, 12n), 63))

def enc4_b3(+cp: U32) -> U32:
  U32.add(128, U32.and(U32.shrn(cp, 6n), 63))

def enc4_b4(+cp: U32) -> U32:
  U32.add(128, U32.and(cp, 63))

def utf8_encode_finish(rev: List<&2, U32>) -> Utf8EncodeResult:
  utf8_encode_ok(List.reverse(&2, U32, rev))

# The encoder uses the same fueled work-item shape as the decoder.  The reverse
# accumulator receives each sequence's bytes in reverse order, so one final
# List.reverse produces exact input-order UTF-8 bytes.
def utf8_encode_work(+fuel: Nat, work: Utf8EncodeWork) -> Utf8EncodeResult:
  match fuel:
    case 0n:
      utf8_encode_invalid(0n, 0)
    case 1n++f:
      match work:
        case U8EncNext{s, pos, rev}:
          match s:
            case SNil{}:
              utf8_encode_finish(rev)
            case SCon{h, t}:
              +cp = Char.to_u32(h)
              utf8_encode_work(f, u8enc_classed(utf8_enc_class_of(cp), cp, t, pos, rev))
        case U8EncClassed{class, +cp, s, pos, rev}:
          match class:
            case EncAscii{}:
              utf8_encode_work(f, u8enc_next(s, Nat.add(pos, 1n), cp <> rev))
            case EncTwo{}:
              utf8_encode_work(f, u8enc_next(s, Nat.add(pos, 1n),
                enc2_b2(cp) <> enc2_b1(cp) <> rev))
            case EncThree{}:
              utf8_encode_work(f, u8enc_next(s, Nat.add(pos, 1n),
                enc3_b3(cp) <> enc3_b2(cp) <> enc3_b1(cp) <> rev))
            case EncFour{}:
              utf8_encode_work(f, u8enc_next(s, Nat.add(pos, 1n),
                enc4_b4(cp) <> enc4_b3(cp) <> enc4_b2(cp) <> enc4_b1(cp) <> rev))
            case EncBad{}:
              utf8_encode_invalid(pos, cp)

# Every character spends one U8EncNext step and one U8EncClassed step, and the
# final empty string spends one more U8EncNext step.
def utf8_encode_fuel_go(s: String, acc: Nat) -> Nat:
  match s:
    case SNil{}:
      acc
    case SCon{h, t}:
      utf8_encode_fuel_go(t, 2n+acc)

def utf8_encode_fuel(+text: String) -> Nat:
  utf8_encode_fuel_go(text, 1n)

# Encode a string as exact UTF-8 bytes.  Ordinary Bend strings produced by
# utf8_decode always pass; forged Char values that name UTF-16 surrogates or
# values above U+10FFFF are rejected rather than emitted as invalid bytes.
def utf8_encode(+text: String) -> Utf8EncodeResult:
  utf8_encode_work(utf8_encode_fuel(text), u8enc_next(text, 0n, Nil{}))
