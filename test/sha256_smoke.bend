import Base
import ./harness.bend as H
import ../src/sha256.bend as S

# Known-answer smoke tests for the pure SHA-256 implementation.  The vectors
# cover the empty input, the standard three-byte and fifty-six-byte NIST
# examples, padding boundaries, input longer than one compression block, and
# bytes containing embedded zeroes.

def ascii_bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{+h, +t}:
      Char.to_u32(h) <> ascii_bytes(t)

def no_bytes() -> List<&2, U32>:
  Nil{}

def mixed_zero_bytes() -> List<&2, U32>:
  0 <> 1 <> 2 <> 0 <> 255 <> Nil{}

def repeated_a(n: Nat) -> List<&2, U32>:
  List.replicate(U32, n, 97)

def case_hex(+name: String, input: List<&2, U32>, +want: String) -> H.Check:
  H.chk(name, S.sha256_hex(input), want)

def case_hex_encode(+name: String, input: List<&2, U32>, +want: String) -> H.Check:
  H.chk(name, S.sha256_hex_encode(input), want)

def checks() -> List<&2, H.Check>:
  case_hex("empty", no_bytes(),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") <>
  case_hex("abc", ascii_bytes("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") <>
  case_hex("nist-56", ascii_bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1") <>
  case_hex("multi-block-80a", repeated_a(80n),
    "0f45e858fbc4176cdf4e411f88281edefc390ae5afe7df0f44cd9297f0a64580") <>
  case_hex("boundary-55a", repeated_a(55n),
    "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318") <>
  case_hex("boundary-56a", repeated_a(56n),
    "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a") <>
  case_hex("boundary-64a", repeated_a(64n),
    "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb") <>
  case_hex("embedded-zeroes", mixed_zero_bytes(),
    "ef7e301027f931dfba06c7ded4ef305797f43cc115a664f9af9b57d08c3172c2") <>
  case_hex("zero-block", List.replicate(U32, 64n, 0),
    "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b") <>
  case_hex_encode("hex-lowercase", 0 <> 15 <> 16 <> 171 <> 255 <> Nil{}, "000f10abff") <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
