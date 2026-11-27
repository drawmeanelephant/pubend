# Security policy

## Supported versions

pubend is pre-release software. Only the latest `main` branch receives security fixes.

## Reporting a vulnerability

Do not open a public issue for a security vulnerability. Use GitHub's private vulnerability reporting for
`drawmeanelephant/pubend` when available, or contact the repository owner through GitHub with a clear reproducer
and impact statement.

## Scope notes

pubend is a local publication compiler. Important security boundaries include path traversal, symlink handling,
unexpected file types, oversized inputs, generated output paths, and supply-chain integrity for the pinned Bend
toolchain and GitHub Actions. The current implementation is still a proof core plus scratch harness, not a
hardened production CLI.
