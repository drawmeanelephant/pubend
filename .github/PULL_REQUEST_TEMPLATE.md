## Summary

<!-- What invariant, behavior, or repository surface changes? Focus on why. -->

## Verification

<!-- Paste exact commands and results. Run `sh tools/verify_ci.sh all` for compile/proof/corpus/CI changes. -->

- [ ] `sh tools/verify_ci.sh proofs`
- [ ] `sh tools/verify_ci.sh corpus`

## Boundaries and deviations

<!-- Name anything not proved, not implemented, or diverging from docs/v0-spec.md. Do not hide uncertainty. -->

## Agent notes

- [ ] No law, proof obligation, test expectation, fixture, oracle expectation, CI check, or protection setting was weakened to make this pass.
- [ ] Markdown parsing still belongs to bendown; no parallel regex parser was added to pubend.
- [ ] Claims about parallelism, output bytes, diagnostics, or artifact-level links match the actual implementation.
