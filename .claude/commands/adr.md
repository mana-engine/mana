---
description: Scaffold a numbered Architecture Decision Record from the template.
argument-hint: <short title of the decision>
---

Create a new ADR in `docs/adr/` for: **$ARGUMENTS**

Steps:
1. Find the highest-numbered `docs/adr/NNNN-*.md` and use the next integer,
   zero-padded to 4 digits.
2. Slugify the title (lowercase, hyphens) for the filename:
   `docs/adr/NNNN-<slug>.md`.
3. Write the file using this template, filling in what you can from context and
   leaving clear TODOs where you need input:

```markdown
# NNNN. <Title>

- Status: proposed
- Date: <today's date, YYYY-MM-DD>

## Context

<What problem or decision prompted this? What forces are in tension? Reference the
relevant vision invariant or module boundary.>

## Decision

<The choice made, stated plainly.>

## Consequences

<What becomes easier, what becomes harder, what we are now committed to, and what
we explicitly are NOT doing. Note any follow-up ADRs this implies.>
```

4. Update the ADR index table in `docs/adr/README.md`.
5. Report the path created; do not commit unless asked.
