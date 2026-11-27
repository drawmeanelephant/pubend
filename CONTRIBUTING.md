# Contributing

pubend is currently optimized for small, auditable agent-driven changes. Human reviewers are not required by
branch protection, but machine verification is mandatory.

## Before opening a PR

1. Read [AGENTS.md](AGENTS.md) and the relevant parts of [docs/v0-spec.md](docs/v0-spec.md).
2. Keep the change coherent and scoped.
3. Run the relevant verification lane, or the full suite when uncertain:

```sh
sh tools/verify_ci.sh all
```

4. Do not weaken proofs, tests, fixtures, branch protection, or CI to make a change pass.

## Pull requests

- Use a branch; direct updates to `main` are rejected.
- Explain the invariant or user-visible behavior being changed, not just the files touched.
- Include exact verification commands and results in the PR body.
- Call out spec deviations and unproved boundaries explicitly.

Reviewer approval count is currently zero by design. That is not permission to merge unverified work: the
`verify-proofs` and `verify-corpus` checks are required.
