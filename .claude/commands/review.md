---
description: Review the current UNCOMMITTED working diff against this project's own rules in CLAUDE.md (vision invariants, module DAG, hygiene, tests) before you commit. For an opened GitHub PR use /review-pr; for a general correctness/cleanup bug-hunt at an effort level use /code-review.
---

Review the current working changes against this project's own rules.

1. Re-read `CLAUDE.md` in full — the vision invariants, module import DAG, hygiene,
   testing, and architecture/abstraction policy are the rubric.
2. Inspect the diff: `git diff` (and `git diff --staged`). If there is nothing to
   review, say so and stop.
3. Review in this priority order, and for each finding cite `file:line`:
   - **Boundary violations** — an import that breaks the DAG (e.g. Vulkan above
     `gpu`, anything in `src/**` referencing `games/**`, a core module doing I/O).
   - **Tests** — is every new public function/type covered? Are serializer changes
     still round-trip safe? Any weakened, skipped, or deleted test? Determinism
     still intact?
   - **Hygiene** — `///` doc comments with ownership/errors; explicit allocators;
     no `catch {}`; `unreachable` only with a proof comment; no dead or
     commented-out code; files ~500 / functions ~60 lines.
   - **Altitude / simplicity** — speculative abstraction, indirection without a
     second implementation, data-layer logic that leaked into code.
4. End with a short verdict: what must change before commit vs. optional nits, and
   whether an ADR is required for any decision in the diff.

Do not edit code in this command unless explicitly asked — report findings.
