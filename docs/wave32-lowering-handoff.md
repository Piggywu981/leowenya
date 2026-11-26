# Wave64 → wave32 lowering: handoff record (main tree, 2026-11-26)

For whoever merges the BVH work into main, or revisits the three sealed
programs. This is the measured state of the lowering line on the main tree,
kept separate from the user-facing README. All numbers are from this machine
(RTX 5070 Laptop 8 GB, 32-lane host), not from upstream reports.

## What landed, and where

| Commit | Source | Files | What it does |
|---|---|---|---|
| `32cffa8` | coolfox `8cc31ab` | `victory-shader`: `emit/lower.rs`, `emit/mod.rs`, `resource.rs`, `dxbc.rs` | Emitter lowers some wave64 shapes to 32 lanes: ordered-LDS uniformity, restored constant VGPR lanes, a driver active-lane loop, distinct name for the divergent-mask exchange. Adds the `supported` gate that refuses to hand a 64-lane PSO to a 32-lane host. `dxbc.rs` adds `FourCC::ACCC` (needed by `mod.rs`; easy to miss). |
| `e8c59fc` | ccs03 `980a273` | `victory-gpu`: `shader_cache.rs`, `pipeline.rs`, `pipeline/make.rs`; `victory-shader`: `emit/lower.rs`, `emit/mod.rs` | Per-container-hash choice of the wave-wide form and the host wave's own first lane. Six wave-wide hashes and six first-lane hashes by default; `VICTORY_WAVE_WIDE_ONLY` / `VICTORY_FIRSTLANE_OWN_ONLY` override. Both variables are folded into the shader-cache key. `builder_runs()` names the programs still missing a pipeline. |
| `729cfee` | coolfox `f4b48ad` | `victory-shader`: `resource.rs` | A descriptor read at a join considers the EXEC guard of the accessing instruction (`Tracer::at` is now an instruction `Site`, not a block). Fixes the transmission-prefilter program `2da4beb3`. |
| `a401b4f`, `5b609af` | coolfox `8cc31ab` | `emit/mod.rs` | Tried the two `scene_kernel` container-digest wave-wide exceptions, measured no benefit, reverted. See "P3 lesson". |
| `0aefd26`, `21a5c80`, `1ba23bd` | — | `README.md` | User-facing record of the measured results and the failed attempt. |

Builds: `cargo test -p victory-shader --lib` → 214 passed / 4 failed / 3
ignored. The 4 failures are the pre-existing ray-intersection tests (main tree
shows `[inf,1.0]` vs `[16.0,16.0]`); they also fail on the bvh-fix worktree
(there as 1–2 ulp differences). Not introduced by this line. `cargo test -p
victory` and `cargo build --profile diag -p victory --features diagnostics`
both pass (note: `-p victory` is a bin crate, so `cargo test -p victory --lib`
reports "no library targets" — omit `--lib`).

## Measured on-card results

Same world scene, same cache warmth and switches, 20 stable frames each.
Tool: `tools/wave64-observe.ps1`; raw logs kept on disk (gitignored as
`run*.log`): `run-baseline.log` (before), `run-lowering-after.log` (after
`8cc31ab`+`980a273`), `run-p1-after.log` (after `f4b48ad`), `run-p3-test.log`
(the reverted experiment). Snapshots: `wave64-baseline.json`,
`wave64-after-lowering.json`.

| Stage | refused `0x80070057` | do-not-translate | dropped/frame (stable world) | ms/frame |
|---|---|---|---|---|
| baseline | 7 | 1 (`f133e35e`) | 1872 | 2027 |
| + `8cc31ab`+`980a273` | **0** | 4 (`2da4beb3`, `02384a60`, `6b82bc7d`, `f133e35e`) | 384 | 2119 |
| + `f4b48ad` (P1) | 0 | **3** (`02384a60`, `6b82bc7d`, `f133e35e`) | ~388 | 2204 |

Reading those numbers: the seven driver refusals became zero — four of them
(`5dc3b259`, `6f225b64`, `369cbe90`, `2cc4c197`) now translate as wave32 via
the wave-wide hash list; the other three are stopped by our own `supported`
gate instead of being sent as bad PSOs. `2da4beb3` then began to translate and
get a host pipeline (log: `shader translated` → `host pipeline` → first bind),
which is a picture fix (transmission buffer no longer zero) worth about one
draw/frame, not a frame-rate fix. Frame time never moved outside noise. The
big 1872→384 drop is mostly the four wave-wide programs' draws returning;
the ray-tracing builder is still off, so the returned draws do not yet change
the picture or the frame rate.

## The three sealed programs (no published low-risk fix)

- `02384a60fda6f2d0`, `6b82bc7d22016cb5` — compute, still "no wave32 lowering
  for this wave64 program". Not in any fork's hash whitelist. The only
  systematic route left is go2afri `6d666d4` (split-Wave64 retry ladder,
  ~2379 new lines across `wave_retry.rs` / `lds_fences.rs` / `own_bits.rs`,
  changes the translation-key length). Decided not to take it: each program
  costs ~1 draw/frame and the risk is high.
- `f133e35efed2a48a` — "a lane mask exchanged where not every lane runs"
  (`DIVERGENT_MASK_EXCHANGE`). The `driver_loop` / `widen(active_loop_only)`
  path from `8cc31ab` is in place but does not rescue it here.

P3 lesson: coolfox's two 16-byte `scene_kernel` digests (in `emit/mod.rs`) were
skipped during the first port under the note "this tree does not keep
`Container::digest`". That note was wrong — `dxbc.rs` has always had the
field. Enabling the exceptions and running on the card gave **3 → 3**, no TDR:
those digests belong to other kernels, not to `02384a60` / `6b82bc7d`. Reverted
rather than kept, since it would default two unknown kernels onto the
barrier-bearing wave-wide form for no benefit.

## Merge notes for the BVH line

- The main tree has **no** avatarmanz `value_uniform` proof (bvh-fix's worktree
  does). Therefore the six `FIRSTLANE_OWN_DEFAULT` hashes are load-bearing
  here; do not drop them as "redundant" when merging from a tree that has the
  proof.
- bvh-fix's worktree `resource.rs` is byte-identical to main's after `729cfee`
  (`git diff --no-index` = 0 hunks), so the P1 part of a merge is clean. Its
  `bvh.rs` / `emit/intersect.rs` changes are a separate correctness line.
- Enabling `VICTORY_BVH_BUILDER=1` currently crashes (~0xC0000005, about 10 s
  in) — a BVH data/thread-dimensions problem, not a lowering failure. The
  lowering's job stops at "the builder's programs have host pipelines".
- When the BVH fix lands, the thing to re-measure is not the refused count
  (already 0) but: does `builder_runs()` stay true, does the world get its
  ray-traced indirect light, and does the frame time change. See the A/B
  method in `tools/README-bvh-visual-ab.md`.
