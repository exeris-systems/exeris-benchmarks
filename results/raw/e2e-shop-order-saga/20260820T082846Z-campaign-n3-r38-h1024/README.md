# Normative-rate campaign, n=3, heap tier 1024m — 2026-08-20

The wide-heap half of a two-tier pair run the same day on the same shape:
`MaxRAM=1024m Xmx768m`, against `MaxRAM=256m Xmx192m` in
`../20260820T175303Z-campaign-n3-r38-h256`.

**The 256m tier is the reference**, because every run from 2026-08-21 onward uses it, so it
is the one that composes with the later data. This directory is kept as the second point on
the memory axis — the pair is what makes "nothing in this roster fails at a 256 MB
whole-process budget" a measurement rather than an assertion.

Same caveat as its sibling, and for the same reason: **`quarkus-lra-jdbc` ×3 is behind the
415 fence.** The `@Compensate` callback was returning HTTP 415 until commit `b0779716`
(2026-08-21 13:58 +0200); this campaign ran 2026-08-20 08:28 UTC. The gate's count leg passed
on a client-visible token while the store held no compensated rows, and the domain
corroboration leg that would have caught it did not exist yet.

Do not quote the quarkus arm from either campaign. See the sibling README for the full
validity screen and the re-run.
