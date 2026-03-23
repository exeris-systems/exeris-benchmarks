# Report Intake Issue Packets

Ready-to-execute implementation packets for routed report-intake backlog items. These packets define implementation scope, repository touchpoints, acceptance tests, and verification handoff for P0 delivery.

## Ready Queue

| Issue | Priority | Owner | Status | Depends On |
|---|---|---|---|---|
| [P0-01 Raw JFR Publication Guard](./ISSUE-P0-01-raw-jfr-publication-guard.md) | P0 | Docs/Reporting | verified (pass with caveat) | None |
| [P0-02 Runtime Claim-Eligibility Normalization](./ISSUE-P0-02-claim-eligibility-normalization.md) | P0 | Implementer | verified (pass with caveat) | P0-01 |
| [P0-03 Measurement Contract Drift Cleanup](./ISSUE-P0-03-measurement-contract-drift-cleanup.md) | P0 | Implementer | reopened (fail - contract drift remains) | P0-02 |
| [P0-05 Comparative Target-ID Runtime Registry](./ISSUE-P0-05-comparative-target-id-runtime-registry.md) | P0 | Implementer | in-progress | P0-03 |
| [P0-04 cert_key_bits OpenSSL 3.x Compat Fix](./ISSUE-P0-04-cert-key-bits-openssl3-compat.md) | P0 | Implementer | verified (pass) | None |

## Execution Order

Execute in sequence: `P0-01 -> P0-02 -> P0-03 -> P0-05 -> P0-04`.
