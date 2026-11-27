import Base
import ./model.bend as Model

# Compile pipeline, v0 scaffold.
#
# This is a typed stub: it always returns None, so no publication is ever
# produced and the laws in LAWS.bend are vacuously satisfiable. That is the
# intended bootstrap state — when the real pipeline lands, the proofs must
# become real or PROOF.bend fails. The signature is the stable contract:
#
#   compile is pure. IO (discovery, reading, writing) happens outside it,
#   in the CLI shell. What is proved about compile therefore never depends
#   on the filesystem.

def compile(config: Model.Config, pages: List<&2, Model.SourcePage>) -> Maybe<&2, Model.Publication>:
  None{}
