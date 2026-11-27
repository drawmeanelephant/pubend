import Base
import ./src/model.bend as Model
import ./src/compile.bend as Compile
import ./LAWS.bend as Laws

# pubend proofs.
#
# compile_deterministic is reflexivity — trivially true of any pure def, kept
# as a regression pin against effect leakage.
#
# link_integrity is deliberately OPEN. The compile stub makes it vacuous, and
# a vacuous proof is worthless; the law must be proved against the real
# pipeline. Until then `bend PROOF.bend` correctly prints SOME PROOFS FAIL —
# that is the ratchet, not a broken build.

def Laws.compile_deterministic(config, pages):
  {==}
