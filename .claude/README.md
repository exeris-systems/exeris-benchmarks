# `.claude/` — Claude Code workspace for `exeris-benchmarks`

This directory is loaded automatically when a Claude Code session opens inside
`~/exeris-systems/exeris-benchmarks/`. It exists alongside the repo-root [`CLAUDE.md`](../CLAUDE.md)
and works as the operating context for AI assistants on the public benchmark lab.

## Layout

- `agents/` — sub-agents Claude can launch via the `Agent` tool (or invoke directly):
  - `exeris-benchmarks-router.md` — entrypoint triage
  - `exeris-benchmarks-architect.md` — separation axes, comparative strict gate, fairness, not-a-merge-gate, confidentiality boundary
  - `exeris-benchmarks-implementer.md` — scenario / driver / JMH / target / scripts changes
  - `exeris-benchmarks-verification.md` — reproducibility metadata, baseline policy, validation gates
  - `exeris-benchmarks-docs-adr.md` — scenario catalog / methodology / regression-policy / TLS matrix docs sync
- `commands/` — slash commands (`/<command-name>`):
  - `comparative-strict-gate-check.md`, `fairness-reproducibility-check.md`, `tls-label-discipline.md`, `publication-mode-scrub.md`
- `skills/` — invocable skills (`/<skill-name>`):
  - `exeris-benchmarks-task-classifier`, `exeris-benchmarks-routing-planner`
  - `exeris-benchmarks-comparative-strict-gate-review`, `exeris-benchmarks-fairness-reproducibility-review`
  - `exeris-benchmarks-tls-label-discipline-review`, `exeris-benchmarks-publication-mode-scrub-review`

## Doctrine — single source

Project doctrine is **not** duplicated under `.claude/`:

- **`/CLAUDE.md`** (repo root) — load-bearing facts, mandatory separation axes, comparative strict gate, TLS labels (B3/B4/B5/B6/B7), fairness, reproducibility, confidentiality.
- **`docs/benchmark-philosophy.md`**, **`docs/methodology.md`**, **`docs/scenario-catalog.md`**, **`docs/protocol-comparison-matrix.md`**, **`docs/tls-zero-copy-benchmark-matrix.md`**, **`docs/result-interpretation.md`**, **`docs/regression-policy.md`**, **`docs/hardware-profiles.md`**.
- **`.github/copilot-instructions.md`** + **`.github/instructions/exeris-bench-{core,runtime,reporting}.instructions.md`** — authoritative operating rules; on conflict, prefer the **stricter** fairness/reproducibility/confidentiality interpretation.
- **`schemas/`** — JSON Schemas that benchmark results MUST validate against.
- **Sister repo:** `~/exeris-systems/exeris-benchmarks-enterprise/` for H3 / Enterprise-only material; that repo enforces its own confidentiality.

When skills/agents need policy context, they reference these — they do not restate them.
