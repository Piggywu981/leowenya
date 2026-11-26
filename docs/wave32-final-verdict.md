# Wave32 lowering: final verdict on the last three hashes

Date: 2026-11-27. This records why the remaining three `no wave32 lowering for this
wave64 program` refusals are **封存 (archived, not fixed)**, after exhausting every
publicly-available fix path. Keep it so nobody repeats the effort.

## Where the line landed

- wave64→32 lowering itself **succeeded and is merged** (`3a4b3ba`, pushed): the 8cc31ab
  lowering core, ccs03 980a273 per-hash wave-wide/firstlane, f4b48ad EXEC-guard lane
  tracking, plus the BVH guards. Live acceptance (`run-merged-acceptance.log`):
  `refused 0x80070057` **7→0**, `notTranslated` **8→3**, wave64-caused dropped draws
  down to ~2/frame. The hundreds of remaining dropped draws per frame are **the BVH
  builder being off**, not a translation problem.
- The three remaining refusals are `02384a60fda6f2d0`, `6b82bc7d22016cb5`,
  `f133e35efed2a48a`. All three fix paths were investigated with container-level
  disassembly (`_handoff/wave32-final-3hash.md` and `_handoff/wave32-prereq-facts.md`)
  and **all three are rejected by the programs' own facts**:

| hash | program | why no public fix applies |
|---|---|---|
| `02384a60fda6f2d0` | DefragHeap_ComputeRelocations | 128 threads/group (multi console wave), LDS 16420 B, 26×`ds_read`/10×`ds_write`/5×`s_barrier` |
| `6b82bc7d22016cb5` | CollectTriangles_Meshlets | 1024 threads/group, LDS 32748 B, `ds_*` + `s_barrier` |
| `f133e35efed2a48a` | ShadowRenderTiledCascadesAlphaCBPPPC | 0x1eb4 mask is dynamic (`s_and_b64 vcc, exec, s[40:41]`, `s_or_b64 s[14:15], s[12:13], vcc`, `s_xor_b64 s[14:15], s[14:15], -1`), not `XOR exec,exec` / `OR exec,exec` |

## Paths tried / rejected, with evidence

- **`VICTORY_WAVE_WIDE=last` (fxceless 96ff135)** — merged as `3bd86a3`, default off,
  correct fork code, no regression, no TDR. Live run (`widelast_run.log`): the retry
  executes, but both multi-wave-group programs are still refused because `widen()`
  rejects "wave-wide branches in a thread group of several console waves" at entry.
  Kept as a zero-risk option for future single-wave programs; does not fix these two.
- **belobug console flow (6ccf47b split 294 lines + 5eac4fa full flow ~1750 lines)** —
  **not worth porting**. Both programs are multi console wave groups (128/1024 threads)
  AND use LDS, exactly the two items belobug's own `docs/wave64-on-wave32.md` lists as
  "Still open". `6ccf47b`'s split needs `lds_dwords==0` and one wave per group;
  `5eac4fa`'s flow assumes one console wave per group. The code would never enter the
  split/console_flow branches.
- **fablinoo zero_mask (94cdceb + 0047, ~10 lines)** — **would be a no-op**. Its early
  return needs `m == Bool::FALSE` (constant empty) or an EXEC copy; f133e35e's mask is
  a runtime combination, so the early return never fires and only the cache key changes.
- **scene_kernel digest exceptions (earlier P3)** — tried and reverted (`a401b4f`
  → `5b609af`); live run showed 3→3, hit different kernels.
- **go2afri 6d666d4 split-Wave64 ladder (2379 lines)** — higher cost than belobug,
  no better coverage; not pursued.

## Why these are architecture, not missing switches

All three programs need what the tree's lowering fundamentally lacks: cross-wave
exchange for **several console waves per thread group**, plus group-level reduction of
**dynamic** lane masks. That is ~200–400 lines of Bool/dataflow proof at minimum, or
~1750+ lines of full console-flow cross-wave exchange — and belobug itself has not
solved the multi-console-wave-group and LDS cases. No existing fork provides a
copyable implementation.

## Related limits (recorded elsewhere)

- Frame time on this RTX 5070 Laptop 8 GB is GPU-bound: live frame decomposition
  `2203 ms/frame` with `1477 ms on the GPU` (67–77%); CPU list recording was only
  ~507 ms. `VICTORY_THIN` (CPU recording, ~8% faster per call) had **no end-to-end
  effect** and was reverted (`20a5f9c` documents it). GPU-bound is the structural cost
  of emulating refused wave64 programs on a 32-lane card — no switch closes it.
- `VICTORY_BVH_BUILDER=1` still crashes 0xC0000005; `docs/wave64-builder-diagnosis.md`
  archives the three live-form attempts (half ±Inf sentinel → NONE-dominated bad
  nodes). Even the leading fork (coolfox) marks dynamic-structure overlap as an open
  gap. Ambient sky-following light is the production substitute: outdoor picture is
  good, interior bounce light remains the known gap.
- **Ambient tuning cannot fix interior readability** (live A/B, `run-ambient-ab.log`,
  2026-11-27): same indoor window scene, `VICTORY_AMBIENT_FILE` hot-tune. Raising
  `least` 0.05→0.12→0.2 changed almost nothing (least is not the limiter); `gain`
  0.36→0.7 brightened hair slightly but the face stayed an unreadable backlit
  silhouette; the best combo (0.6/0.15/0.3) was only marginal and did not overexpose
  outdoors. Interior light comes from direct/ray-traced bounce (the builder), of which
  ambient's sky-mean is only an approximation. Default stays 0.36/0.05/0.4 — the
  marginal gain is not worth unbalancing other hours. Stripe artifacts are unrelated
  to ambient (unchanged across all settings). Interior "good picture" is archived as
  a builder-dependent, hardware-limited gap.

## Bottom line

lowering: done. The three remaining refusals: **archived as hardware/ISA-structure
limits**, not fixable by any available fork's small switch. Further work would need
new lowering capability (multi-wave-group cross-wave exchange + dynamic mask proof)
that no public tree implements.

## Correction (2026-11-27): the frame-time attribution was wrong

An earlier conclusion called the world frame "GPU-bound = the structural cost of
wave64 emulation on a 32-lane card, no switch closes it". That was **premature and is
withdrawn**. Reading `host.rs` shows the frame line's `{gpu:.1} on the GPU` is
`SUBMISSION_US[1]` (`host.rs:6673-6675`), i.e. the **wall-clock from submission to the
fence completing** (`prepared.elapsed()` at `:4863`, `waiting.elapsed()` at `:4549`),
NOT pure GPU compute time. The live log `run-merged-acceptance.log` reports, in the
same frame: `card about 92-95% busy`, `nothing of ours queued 117 ms`, and `1477 ms
waiting for the card in settles`. So the card is busy but *not with our queued draw
work* — the 1477 ms is memory copies / synchronization occupying the card, which is
the opposite of an unavoidable wave64 compute wall. kelvaroq
(`stellarr-studio/kelvaroq`, = local `fablinoo__kelvaroq`, HEAD `1270c42`) makes the
same claim with its "unified memory layer": the copy loop, not the game's draw work,
eats the frame.

**New direction (NVIDIA only — no hardware change):** attribute the 1477 ms properly
with copystat/GPU timestamps (measure before editing), then port N-card-applicable
copy/VRAM/submission fixes — kelvaroq patches 0038 (constants read from the GPU copy),
0039 (ReBAR: read-only copies in CPU-visible VRAM), 0040 (async submit defaults) as
references — evaluating each against this merged main tree. Success = stable world
frame time drops materially, with `notTranslated` not regressing, no TDR, tests clean.

