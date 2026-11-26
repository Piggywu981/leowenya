# Wave64 / ray-tracing builder: measured blockers (2026-11-26)

Findings from offline `victory translate --warm` runs and the on-machine log
`G:\Leonida\mipskip_on.err.log`. **These are measurements, not fixes.** They are
recorded so the next pass starts from evidence instead of repeating searches.

## Host and failure shape

- `mipskip_on.err.log:40`: `host wave lanes min=32 max=32` — the host is an
  NVIDIA RTX 5070 Laptop with 32-lane waves, so any emitted shader that still
  asks for `WaveSize(64)` is refused by D3D12 with `E_INVALIDARG (0x80070057)`.
- 7 compute programs reach "shader translated" and then "host pipeline refused"
  (log lines 243/247, 546/550, 1941/1943, 2165/2167, 2182, 2223, 2229). Their
  hashes (16-hex prefixes): `2da4beb386509b77`, `369cbe906ea72764`,
  `2cc4c197ee29e291`, `02384a60fda6f2d0`, `6b82bc7d22016cb5`,
  `5dc3b25986622949`, `6f225b641c5b0708`. These are translation *successes*
  whose DXIL carries `WaveSize(64)`; the fix is a lowering change, not a
  translator change.
- One program does not translate at all: `f133e35efed2a48a`
  (`mipskip_on.err.log:1783`), `GFX10 code at 0x1eb4: a lane mask exchanged
  where not every lane runs is not supported` (lower.rs:3168 / 3814). It is a
  lane-mask / wave64 shape, a different failure line from the 7 above. Whether
  it gates the builder is unproven; no log has run with
  `VICTORY_BVH_BUILDER=1`, so "builder stays off" in old logs only proves the
  default-off gate, not the refused-pipeline gate.

## Why each program keeps 64 lanes (`VICTORY_WAVE_WHY=1`, offline warm-up)

Re-running the 8 hashes through the translator with `VICTORY_HOST_WAVE=32` and
`VICTORY_WAVE_WHY=1` prints, per program, the reason `wave` stays at 64. Every
one of them reports:

- `LDS in a group over 32`, and
- `an LDS read and write in one lane-branch region`

Some also report `v_readlane`, `mask as data`, or `v_mbcnt`. The second reason
is the decisive one: `lds_meetings` (lower.rs:847-909) returns `None` at line
893 when a single lane-branch region contains both an LDS read and an LDS
write. A group barrier cannot keep the console's write-then-read order there
without hanging, so the whole lowering keeps 64-lane waves and D3D12 refuses it.

## Existing switches do not rescue these programs

Offline warm-up of `f133e35` under `VICTORY_HOST_WAVE=32`, one hash, fresh cache
each time (cache kept outside the source tree per `docs/asset-policy.md`):

| Switch | Result |
|---|---|
| default | 1 do not translate |
| `VICTORY_WAVE_WIDE=1` | 1 do not translate |
| `VICTORY_WAVE_LOCAL=0` | 1 do not translate |
| `VICTORY_WAVE_LOCAL=idiom` | 1 do not translate |
| `VICTORY_WAVE_WIDE=1 VICTORY_WAVE_DEEP_SKIPS=1` | hangs (known barrier risk, see emit/mod.rs:420-425) |

And for the 7 translated programs, every retry tier in `emit()` (without
early-outs, without skips, local idiom, `with_local_waves_any`) still ends at
`wave Some(64)` per the `WAVE64-RETRY` lines. So the retry chain cannot lower
these to 32 lanes as-is.

## Where a fix must go (not attempted here)

- The 7 refused programs: `emit/lower.rs:1300-1412`, specifically the
  `lds_meetings` gate at 1341-1344. The BVH traversal uses a per-thread stack in
  group-shared memory (`docs/fork-ray-tracing.md:16-18`). If the LDS addresses
  are provably per-lane (derived from the console lane number), two 32-lane
  halves touch disjoint dwords and a region-local read+write needs no barrier;
  that would let `wave = 32` here. Proving that needs value tracking on the
  address VGPR (`ds()`: lower.rs:4495-4512) and is **not** done — shipping it on
  a guess would produce a wrong shader, which is worse than a dropped draw.
- `f133e35`: the `scc_some` ballot exchange at lower.rs:3158-3168 / 3809-3814.
  A proposed "reach ⊆ m ⇒ half-wave independent" shortcut was reviewed and
  **rejected**: it does not make the two halves' `any` equal in general, and
  would generate wrong wave-wide branch decisions. Do not apply it.
- The builder gate itself (`pipeline.rs:308-336`) is correct and must stay:
  run 98 (14/35 stages translated) died within a second on garbage bounding
  boxes. Loosening `all or none` to get the builder running is not a fix.

## Instrumentation added in this worktree

- `draw.rs` / `host.rs`: split the `heap buffers` bucket into three timed
  stages (readying host copies, `refresh_many`, texture upload) in the frame
  report. The old single number could not say where a 3522 ms pass went; this
  can. Both default and `diagnostics` builds compile.
- `pipeline.rs`: the "builder stays off" warning now lists each missing
  pipeline with the reason `make::missing()` already computes (refused / does
  not translate / being made).
- `pipeline.rs`: `VICTORY_BVH_BUILDER=report` is a new third mode (with `1` =
  run and unset = off). On the first builder dispatch it prints every program
  the title created and why each lacks a host pipeline, then returns false —
  **no stage runs**. This is the safe way to learn which of the 7 refused
  programs are really builder stages: the whole-builder rule once killed the
  title (run 98), so a first look should not risk executing it. Parsing is
  covered by a unit test (`builder_mode_distinguishes_report_from_run`).
  Both builds compile and the unit test passes.

## Decisive live result: the builder key is `VICTORY_FIRSTLANE_OWN=1`

Live runs of the diagnostics build with `VICTORY_BVH_BUILDER=report` and the
`-Guide` key script (exe
`G:\Leonida\_port\.agents\worktrees\lowlevel-wave64-instrumentation\target\release\victory.exe`,
game `G:\Leonida\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe`)
gave the authoritative builder census at the first builder dispatch:

| Run | Result |
|---|---|
| `VICTORY_BVH_BUILDER=report` | `pipelines=53 ready=50 failed=[compute 39321a95223001ed, compute 77360df21e12ea43, compute 9fc111d3be79364f]` |
| `VICTORY_BVH_BUILDER=report VICTORY_FIRSTLANE_OWN=1` | `pipelines=53 ready=53 failed=[]` |

This **corrects the earlier diagnosis**: the 7 `WaveSize(64)`-refused hashes in
`mipskip_on.err.log` are ordinary compute programs, **not** builder stages —
none of them appear in the builder's 53. The real builder blocker is a single
translator shape in exactly 3 programs:

```
shader does not translate stage="compute" hash=<the three above>
error=converter shader.dxil v1: GFX10 code at 0x23c (0x258 for 9fc111d3):
  a first-lane read where not every lane runs is not supported
```

That is lower.rs:7610-7633, `v_readfirstlane_b32` with a non-uniform source in
a block not every lane runs. The source already has a switch for precisely
this case — `VICTORY_FIRSTLANE_OWN=1` at lower.rs:7624-7631 — whose comment
names the ray-tracing builder's scans ("a sum of scalars ... inside a loop
whose exit is per console wave"). Setting it makes all 53 builder host
pipelines constructible.

### Boundary — read before enabling

`ready=53` proves the pipelines **build**, not that the builder produces
**correct** BVH data. `FIRSTLANE_OWN` is a bounded approximation: it takes the
host wave's own first lane when the console's first lane might be in the other
half. It is exact only if the read value is the same in every console lane.
The code's `uniform` analysis (lower.rs:463-510) proves that for some values,
but the `OWN` branch currently bypasses even that check. Enabling it as a
default therefore needs one live `VICTORY_BVH_BUILDER=1` run with visual/QA
checks — which is risky (run 98 killed the title on garbage bounding boxes)
and was deliberately **not** done here. Use `VICTORY_BVH_QUARANTINE=1` for such
a first run so builder stores cannot reach title memory.

The safe next step is not `=1` blindly: either (a) prove the three programs'
first-lane source uniform and narrow `FIRSTLANE_OWN` to that proof, or (b) run
builder once in quarantine with screen capture and check for device loss and
correct geometry. Until then the key is found and documented, not shipped as
a default.

### Diagnosing the shape (`VICTORY_FIRSTLANE_OWN=why`)

`emit/lower.rs:7624-7638` now has a pure-diagnostic mode: `=why` prints one
`FIRSTLANE-OWN` line per program that hits the wall (`block`, whether the
instruction has an EXEC `guard`, whether the source is in the proved-`uniform`
set, and the source operand) **without** changing translation; only `=1`
takes the approximation.

A live `-Guide` run with `VICTORY_FIRSTLANE_OWN=why` plus
`VICTORY_BVH_BUILDER=report` produced hits with `guard=false uniform=false`.
The `why` print was then extended to name the instruction defining each source
(`FIRSTLANE-OWN ... def=<inst>`). The distribution of 229 hits:

| defining instruction | count |
|---|---|
| `v_cvt_u32_f32` | 53 |
| `buffer_load_format_x` | 36 |
| (no single definer — a phi/input) | 34 |
| `v_cndmask_b32` | 23 |
| `v_fma_mix_f32` | 14 |
| `v_cvt_i32_f32` | 12 |
| `v_add_nc_u32` | 9 |
| `v_mul_legacy_f32` | 8 |
| `ds_read2_b32` / `ds_read_b32` | 8 |
| `v_max_f32` / `v_min_f32` / `v_add_f32` / others | ~32 |

### This corrects the previous recommendation

The earlier idea — "extend `lane_uniform` to recognise the builder's reduce
and take an exact path" — is **not viable**. The sources are not one reduce
shape: they are ordinary per-lane computations (conversions, buffer loads,
ds reads, selects, FMAs). `uniform=false` is correct for most of them: their
values genuinely differ per lane. So the switch's comment ("a sum of scalars")
describes only a minority of these reads.

Consequence: `VICTORY_FIRSTLANE_OWN=1` is **not exact** for these programs. It
takes the host wave's own first lane; when the console's lane 0 is in the
other half, that is a different lane's value — a wrong first-lane read. A
`ready=53` census proves the pipelines **construct**, not that the builder
computes correct BVH data. Do not enable `FIRSTLANE_OWN=1` as a default on
the strength of the census alone.

### Correction: `with_local_waves` is not an exact escape either

An earlier note suggested routing these programs through `with_local_waves`
so their first-lane reads take `exchange_halves`' barrier-free `self.local`
form (lower.rs:3734-3742). Re-reading the lowering shows that is wrong: under
`self.local`, `v_readfirstlane` is lowered at lower.rs:7656 (`halves` is
false when `local`), which simply takes `mine` — the **same approximation**
as `FIRSTLANE_OWN`, not the exact lower-half branch. The barrier-free
`exchange_halves` form is used for lane masks and lane reads, not for this
first-lane read. So `VICTORY_WAVE_LOCAL` does not make these reads exact.

### Where that leaves goal (3)

An exact lowering needs `exchange_halves` at lower.rs:7653, whose normal form
uses a group barrier (unsafe when the block is not all-lanes), while the
barrier-free local form is not reached for `v_readfirstlane`. So neither of
the existing switches gives an exact result here; both approximate. The
honest options are:

1. prove each source uniform (ruled out by the `why` distribution — most are
   per-lane data), or
2. prove the block can safely take the barrier (needs an all-lanes guarantee
   the builder's loop does not give), or
3. accept a documented approximation and validate the builder's output by
   live QA under `VICTORY_BVH_QUARANTINE=1`.

None is a small, safe code change. To prevent misuse, `VICTORY_FIRSTLANE_OWN=1`
now prints a one-time warning naming the approximation; `=why` remains a pure
diagnostic. The builder key is confirmed but **not** safe to default on.

### Live stability QA (2026-11-26, passed)

A controlled live run with
`VICTORY_BVH_BUILDER=1 VICTORY_FIRSTLANE_OWN=1 VICTORY_BVH_QUARANTINE=1`
and the `-Guide` key script produced the decisive result for "can it run":

- `the ray-tracing structure builder runs: all of its programs have host pipelines` —
  the builder **actually started** (not just `ready=53` in a census).
- Ran for over 6 minutes **without** `device removed`, crash, panic, or any
  `builder ... off` / `stays off` line. Run 98 (14/35 stages) killed the title
  within a second on garbage bounding boxes; that did not recur with all 53
  present.
- World frames kept advancing, settling near 2.8 fps (vs 1-3 fps before):
  the full builder every frame is heavy, the expected cost of turning ray
  tracing on.

**What this proves and what it does not.** It proves the builder can run
without crashing when all programs are present. It does **not** prove the BVH
data is numerically correct: `VICTORY_BVH_QUARANTINE=1` keeps builder stores in
host copies, so the title never consumes the structures, and
`FIRSTLANE_OWN=1` is still an approximation for the non-uniform sources found
above.

### Non-quarantined run: crashes (2026-11-26)

The decisive follow-up — `VICTORY_BVH_BUILDER=1 VICTORY_FIRSTLANE_OWN=1`
with **no** quarantine, so the title actually consumes the BVH — crashed:

- `the ray-tracing structure builder runs` appeared, frames advanced past the
  world, then at ~100 s the title hit a cascade of
  `unhandled exception 0xc0000005 ... read 0xfffffffffffffff...` inside its own
  image, ending in `WER ... crash.log`. Exit code `-1073741819` (0xC0000005).
- This is the run-98 failure mode: the builder writes bad bounding-box pointers
  into title memory; with `FIRSTLANE_OWN=1` an exact first-lane read is not
  guaranteed for the non-uniform sources, so the produced structures are
  corrupt.

**Conclusion for goal (3).** The builder pipeline can be made fully
constructible (`ready=53`) and can execute without fault **in quarantine**, but
with the current first-lane lowering it produces unusable BVH data, so it
cannot be enabled for real rendering. This is now proven, not suspected. The
blocker is exactly the `v_readfirstlane` approximation: an exact lowering needs
either per-lane-uniform proof (ruled out by the `why` distribution) or a safe
group barrier for the non-all-lanes block (not available on this host wave
split). Until one of those is implemented, `VICTORY_BVH_BUILDER=1` must stay
off for normal play; `report` and the `why` diagnostic are the safe interfaces.

### Every exact-path switch combination was tried and fails (2026-11-26)

To be sure the crash is not an avoidable configuration mistake, all
switch-only routes to an exact lowering were tested with
`VICTORY_BVH_BUILDER=report` (safe: no builder stage executes):

| Configuration | Builder census |
|---|---|
| default | `ready=50`, 3 failed |
| `VICTORY_FIRSTLANE_OWN=1` | `ready=53`, but approximate → crashes live |
| `VICTORY_WAVE_DEEP_SKIPS=1` | `ready=50`, same 3 failed |
| `VICTORY_WAVE_DEEP_SKIPS=1 VICTORY_WAVE_WIDE=1` | `ready=50`, same 3 failed |
| `VICTORY_WAVE_LOCAL=idiom` (earlier) | these programs refused, "not the allocation idiom" |

In every failing case the 3 programs report the same
`a first-lane read where not every lane runs is not supported` at
GFX10 offset `0x23c`/`0x258`. Deep skips and widen do **not** convert the
non-all-lanes block into one where the exact barrier path is safe, and local
waves take the same `mine` approximation. So there is no configuration that
gives an exact result: the only way to reach `ready=53` is the approximation
that crashes when consumed. This closes the switch-level search; a real fix
requires a translator change (an exact first-lane lowering for this block
shape), which is beyond a switch and was not attempted.

## UPDATE (later same day): the exact proof exists and was ported

The "ruled out by the `why` distribution" conclusion above was **wrong**. A
local peer, `uiliannn__VItoriaBr` (README line 189, commit `fe3aa3f` then
`809ba50`), implemented `value_uniform`: a recursive proof that a value is
the same in every console lane. Its decisive case is **`ds_read` at a uniform
address** — every lane reads the same LDS dword, which is exactly the wave's
running scan the BVH builder uses. My earlier `why` probe saw `ds_read2_b32`
and `v_cvt_u32_f32` as sources and concluded "per-lane, not uniform"; the
proof follows the address and the value's defining chain instead. With it,
the three first-lane shaders translate in wave32 and `FIRSTLANE_OWN` is no
longer needed (their README says 2 PSOs remain refused in the builder).

Ported into this worktree's `crates/victory-shader/src/emit/lower.rs`, faithful
to the peer implementation (`Uniform` enum, `lds_stable`, `operand_uniform`,
`value_uniform`), wired into the `alike` check at `v_readfirstlane_b32`:

- `cargo check -p victory-shader` (default and diagnostics): clean.
- Unit tests: 212 passed, 4 failed — the same 4 pre-existing ray-intersection
  tests as baseline (no regression).
- Live `VICTORY_BVH_BUILDER=report` **without** `VICTORY_FIRSTLANE_OWN`:
  `pipelines=53 ready=53 failed=[]`. The approximation is gone; all builder
  programs now translate on exact grounds.

**Remaining failure.** A non-quarantined live run (`VICTORY_BVH_BUILDER=1`,
no `FIRSTLANE_OWN`, no quarantine) still crashed with `0xC0000005` on bad
pointers, but later: ~140 s versus ~100 s with the approximation. So
`value_uniform` fixes the first-lane cause and is necessary, but BVH validity
is still broken by another issue.

### Narrowing the remaining crash (2026-11-26)

Two pieces of evidence from that run narrow what is left:

- **Missing-page accesses are ruled out.** The log shows no
  `shaders touched pages that had no copy` line — the fault counter stayed at
  zero. `memory.rs` records a fault whenever a raw-address access hits a page
  with no host copy, so the "lost store" candidate in `fork-ray-tracing.md` is
  not what is corrupting the BVH here.
- **The bad value is structured, not random.** At the first `0xC0000005` the
  faulting register was `rax = 0x7c007c00fc00fc00` — an interleaved
  `AB00AB00` byte pattern, characteristic of 16-bit data (the console's
  64-byte BVH box nodes hold 16-bit half-float bounds) being consumed as a
  64-bit pointer. That points at BVH node layout / bounds interpretation,
  which `fork-ray-tracing.md` lists under "assumed, not publicly documented":
  the instruction's rounding, equal-distance box order, and the ray-through-edge
  result.

This is a different class from the first-lane problem: it needs per-node
validation against the console's node format (a hardware oracle on a real AMD
GPU, like AnyPS5's approach, or the traversal-counter method DexNom used),
not a translator switch. No peer repo claims a fully working dynamic builder
on NVIDIA — `uiliannn`'s README still lists 2 refused builder PSOs. The honest
state at the end of this round: **first-lane is exact, builder constructs 53/53,
no missing-page faults, but BVH data still crashes the title ~140 s in, with
the signature of a node-layout/bounds error.** `VICTORY_BVH_BUILDER=1` remains
unsafe for normal play; `report` and `why` are the safe interfaces.

## Empty-slot guard: the ~140 s run had never contained it (2026-11-26)

The earlier "different class / node-layout error" conclusion was drawn from a
run that did **not** include the empty-slot guard. The guard (bvh.rs:202
`children[n] != NONE`, emit/intersect.rs:412 `child_present`) was written at
16:32-16:33, but `target/release/victory.exe` was still stamped 15:59:52;
`build7.txt`/`build8.txt` were two *interrupted* builds (36/37 lines, no
`Finished`). So the guard had never reached a binary, let alone been tested.

Its purpose matches the bad value exactly: an empty builder slot holds inverted
infinite bounds (min = +inf, max = -inf), which every ray enters at minus
infinity. Without the guard it sorts first and contributes the console's
`AB00AB00` half-float bounds (0x7c00 = +inf, 0xfc00 = -inf) as a child pointer.
DexNom `bc3cd4b0` and avatarmanz `810efe5` fix exactly this. The guard is now
ported faithfully and given two regression tests (bvh.rs
`an_empty_slot_is_never_entered`, intersect_tests.rs's inverted-bounds slot).

### Live result with the guard actually in the binary

Non-quarantined run, `VICTORY_BVH_BUILDER=1`, no `FIRSTLANE_OWN`, `-Guide` keys,
fresh `cargo build --release --features diagnostics -p victory`
(exe stamped 17:25:50), log `bvh_guard_run.log`:

- `the ray-tracing structure builder runs: all of its programs have host
  pipelines pipelines=53` at 17:31:25. The builder genuinely started.
- **Still crashed** at 17:31:35, exit `-1073741819` (0xC0000005), Breakpad
  `t:\victory-20261126-173135-46112.crash.log`. That is ~10 s after the builder
  began dispatching, ~171 s after process start (17:28:44).
- The bad-value **shape changed**. The old `rax = 0x7c007c00fc00fc00`
  (16-bit half ±inf interleaved) appears **zero** times in this log; the guard
  removes that class. Instead the first-chance faults carry 32-bit float
  infinities as addresses: `read 0x7f80002c` with `rcx = 0x7f800000`
  (+inf), later `rax = 0xff8000007f800000`, and an unhandled
  `read 0x7e007e000` with `rcx/rdx/rdi = 0xfc00fc00`. `0x7f800000` occurs
  14 times, `0xff800000` twice, `0xfc00fc00` twice, `0x7c007c00` zero times.
- No `shaders touched pages that had no copy` line; the missing-page class
  remains ruled out.

**Interpretation.** The empty-slot guard is necessary and now verified to
remove the half-float-sentinel pointer, but it is not sufficient: the builder
still writes (or traversal still reads) BVH data whose bounds values — now
32-bit float infinities, the wide/128-byte box-node form — are consumed as
child addresses. This points at the remaining gaps from `fork-ray-tracing.md`:
(a) the missing DispatchX flag-`0x20` counted-in-threads path
(avatarmanz `810efe5` / DexNom `bc3cd4b0`), where a builder rehydration stage
runs up to 64x its threads and stores over later structures — **not present in
this worktree** and a direct cause of corrupted bounds; and (b) the wide-node
bounds interpretation. Next: port the thread-dimensions fix and re-validate.

## Wave32 lowering: 8cc31ab then ccs03 980a273 (2026-11-26)

The highest priority moved to wave64 -> wave32 lowering: on this 32-lane RTX
host, seven compute programs were refused by D3D12 with `0x80070057` because
their DXIL still asked for `WaveSize(64)`, and a further one (`f133e35e`) did
not translate. Those refusals drop ~1870 draws/frame in the world.

**Ported coolfox `8cc31ab`** (victory-shader only): `DIVERGENT_MASK_EXCHANGE`,
`lane_uniform(..., ordered_lds)` with uniform-address `ds_read_b32`,
`reads_mask_as_data`/`scc_in` SCC handling, `restored_lanes` (resource.rs), and
the `supported()` gate in emit/mod.rs that refuses a wave==Some(64) result on a
32-lane host instead of handing a doomed WaveSize(64) PSO to the driver. Also
added `FourCC::ACCC` and the ACCC translate path so the `driver_loop` route is
meaningful. The digest-based scene_kernel exception was skipped: this tree's
`Container` does not keep `digest`.

Live result of 8cc31ab alone (exe 20:21:06, `wave32_run.log`): refused
`7 -> 0` — but the seven hashes merely became `does not translate: no wave32
lowering for this wave64 program`. They were still unusable; draw loss was
unchanged (`peakDrop ~12482`). `driver_loop` did not fire for `f133e35e`
because that container is DXIL, not ACCC. So the lowering core only changed
the shape of the refusal.

**Ported ccs03 `980a273`** (the missing piece): per-program, by container hash,
`with_wave_wide` / `with_firstlane_own` (thread-local, wrapped around
`emit::translate` in `translate_listed`); `warm`/`host_shader` use it; the two
`*_ONLY` environment lists are folded into the shader cache key (no stale
cross-talk). Hash tables are ccs03 HEAD's 6-entry versions. The `unmade` reason
log was already covered here by the more detailed `?why` (`make::missing`),
so it was not duplicated. The first-lane gate adds `firstlane_own_here()` as a
fallback after this tree's `value_uniform` proof.

Live result of 980a273 (exe 20:32:20, `p0_run.log`): `notTranslated` dropped
`8 -> 4` by hand count. The four WAVE_WIDE_DEFAULT programs
(`5dc3b259`, `6f225b64`, `369cbe90`, `2cc4c197`) now translate to wave32 and
disappear from the drop list; stable-world builder-off drop fell from ~1872
to ~414. Remaining non-translating hashes: `02384a60`, `6b82bc7d` (no known
fix in any peer), `2da4beb3` (coolfox `f4b48ad` guard fix, P1), `f133e35e`.
Note: `wave64-observe.ps1` mis-parses `notTranslated` on this tree's log
(it reads the hash from the next line; here `hash=... error=...` is one line),
so counts were taken by hand.

With `VICTORY_BVH_BUILDER=1` (non-quarantined, `p0_builder_run.log`): builder
genuinely started (`pipelines=53`, 20:39:55) then crashed `0xC0000005` at
20:40:05 (~10 s later, exit -1073741819). Bad-value census this run:
`0x7c007c00` x8, `0xfc00fc00` x2, no 32-bit-float infinities — still the
half-float ±Inf sentinel of bad BVH node data, and no missing-page access.
So lowering is fixed enough to restore the builder's pipelines, but the BVH
data correctness gap (thread-dimensions / node bounds, above) is what now
blocks a lit world. `VICTORY_BVH_BUILDER=1` stays unsafe for normal play.
