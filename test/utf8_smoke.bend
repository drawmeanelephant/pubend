import Base
import ./harness.bend as H
import ../src/utf8.bend as U

# Smoke tests for strict UTF-8 validation, decoding, and encoding.  Round-trip
# cases cover ASCII, BMP, astral scalar values, embedded NUL, and U+10FFFF.
# Rejection cases cover overlong forms, surrogate halves, truncation at every
# continuation length, misplaced continuation bytes, and U+110000.

def bytes_eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +xh <> xt +yh <> yt:
      Bool.and(U32.is_eq(xh, yh), bytes_eq(xt, yt))
    case x y:
      False{}

def encode_matches(r: U.Utf8EncodeResult, want: List<&2, U32>) -> Bool:
  match r:
    case U.Utf8EncodeOk{+bytes}:
      bytes_eq(bytes, want)
    case U.Utf8EncodeInvalid{offset, code}:
      False{}

def encode_is_invalid(r: U.Utf8EncodeResult) -> Bool:
  match r:
    case U.Utf8EncodeOk{bytes}:
      False{}
    case U.Utf8EncodeInvalid{offset, code}:
      True{}

def decode_invalid_offset_matches(r: U.Utf8DecodeResult, want: Nat) -> Bool:
  match r:
    case U.Utf8DecodeOk{text, codepoints}:
      False{}
    case U.Utf8DecodeInvalid{offset}:
      Nat.is_eq(offset, want)

def encode_invalid_offset_matches(r: U.Utf8EncodeResult, want: Nat) -> Bool:
  match r:
    case U.Utf8EncodeOk{bytes}:
      False{}
    case U.Utf8EncodeInvalid{offset, code}:
      Nat.is_eq(offset, want)

def decode_roundtrip_matches(r: U.Utf8DecodeResult, +want_text: String, want_bytes: List<&2, U32>) -> Bool:
  match r:
    case U.Utf8DecodeOk{+text, codepoints}:
      Bool.and(String.eq(text, want_text), encode_matches(U.utf8_encode(text), want_bytes))
    case U.Utf8DecodeInvalid{offset}:
      False{}

def decode_codepoints_match(r: U.Utf8DecodeResult, want: List<&2, U32>) -> Bool:
  match r:
    case U.Utf8DecodeOk{text, +codepoints}:
      bytes_eq(codepoints, want)
    case U.Utf8DecodeInvalid{offset}:
      False{}

def case_roundtrip(+name: String, +text: String, +bytes: List<&2, U32>) -> H.Check:
  H.chkb(name, decode_roundtrip_matches(U.utf8_decode(bytes), text, bytes), True{})

def case_encode(+name: String, +text: String, want: List<&2, U32>) -> H.Check:
  H.chkb(name, encode_matches(U.utf8_encode(text), want), True{})

def case_invalid(+name: String, bytes: List<&2, U32>) -> H.Check:
  H.chkb(name, U.utf8_valid(bytes), False{})

def case_encode_invalid(+name: String, +text: String) -> H.Check:
  H.chkb(name, encode_is_invalid(U.utf8_encode(text)), True{})

def case_decode_invalid_offset(+name: String, bytes: List<&2, U32>, want: Nat) -> H.Check:
  H.chkb(name, decode_invalid_offset_matches(U.utf8_decode(bytes), want), True{})

def case_encode_invalid_offset(+name: String, +text: String, want: Nat) -> H.Check:
  H.chkb(name, encode_invalid_offset_matches(U.utf8_encode(text), want), True{})

def case_codepoints(+name: String, bytes: List<&2, U32>, want: List<&2, U32>) -> H.Check:
  H.chkb(name, decode_codepoints_match(U.utf8_decode(bytes), want), True{})

def scalar_string(+cp: U32) -> String:
  SCon{Char.from_u32(cp), SNil{}}

def nul_string() -> String:
  scalar_string(0)

def astral_string() -> String:
  scalar_string(128512)

def max_scalar_string() -> String:
  scalar_string(1114111)

def too_large_string() -> String:
  scalar_string(1114112)

def surrogate_string() -> String:
  scalar_string(55296)

def mixed_string() -> String:
  "A" ++ scalar_string(233) ++ astral_string()

def checks() -> List<&2, H.Check>:
  case_roundtrip("roundtrip-ascii", "hello", [104, 101, 108, 108, 111]) <>
  case_roundtrip("roundtrip-bmp", "café λ", [99, 97, 102, 195, 169, 32, 206, 187]) <>
  case_roundtrip("roundtrip-astral", astral_string(), [240, 159, 152, 128]) <>
  case_roundtrip("roundtrip-mixed", mixed_string(), [65, 195, 169, 240, 159, 152, 128]) <>
  case_roundtrip("roundtrip-nul", nul_string(), [0]) <>
  case_roundtrip("roundtrip-max-u10ffff", max_scalar_string(), [244, 143, 191, 191]) <>
  case_encode("encode-mixed-exact", mixed_string(), [65, 195, 169, 240, 159, 152, 128]) <>
  case_codepoints("codepoints-mixed", [65, 195, 169, 240, 159, 152, 128], [65, 233, 128512]) <>
  case_codepoints("codepoints-max", [244, 143, 191, 191], [1114111]) <>
  case_invalid("reject-overlong-c0af", [192, 175]) <>
  case_invalid("reject-overlong-c1bf", [193, 191]) <>
  case_invalid("reject-overlong-e0", [224, 128, 175]) <>
  case_invalid("reject-overlong-f0", [240, 128, 128, 175]) <>
  case_invalid("reject-surrogate-d800", [237, 160, 128]) <>
  case_invalid("reject-surrogate-dfff", [237, 191, 191]) <>
  case_invalid("reject-truncated-1-of-2", [195]) <>
  case_invalid("reject-truncated-1-of-3", [226]) <>
  case_invalid("reject-truncated-2-of-3", [226, 130]) <>
  case_invalid("reject-truncated-1-of-4", [240]) <>
  case_invalid("reject-truncated-2-of-4", [240, 159]) <>
  case_invalid("reject-truncated-3-of-4", [240, 159, 152]) <>
  case_invalid("reject-invalid-cont-3", [226, 40, 172]) <>
  case_invalid("reject-invalid-cont-4", [240, 159, 65, 128]) <>
  case_invalid("reject-stray-continuation", [128]) <>
  case_invalid("reject-u110000-bytes", [244, 144, 128, 128]) <>
  case_invalid("reject-lead-f5", [245, 128, 128, 128]) <>
  case_encode_invalid("reject-encode-surrogate", surrogate_string()) <>
  case_encode_invalid("reject-encode-u110000", too_large_string()) <>
  case_decode_invalid_offset("decode-offset-truncated", [65, 195], 1n) <>
  case_decode_invalid_offset("decode-offset-surrogate", [65, 66, 237, 160, 128], 2n) <>
  case_encode_invalid_offset("encode-offset-surrogate", "ab" ++ surrogate_string(), 2n) <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
