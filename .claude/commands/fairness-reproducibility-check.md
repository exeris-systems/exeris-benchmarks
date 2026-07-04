---
description: Enforce fairness scoping + reproducibility metadata on every committed result. JMH publishable runs use `-f 3` minimum.
argument-hint: result artefact / scenario change / JMH benchmark change to audit
---

Audit this change for fairness and reproducibility.

Fairness rules (per repo `CLAUDE.md`):
- Matched payload, concurrency, protocol mode, and target scope before any cross-target claim.
- Reject apples-to-oranges comparisons.
- Mandatory separation axes preserved (Community/Enterprise, H1/H2/H3, Pure/Compat, Micro/Runtime, Guard/Exploratory).

Reproducibility rules:
- Every committed result captures: commit SHA, JDK version, tool versions, JVM flags, hardware profile, scenario id, target classification.
- JMH publishable runs: `-f 3` minimum (`-f 1` is iteration-only).
- Standard JMH JVM flags: `-XX:+UseG1GC -XX:+AlwaysPreTouch -Xms256m -Xmx256m` (fixed heap prevents GC-mode switching across forks).
- Schema validation via `schemas/` MUST pass.

Change:
$ARGUMENTS

Please review:
1. For cross-target claims: are payload / concurrency / protocol / target matched, with explicit axis labels?
2. Are all mandatory separation axes labelled?
3. For committed results: is reproducibility metadata complete (SHA, JDK, JVM flags, hardware, scenario id, target classification)?
4. For JMH: was `-f 3` (or higher) used? `-f 1` in a committed result is a reject.
5. Does the artefact validate against the relevant schema in `schemas/`?
6. Minimal correction if fairness or reproducibility is at risk.

Mission: fair, reproducible, honest measurement. Non-goal: optimising to prove Exeris is fast.
