import Base

# Pure SHA-256 over byte input.  This module has no foreign effects and no IO:
# bytes enter as List<&2, U32>, the compression function is ordinary pure Bend
# arithmetic, and the digest leaves as bytes or lowercase hexadecimal text.
#
# The scanner is streaming rather than append-then-hash: input blocks are
# compressed as they become full, and only the final one-or-two padding blocks
# are ever materialized.  U32 arithmetic is fixed-width Word arithmetic in
# Base, so additions already wrap modulo 2^32 exactly as SHA-256 requires.

type ShaState is Data:
  ShaState{h0: U32, h1: U32, h2: U32, h3: U32, h4: U32, h5: U32, h6: U32, h7: U32}

type ShaWindow is Data:
  ShaWindow{w0: U32, w1: U32, w2: U32, w3: U32, w4: U32, w5: U32, w6: U32, w7: U32,
    w8: U32, w9: U32, w10: U32, w11: U32, w12: U32, w13: U32, w14: U32, w15: U32}

type ShaCore is Data:
  ShaCore{state: ShaState, window: ShaWindow}

type ShaWindowStep is Data:
  ShaWindowStep{window: ShaWindow, word: U32}

type BitLen is Data:
  BitLen{hi: U32, lo: U32}

type ShaScan is Data:
  ShaScan{state: ShaState, blockrev: List<&2, U32>, blocklen: U32, bits: BitLen}

# --- small factories ---------------------------------------------------------

def sha_state(h0: U32, h1: U32, h2: U32, h3: U32, h4: U32, h5: U32, h6: U32, h7: U32) -> ShaState:
  ShaState{h0, h1, h2, h3, h4, h5, h6, h7}

def sha_initial_state() -> ShaState:
  sha_state(1779033703, 3144134277, 1013904242, 2773480762,
    1359893119, 2600822924, 528734635, 1541459225)

def sha_window(w0: U32, w1: U32, w2: U32, w3: U32, w4: U32, w5: U32, w6: U32, w7: U32,
  w8: U32, w9: U32, w10: U32, w11: U32, w12: U32, w13: U32, w14: U32, w15: U32) -> ShaWindow:
  ShaWindow{w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15}

def sha_core(state: ShaState, window: ShaWindow) -> ShaCore:
  ShaCore{state, window}

def sha_window_step_make(window: ShaWindow, +word: U32) -> ShaWindowStep:
  ShaWindowStep{window, word}

def bitlen(hi: U32, lo: U32) -> BitLen:
  BitLen{hi, lo}

def sha_scan(state: ShaState, blockrev: List<&2, U32>, blocklen: U32, bits: BitLen) -> ShaScan:
  ShaScan{state, blockrev, blocklen, bits}

def sha_scan_new() -> ShaScan:
  sha_scan(sha_initial_state(), Nil{}, 0, bitlen(0, 0))

# --- fixed-width bit algebra --------------------------------------------------

def u32_rotr(+x: U32, r: Nat, l: Nat) -> U32:
  U32.or(U32.shrn(x, r), U32.shln(x, l))

def sha256_ch(+x: U32, +y: U32, +z: U32) -> U32:
  U32.xor(U32.and(x, y), U32.and(U32.not(x), z))

def sha256_maj(+x: U32, +y: U32, +z: U32) -> U32:
  U32.xor(U32.xor(U32.and(x, y), U32.and(x, z)), U32.and(y, z))

def sha256_big_sigma0(+x: U32) -> U32:
  U32.xor(U32.xor(u32_rotr(x, 2n, 30n), u32_rotr(x, 13n, 19n)), u32_rotr(x, 22n, 10n))

def sha256_big_sigma1(+x: U32) -> U32:
  U32.xor(U32.xor(u32_rotr(x, 6n, 26n), u32_rotr(x, 11n, 21n)), u32_rotr(x, 25n, 7n))

def sha256_small_sigma0(+x: U32) -> U32:
  U32.xor(U32.xor(u32_rotr(x, 7n, 25n), u32_rotr(x, 18n, 14n)), U32.shrn(x, 3n))

def sha256_small_sigma1(+x: U32) -> U32:
  U32.xor(U32.xor(u32_rotr(x, 17n, 15n), u32_rotr(x, 19n, 13n)), U32.shrn(x, 10n))

def sha256_add4(a: U32, b: U32, c: U32, d: U32) -> U32:
  U32.add(a, U32.add(b, U32.add(c, d)))

def sha256_add5(a: U32, b: U32, c: U32, d: U32, e: U32) -> U32:
  U32.add(a, U32.add(b, U32.add(c, U32.add(d, e))))

# One compression round.  The caller supplies the already prepared message
# word and round constant; all additions wrap in U32.
def sha256_round(st: ShaState, w: U32, k: U32) -> ShaState:
  match st:
    case ShaState{+a, +b, +c, +d, +e, +f, +g, +h}:
      +t1 = sha256_add5(h, sha256_big_sigma1(e), sha256_ch(e, f, g), k, w)
      +t2 = U32.add(sha256_big_sigma0(a), sha256_maj(a, b, c))
      sha_state(U32.add(t1, t2), a, b, c, U32.add(d, t1), e, f, g)

# The circular sixteen-word window is the standard SHA-256 message-schedule
# recurrence.  At the step that produces W[t], the window contains W[t-16]
# through W[t-1] in fields w0 through w15.  Computing the next word and
# shifting in one pass avoids copying the window once for the recurrence and
# again for the shift on every round.
def sha256_window_step(win: ShaWindow) -> ShaWindowStep:
  match win:
    case ShaWindow{+w0, +w1, +w2, +w3, +w4, +w5, +w6, +w7, +w8, +w9, +w10, +w11, +w12, +w13, +w14, +w15}:
      +x = sha256_add4(sha256_small_sigma1(w14), w9, sha256_small_sigma0(w1), w0)
      sha_window_step_make(sha_window(w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15, x), x)

# Round constants K[16..63].  K[0..15] are used directly in the first sixteen
# rounds; keeping the tail in order lets the recursive fused schedule/round
# loop consume one constant per step without a numeric lookup table.
def sha256_ktail() -> List<&2, U32>:
  3835390401 <> 4022224774 <> 264347078 <> 604807628 <>
  770255983 <> 1249150122 <> 1555081692 <> 1996064986 <>
  2554220882 <> 2821834349 <> 2952996808 <> 3210313671 <>
  3336571891 <> 3584528711 <> 113926993 <> 338241895 <>
  666307205 <> 773529912 <> 1294757372 <> 1396182291 <>
  1695183700 <> 1986661051 <> 2177026350 <> 2456956037 <>
  2730485921 <> 2820302411 <> 3259730800 <> 3345764771 <>
  3516065817 <> 3600352804 <> 4094571909 <> 275423344 <>
  430227734 <> 506948616 <> 659060556 <> 883997877 <>
  958139571 <> 1322822218 <> 1537002063 <> 1747873779 <>
  1955562222 <> 2024104815 <> 2227730452 <> 2361852424 <>
  2428436474 <> 2756734187 <> 3204031479 <> 3329325298 <> Nil{}

# A named gate for the computed window step: Bend matches cannot scrutinize a
# computed pair directly inside the recursive round loop.
def sha256_rounds_tail_step(state: ShaState, +k: U32, step: ShaWindowStep) -> ShaCore:
  match step:
    case ShaWindowStep{window, +word}:
      sha_core(sha256_round(state, word, k), window)

# Rounds 16..63, fusing message-schedule expansion with compression.  This
# keeps every block O(1) in memory: no sixty-four-word schedule vector is ever
# allocated, only the circular sixteen-word window is shifted.
def sha256_rounds_tail(ks: List<&2, U32>, core: ShaCore) -> ShaCore:
  match ks:
    case Nil{}:
      core
    case +k <> kt:
      match core:
        case ShaCore{state, window}:
          sha256_rounds_tail(kt,
            sha256_rounds_tail_step(state, k, sha256_window_step(window)))

def sha256_core_state(core: ShaCore) -> ShaState:
  match core:
    case ShaCore{+state, window}:
      state

def sha256_add_states(x: ShaState, y: ShaState) -> ShaState:
  match x y:
    case ShaState{+a0, +a1, +a2, +a3, +a4, +a5, +a6, +a7} ShaState{+b0, +b1, +b2, +b3, +b4, +b5, +b6, +b7}:
      sha_state(U32.add(a0, b0), U32.add(a1, b1), U32.add(a2, b2), U32.add(a3, b3),
        U32.add(a4, b4), U32.add(a5, b5), U32.add(a6, b6), U32.add(a7, b7))

# Rounds 0..15 consume the message words directly.  Writing them out avoids
# both a round-index lookup and a temporary schedule structure.
def sha256_first16(initial: ShaState, w0: U32, w1: U32, w2: U32, w3: U32,
  w4: U32, w5: U32, w6: U32, w7: U32, w8: U32, w9: U32, w10: U32, w11: U32,
  w12: U32, w13: U32, w14: U32, w15: U32) -> ShaState:
  s01 = sha256_round(initial, w0, 1116352408)
  s02 = sha256_round(s01, w1, 1899447441)
  s03 = sha256_round(s02, w2, 3049323471)
  s04 = sha256_round(s03, w3, 3921009573)
  s05 = sha256_round(s04, w4, 961987163)
  s06 = sha256_round(s05, w5, 1508970993)
  s07 = sha256_round(s06, w6, 2453635748)
  s08 = sha256_round(s07, w7, 2870763221)
  s09 = sha256_round(s08, w8, 3624381080)
  s10 = sha256_round(s09, w9, 310598401)
  s11 = sha256_round(s10, w10, 607225278)
  s12 = sha256_round(s11, w11, 1426881987)
  s13 = sha256_round(s12, w12, 1925078388)
  s14 = sha256_round(s13, w13, 2162078206)
  s15 = sha256_round(s14, w14, 2614888103)
  sha256_round(s15, w15, 3248222580)

# Compress one block after it has been packed into sixteen big-endian words.
# Internal callers maintain the exact sixty-four-byte block invariant.  The
# malformed fallback is unreachable inside that invariant and keeps the total
# function honest without introducing exceptions.
def sha256_compress_words(+initial: ShaState, ws: List<&2, U32>) -> ShaState:
  match ws:
    case +w0 <> +w1 <> +w2 <> +w3 <> +w4 <> +w5 <> +w6 <> +w7 <>
      +w8 <> +w9 <> +w10 <> +w11 <> +w12 <> +w13 <> +w14 <> +w15 <> t:
      +core = sha256_rounds_tail(sha256_ktail(),
        sha_core(sha256_first16(initial, w0, w1, w2, w3, w4, w5, w6, w7,
          w8, w9, w10, w11, w12, w13, w14, w15),
          sha_window(w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15)))
      sha256_add_states(initial, sha256_core_state(core))
    case other:
      initial

# --- block packing -------------------------------------------------------------

def sha256_be_word(+b0: U32, +b1: U32, +b2: U32, +b3: U32) -> U32:
  U32.or(U32.shln(b0, 24n),
    U32.or(U32.shln(b1, 16n),
      U32.or(U32.shln(b2, 8n), b3)))

def sha256_pack_done(acc: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, acc)

# Groups four input bytes into one big-endian word.  The scanner only calls
# this with a full sixty-four-byte block; short trailing groups are dropped in
# the unreachable malformed cases.
def sha256_pack_words_go(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      sha256_pack_done(acc)
    case +b0 <> t0:
      match t0:
        case Nil{}:
          sha256_pack_done(acc)
        case +b1 <> t1:
          match t1:
            case Nil{}:
              sha256_pack_done(acc)
            case +b2 <> t2:
              match t2:
                case Nil{}:
                  sha256_pack_done(acc)
                case +b3 <> t3:
                  sha256_pack_words_go(t3, sha256_be_word(b0, b1, b2, b3) <> acc)

def sha256_pack_words(xs: List<&2, U32>) -> List<&2, U32>:
  sha256_pack_words_go(xs, Nil{})

def sha256_compress_block(+state: ShaState, block: List<&2, U32>) -> ShaState:
  sha256_compress_words(state, sha256_pack_words(block))

# --- streaming byte scan -------------------------------------------------------

def bitlen_add8(bits: BitLen) -> BitLen:
  match bits:
    case BitLen{+hi, +lo}:
      +lo2 = U32.add(lo, 8)
      bitlen(U32.add(hi, Bool.to_u32(U32.is_lt(lo2, lo))), lo2)

def sha256_scan_step_gate(state: ShaState, blockrev: List<&2, U32>, blocklen: U32,
  bits: BitLen, full: Bool) -> ShaScan:
  match full:
    case False{}:
      sha_scan(state, blockrev, blocklen, bits)
    case True{}:
      sha_scan(sha256_compress_block(state, List.reverse(&2, U32, blockrev)), Nil{}, 0, bits)

# Add one byte to the partial block.  Input is byte-valued by contract; the low
# byte is selected here as a total-function normalization for malformed callers.
def sha256_scan_step(scan: ShaScan, +byte0: U32) -> ShaScan:
  match scan:
    case ShaScan{state, blockrev, blocklen, bits}:
      +byte = U32.and(byte0, 255)
      +newlen = U32.add(blocklen, 1)
      sha256_scan_step_gate(state, byte <> blockrev, newlen, bitlen_add8(bits), U32.is_eq(newlen, 64))

# The padding scan uses the same stepper.  It increments the length counter
# too, but that counter has already been encoded into the padding bytes and is
# never read afterwards.
def sha256_scan_tail(xs: List<&2, U32>, scan: ShaScan) -> ShaScan:
  match xs:
    case Nil{}:
      scan
    case +h <> t:
      sha256_scan_tail(t, sha256_scan_step(scan, h))

def u32_be0(+x: U32) -> U32:
  U32.and(U32.shrn(x, 24n), 255)

def u32_be1(+x: U32) -> U32:
  U32.and(U32.shrn(x, 16n), 255)

def u32_be2(+x: U32) -> U32:
  U32.and(U32.shrn(x, 8n), 255)

def u32_be3(+x: U32) -> U32:
  U32.and(x, 255)

# The bit length is tracked as a wrapping sixty-four-bit counter split into
# high and low U32 halves.  Padding emits all eight bytes, high half first.
def sha256_len_bytes(bits: BitLen) -> List<&2, U32>:
  match bits:
    case BitLen{+hi, +lo}:
      u32_be0(hi) <> u32_be1(hi) <> u32_be2(hi) <> u32_be3(hi) <>
      u32_be0(lo) <> u32_be1(lo) <> u32_be2(lo) <> u32_be3(lo) <> Nil{}

def sha256_zero_count(+blocklen: U32, small: Bool) -> Nat:
  match small:
    case True{}:
      U32.to_nat(U32.sub(55, blocklen))
    case False{}:
      U32.to_nat(U32.sub(119, blocklen))

# Standard SHA-256 padding: one 0x80 byte, enough zero bytes to reach the
# fifty-six-byte position modulo sixty-four, then the original bit length as
# sixty-four-bit big-endian.  A partial block of length fifty-six or more
# correctly spills into a second final block.
def sha256_padding(+blocklen: U32, bits: BitLen) -> List<&2, U32>:
  +small = U32.is_lt(blocklen, 56)
  +zeros = List.replicate(U32, sha256_zero_count(blocklen, small), 0)
  List.append(&2, U32, 128 <> Nil{},
    List.append(&2, U32, zeros, sha256_len_bytes(bits)))

def sha256_final_state(scan: ShaScan) -> ShaState:
  match scan:
    case ShaScan{+state, blockrev, blocklen, bits}:
      state

def sha256_scan_finish(scan: ShaScan) -> ShaState:
  match scan:
    case ShaScan{state, blockrev, +blocklen, +bits}:
      +padding = sha256_padding(blocklen, bits)
      sha256_final_state(sha256_scan_tail(padding, sha_scan(state, blockrev, blocklen, bits)))

def sha256_scan_input(xs: List<&2, U32>, scan: ShaScan) -> ShaState:
  match xs:
    case Nil{}:
      sha256_scan_finish(scan)
    case +h <> t:
      sha256_scan_input(t, sha256_scan_step(scan, h))

# --- public digest API ---------------------------------------------------------

def sha256_word_bytes(+x: U32) -> List<&2, U32>:
  u32_be0(x) <> u32_be1(x) <> u32_be2(x) <> u32_be3(x) <> Nil{}

def sha256_words_to_bytes(ws: List<&2, U32>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +h <> t:
      List.append(&2, U32, sha256_word_bytes(h), sha256_words_to_bytes(t))

def sha256_state_bytes(st: ShaState) -> List<&2, U32>:
  match st:
    case ShaState{+h0, +h1, +h2, +h3, +h4, +h5, +h6, +h7}:
      sha256_words_to_bytes(h0 <> h1 <> h2 <> h3 <> h4 <> h5 <> h6 <> h7 <> Nil{})

# Compute the thirty-two-byte SHA-256 digest of a byte list.  Byte values are
# expected in the inclusive range 0..255; the scanner normalizes any out-of-
# range U32 to its low byte rather than introducing a partial or effectful API.
def sha256_bytes(input: List<&2, U32>) -> List<&2, U32>:
  sha256_state_bytes(sha256_scan_input(input, sha_scan_new()))

# --- lowercase hexadecimal output ----------------------------------------------

def sha256_hex_digit_gate(+x: U32, small: Bool) -> String:
  match small:
    case True{}:
      SCon{Char.from_u32(U32.add(x, 48)), SNil{}}
    case False{}:
      SCon{Char.from_u32(U32.add(x, 87)), SNil{}}

def sha256_hex_digit(+x: U32) -> String:
  sha256_hex_digit_gate(x, U32.is_le(x, 9))

def sha256_hex_byte(+b: U32) -> String:
  sha256_hex_digit(U32.and(U32.shrn(b, 4n), 15)) ++ sha256_hex_digit(U32.and(b, 15))

def sha256_hex_encode(bytes: List<&2, U32>) -> String:
  match bytes:
    case Nil{}:
      ""
    case +h <> t:
      sha256_hex_byte(h) ++ sha256_hex_encode(t)

# Compute the digest and encode it as sixty-four lowercase hexadecimal chars.
def sha256_hex(input: List<&2, U32>) -> String:
  sha256_hex_encode(sha256_bytes(input))
