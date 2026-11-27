#!/bin/sh
# Local/CI verification entrypoint. Keep CI thin so agents run the same
# commands locally that protected branches require in GitHub Actions.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MODE=${1:-all}
BEND_BIN=${BEND_BIN:-$HOME/.bend/bin/bend}
export BEND_NO_TELEMETRY=1
export PYTHONDONTWRITEBYTECODE=1

proofs() {
  proof_out=$("$BEND_BIN" PROOF.bend 2>&1)
  printf '%s\n' "$proof_out"
  printf '%s\n' "$proof_out" | grep -q '^ALL PROOFS CHECK$'

  for test_file in \
    test/frontmatter_smoke.bend \
    test/paths_smoke.bend \
    test/graph_smoke.bend \
    test/links_smoke.bend \
    test/compile_smoke.bend
  do
    "$BEND_BIN" "$test_file"
  done
}

corpus() {
  for site in \
    corpus/conifers \
    corpus/hearth \
    corpus/sourdough \
    corpus/spices \
    corpus/tidepools
  do
    python3 tools/check_corpus.py "$site"
  done

  python3 tools/check_corpus.py --self-test corpus-negative
  node tools/compile_corpus.mjs all corpus corpus-negative --rebuild
}

case "$MODE" in
  proofs) proofs ;;
  corpus) corpus ;;
  all) proofs; corpus ;;
  *) echo "usage: sh tools/verify_ci.sh [proofs|corpus|all]" >&2; exit 2 ;;
esac
