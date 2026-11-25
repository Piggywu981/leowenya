# leowenya

**leowenya** runs the Xbox Series build of the game natively on Windows PCs
with NVIDIA graphics cards, from game files you supply yourself. It is our
tuned tree based on [ztrx](https://github.com/Zettrox/ztrx) and
[VIctory](https://github.com/Marvisak/VIctory)/victory-fork, with a launcher
and settings A/B-tested on an RTX 5070 Laptop.

**This repository contains no game files or assets.** You need your own copy
of the game. Not affiliated with or endorsed by its developer or publisher.

## Status (2026-11-25)

Tested on Windows 11 with an **NVIDIA GeForce RTX 3050** (8 GB) upstream;
this fork is tuned and A/B-tested on an **RTX 5070 Laptop** (8 GB, Blackwell).
See our notes below.

| | |
|---|---|
| Boot, first-boot screens, intro, opening credits | works |
| Prologue | playable from the cell to the boat chase: cell, cafeteria, robbery, police chase (wanted level, minimap), boat, binoculars |
| Stability | 1 h 30 min+ in one session without a crash |
| Frame rate | menus 30 fps; 1-3 fps in the world (the first run is slower while shaders translate; they are cached after that) |
| Known problems | shadows no longer go fully black with the ambient floor on, but lit detail is approximate and bright scenes still overexpose (ray-traced lighting does not run yet); some blocky artifacts; boats sit low in the water |

## Requirements

- Windows 10/11 x64, a CPU with AVX2
- A Direct3D 12 GPU with shader model 6.6 and mesh shaders (NVIDIA RTX 20 series or newer)
- Rust (the version in `rust-toolchain.toml`)
- Several GB of free Windows commit memory (raise the paging file if `crashes.log` reports error 1455)

### Newest (2026-11-25, later the same day)

**Latest: driver watch, ported unchanged from victory-fork.**
- The layer now subscribes to the system event log's display-driver errors
  (`crates/victory-gpu/src/drvwatch.rs`, from victory-fork `a253706`, itself
  from the earlier frame-rate work). Every loss of the card in a run with
  draw windows was announced by such an entry 2.7 to 6.3 seconds ahead;
  now each is logged as it happens, counted in the periodic status, and the
  **first one turns draw windows off for the rest of the run**, so a driver
  fault costs a slower frame and not the card. On by default;
  `VICTORY_DRIVER_WATCH=0` subscribes to nothing. `windows()` (in draw.rs)
  now checks `!drvwatch::tripped()`. Verified on this machine: the EventLog
  subscription is accepted (`the_system_takes_the_subscription`) and the
  trip/count logic passes; full test suite has only the four pre-existing
  ray-intersection failures. This gives `run.ps1 -Window` a safety net; the
  window default is unchanged because an on/off frame-rate A/B is still
  owed.

**Pixel quad reads reach helper lanes at triangle edges.**
- In a pixel program, a quad read of another lane now goes through DXIL quad
  operations even for the helper lanes a triangle edge or a discard leaves
  in the quad. Host wave reads return 0 from helpers, so a hand-made
  derivative took the wrong (smallest) mip and drew lines along every
  triangle edge on car paint, glass and skin. Ported from upstream VIctory
  `4015a18` (and Belobug `03629f3`): `helpers_read_for` in
  `victory-shader/src/emit/lower.rs`, applied at both quad-local lane-read
  sites. The companion fix for `v_readfirstlane` (upstream `0601955`,
  Belobug `f520772`) is in too: a helper lane reads its own value, so a
  waterfall loop does not spin to its limit with a wrong descriptor.
  New test `pixel_quad_reads_reach_helpers`; full shader suite is 212 passed
  with only the four pre-existing ray-intersection failures. This is a
  picture-quality fix, not a frame-rate one.
  Live run on this machine (2026-11-25, diag build, first run with an empty
  shader cache): with `VICTORY_INDIRECT_WINDOW=1` and in-flight fetch off,
  the title booted, played its cutscenes and reached the 3D world; 2,000+
  frames captured, no device loss and no `crashes.log` entry. The picture
  is lit and textured (see `capture/frame-2048.png`): the missing magenta
  and black rooms are gone. The world is still overexposed with the fixed
  ambient level -- a picture-quality task for a later round. Frame-rate
  A/B against the window-off path still needs a warm cache.

**Indirect-draw window safety guard from CCS03.**
- The clamp shader drops garbage draw records asking for 2^23 vertices or
  instances an instance or more (they cannot be the title's meshes). CCS03
  traced the device losses of `VICTORY_INDIRECT_WINDOW` to such records: a
  window charges them once however often drawn, so a list of 90 of them ran
  1.5 billion vertices. The `MOST_DRAW` guard empties them in every path.
  `run.ps1 -Window` now makes the window switch available and forces
  in-flight fetch off (the two together also lost the device in CCS03).
  Still off by default; see "Tried and NOT in this tree" below. Verified:
  all WARP clamp tests pass, full workspace test has only the four pre-
  existing ray-intersection failures, release build clean.

**Later: texture mip-skip for small cards (commit `ae865f5`).**
- Host copies of large 2D textures the title fills leave out the two most
  detailed mips (`VICTORY_TEXTURE_MIP_SKIP=2`, **on by default** on cards under 10 GB): each level
  left out quarters the card memory of that texture, so on an 8 GB card far
  fewer textures stay un-hosted (black albedo). The staging reader follows
  with a kept prefix (`subresource_read_span` + `tiled_need` check) and views
  shift their level indices; copies into/out of such textures are refused.
  Ported from Comet's `e82716d`. A/B on this RTX 5070 Laptop 8 GB cut texture prep from 90-1700 ms to 6-20 ms; `run.ps1 -NoMipSkip` disables it; it trades a
  little fine detail for texture residency. The detile `TooSmall` bug found
  in the first port is fixed (verified: no warnings with the switch on).

**Evening: indirect light and the tuned launcher.**
- A constant indirect-light floor (`crates/victory-gpu/src/ambient.rs`,
  commit `a2ee402`; ported from Belobug via CCS03 PR24). The title's probe
  resolve (`CS_ScreenProbes_TemporalResolve_*`) has no traced rays feeding it,
  so its output was garbage or nothing. Just after that pass, a small compute
  shader writes a fixed value (level `0.6`, tint `1.0/0.98/0.94`) into the
  probe texture; the title's own lighting then applies it to surfaces.
  `VICTORY_AMBIENT=<level>` sets the level (`0` = none);
  `VICTORY_AMBIENT=off` leaves the title's output untouched. It lifts rooms
  out of pitch black, but the light is uniform from every direction and does
  not follow exposure or geometry; it goes away once ray tracing runs.
- `run.ps1` loads those settings and the perf switches A/B-tested on the RTX
  5070 Laptop (commit `bfd1e92`). See **Play this fork (run.ps1)** below.

**Update, the same night: the first room now renders right on the test
machine** (walls, textures, people, lamps), at 190 to 450 ms a frame (2 to 5
frames a second): the picture work has caught up, the frame rate has not.
What did it, on top of the list below:
- Descriptor records the title copies into its heap as plain bytes are
  mirrored before every submission (pull request #305 by Flyander, after
  upstream VIctory 86a5ed6). Measured here: about 40,000 records a frame
  that no call had announced; their host slots were empty or stale.
- A buffer view that does not start on an element of its buffer's host
  copy gets a copy of its own bytes instead of being refused (after
  upstream 86a5ed6): 3 to 6 such views a frame.
- Room on the card is kept for the render targets and buffer copies a
  world makes in its first frame: 98 buffer copies are made (945 MB) where
  the runs before made 1, and the processor no longer compares 550 to
  710 MB a frame looking for shader writes (25 MB now).
- Levels on demand ran on the card for the first time
  (`VICTORY_LEVELS_ON_DEMAND=1`, still off by default; with the fixes of
  pull request #747 by AscilCH): 3.1 GB of the card not allocated for
  texture levels the title does not hold, no device loss.
- Guarded blocks under storage writes are opened by default; 14 more
  shader programs translate; a program is translated with first-half
  interpolation pairs only if it was refused for one (with that on for
  every program, 8,551 working pixel programs came out changed).
- Frame rate, first cuts on the processor side: the descriptor sync uses a
  cheap fingerprint and leaves draw-table slots to their draws (the pass
  over the heap went from 70-220 ms a frame to about 3), and memory the
  guards already hold is not asked of the write watch (pull request #670
  by Jonirulah). Card copies' pieces can come down inside their own
  flights (pull request #648 by Jonirulah, `VICTORY_CARD_FETCH_INFLIGHT=1`,
  off by default: the copy-back thread's wait went from 181 ms a frame to
  0 here, but the card got busier, so no gain is claimed yet). The frame is
  still 250 to 380 ms: the card is the limit now, most of it the
  per-record clamp before each of some 6,700 indirect draws a frame.
- Indirect draws clamped in windows are available as an A/B switch
  (`run.ps1 -Window`, `VICTORY_INDIRECT_WINDOW=1`), still off by default.
  Pull request #220 cut the card's time here from about 100-150 to 35-80 ms
  a frame, but lost the device twice (once with a page fault on the card
  after 160 s). CCS03 traced those losses to two things and fixed both:
  a window charges a clamped record once however often it is drawn, so a
  list of 90 records of 2^24 vertices all ran (1.5 billion vertices in one
  list); and windows combined with in-flight fetch (#648) lost the device.
  This tree now has CCS03's `MOST_DRAW` guard: a draw of 2^23 vertices or
  instances an instance or more runs empty and charges nothing, window or
  not (clamp shader in `victory-gpu/src/indirect.rs`, WARP test
  `warp_budget_saturates_without_wraparound_and_preserves_draw_fields`).
  `-Window` also forces in-flight fetch off. It is still off by default:
  CCS03 lost the device once in eight runs even after the fix, and relies
  on a driver watch that is not in this tree. On their NVIDIA 8 GB cards
  windows measured 6.0 -> 8.9 fps in the first room.
- Known and counted, not fixed yet: an indirect compute pass asks for
  about 77,500 thread groups in x where one dispatch runs 65,535 (the
  rest is cut off).

Memory sync between the title's memory and the copies on the card:
- **A write through one view of a physical page is seen by the copies taken
  through its other views** (`VICTORY_VIEW_GUARD=0` turns it off). The title
  shows one page at several addresses and a copy was guarded at one of them
  only. Measured on the test machine: 0.8 to 1.0 million such writes in a
  five-minute run, every one of which used to leave a copy stale. Since it
  went in, the first room had its walls in the later frames of 4 runs out of
  4 (2 of 5 before); the room's very first shot still comes up without walls
  in some runs.
- Kernel reads into title memory are read beside and copied in, so a block
  guarded again in between no longer fails the read.
- Writes of the storage layer into physical pages are counted where the title
  has those pages mapped (10,000 to 50,000 guarded blocks of copies lay under
  them in every run) and can open the guards there:
  `VICTORY_PAGE_WRITES=guards` (off by default; `1`, `slots`, `all` do more).
- Failed page-destination reads are retried (`VICTORY_DSTORAGE_RETRIES=0` = as before).

Card memory (the test card is full from the first frame of the world: 85 to
99 % of its budget for a whole run, about 26,000 texture copies let go and
3,400 made again in five minutes, 2.8 GB of render targets that are all in
use):
- Levels on demand, **off by default** (`VICTORY_LEVELS_ON_DEMAND=1`): a
  texture the title fills takes card memory only for the levels the title
  holds (2.2 to 3.0 GB of the copies were levels it does not hold). Its test
  runs on the software adapter; it has not run on a card yet.
- Refused texture slots are held back for a few seconds so that a pass
  reaches the slots behind them (`VICTORY_FULL_CARD_PASS=0` = as before);
  room can be kept for the card copies of title buffers
  (`VICTORY_CARD_ROOM_FOR_BUFFERS=1`, off).

Tools and diagnostics:
- `victory translate <shader file> --warm all --jobs N` translates every
  shader ahead of a run, on the processor only (about 4.5 to 6.5 minutes
  here); the shader cache is keyed on the translator's source, so a new
  build that does not touch the translator starts warm.
- Counters, all off or diagnostics-only: `VICTORY_MERGE_RACE=1` (title bytes
  a copy-back is about to put back to older values: none found in 138,000
  copy-backs), `VICTORY_WALLS_TRACE`, `VICTORY_CARD_ACCOUNTING`, and a census
  of the copies the texture sweep never lets go.

### What this fork changed (summary)

Rendering:
- Meshlet culling read its scene buffers as the wrong kind of view, so the world drew almost nothing; fixed.
- Per-draw descriptor tables could run out, after which draws used slots never made for them and the card hung; fixed.
- Light packed by the game's compute shaders was read back through empty copies (sky, probes, fog); fixed for every mip level and layer.
- The fog reconstruction, shadow-mask, hair, blend-shape skinning, fire and several material programs did not translate; fixed.
- Gathers at a named mip level (with and without an offset) read level 0; fixed.
- Implicit-level samples outside pixel shaders produced invalid DXIL in 730 compute programs; fixed.
- Rectangle lists, depth and stencil twins for depth textures written by compute, texture read-backs.
- Ray tracing, in progress and off by default: the game's own structure-builder programs translate, title memory can be read by raw address from shaders, the hardware ray/box and ray/triangle test is emulated in DXIL (checked against a reference on the GPU), and 59 of the 64 trace programs translate. Nothing is lit by it yet. See [docs/fork-ray-tracing.md](docs/fork-ray-tracing.md).
- Indirect diffuse light is a constant floor while rays do not run (see above); the title's empty probe resolve no longer decides how dark a room is.
- The ambient light has a tunable warm-white colour (VICTORY_AMBIENT_TINT=r,g,b) and,
  where the light resolve reads the scene depth, less of it in creases and under objects
  (VICTORY_AMBIENT_SHADE=strength,radius,near,tanY; from Belobug via cd9f78c/4ffc476).
  Falls back to flat light when the depth view is not found.
- Integer render targets never blend (Belobug 86292110): D3D12 refuses blending on R8_UINT etc with E_INVALIDARG, and every draw on such a pipeline was silently lost (e.g. the first room walls). The host blend state now disables blending per integer target.

Speed and memory:
- Waits for memory values, write-watch queries and page queries no longer walk page tables per call.
- Large title buffers get a copy in card memory, with shader writes found by hashing on the card.
- Card-copy fetches fold into the submitting flight (`VICTORY_CARD_FETCH_INFLIGHT=1`, default on): the copy-back thread no longer waits on a separate fence. A/B on the RTX 5070 Laptop 8 GB cut copying-back from 338-452 ms to 37-81 ms per frame (from upstream victory-fork 9376fd6). `run.ps1 -NoFetchInflight` disables it.
- Only a shader that can store by address declares title-memory copies written (PR916, from victory-fork): the ray-tracing structure builder reads by address but stores through views, so it used to mark every 4 MiB copy written -- 12 GB compared/frame. Copy-back stays 42-67 ms/frame in our runs.
- Submissions can be sent ahead of the wait for the card (`VICTORY_LATE_WAIT`), with a relay thread that lands results as the card finishes (`VICTORY_RELAY`): in a first five-minute run the card's idle time behind the submitting thread fell from about 136 to 30 ms per frame.
- Title memory can be opened as a graphics heap so that buffers are used in place instead of copied (`VICTORY_INPLACE`, first stage only; a probe confirmed the approach on the test GPU).
- The bindless texture queue no longer uploads stale views; the view table no longer grows without bound; the pipeline library is mapped instead of read into memory.
- An intermittent device loss was traced to the pipeline library file being replaced while mapped; fixed.

- Translated shaders get clean-up passes over the finished module (dead code, constant folding, reuse of values, branch facts); the pack's host instruction count falls by about 43 %, worth about 20 ms of GPU time per frame on the test machine (`VICTORY_SHADER_OPT=0` turns them off).

Most of the newer speed changes sit behind environment switches that are off
by default (`VICTORY_LATE_WAIT`, `VICTORY_RELAY`, `VICTORY_WIDE_BACK`,
`VICTORY_CARD_BUFFERS_MIN_MB`, `VICTORY_INPLACE`, `VICTORY_BVH_BUILDER`, ...).
Each is described in a comment where it is read.

### Known problems

- Indirect light is a constant, not real bounce light: rooms are no longer pitch black, but shading stays flat and exposure is not followed (see above).
- The interior of the first gameplay room is sometimes not drawn after the cutscene hands over to gameplay.
- Around 24 GB of memory is in use during play.
- A few style lints are switched off for this fork in the workspace `Cargo.toml` until the newer code is tidied.
- Many changes here are specific to this title and this GPU, and some are marked `shortcut:` in the code where they approximate what the console does.

Everything below this line is upstream VIctory's own README, unchanged; its
status section describes upstream, not this fork.

---

# VIctory

Runs the title (Xbox Series X|S) natively on Windows, from files
the user supplies.

The title's x86-64 code runs unchanged inside our process; VIctory supplies
the platform underneath it and converts the title's data, ahead of time where
it can and on first use where it must (shaders). See
[docs/architecture.md](docs/architecture.md).

## Status (2026-11-23)

**Not playable yet.** The title boots, runs its menus at its own 30 fps and
loads the world, where rendering fails.

| Stage | State |
|-------|-------|
| Boot, first-boot screens (accessibility, language, settings, legal) | works, 30 fps |
| Intro video with sound | works |
| Start screen, profile and saves | works |
| Loading into the world (about 50 s) | works |
| The world (first mission's intro) | reached and runs with indirect draws; its title card renders, the scene after it is still dark; 0.5-1.8 s per frame |

Tested on one machine: Windows 11, AMD RX 6700 XT.

> **Warning.** Entering the world on a real GPU can currently hang it, and
> Windows then resets the display driver (every monitor goes black for a
> moment). To look further, use a diagnostics build with
> `VICTORY_D3D12_WARP=1`, which renders on the software adapter.

What each part does today and what it still needs:

| Subsystem | Today | Needs |
|-----------|-------|-------|
| Loader | Runs the title's executable and its DLLs in our process; crash reports name the faulting code and are kept in `crashes.log` | – |
| Runtime services | One signed-in offline user, licences, packages, saves that survive a kill at any step, text entry dialog | Speech is silent; the dialog and relaunch are untested live |
| Network | Offline by design: the title cannot reach the network | – |
| Files and streaming | Archives and streamed data read, zlib and BCPack decoded in parallel | Loading is limited by writes into title memory |
| Input | XInput pads, keyboard, keyboard stand-in pad | Trigger rumble |
| Audio | Menu, video and loading sound; XMA voices and Opus streams decode | Reverb is silent; Opus results unverified against the title |
| GPU: menus | Draws, compute and presentation on host D3D12; only changed title memory is copied | Frame pacing drifts on one screen in release builds |
| GPU: world | Mesh pipelines, shader-written buffers, descriptor lifetimes, indirect execution (arguments clamped), pipelines made by worker threads and kept on disk | Most of the scene is still missing (untranslated shaders drop draws); frames take seconds; real queries, depth bounds, HDR and scaling are missing |
| Shaders | Console GPU code recompiled to DXIL at first use, cached on disk. Menus: all. World: mesh 8,191 of 8,506, vertex/pixel 10,617 of 12,346, compute 1,643 of 2,539 | 64-bit image atomics, merged geometry stages, the ray-tracing builder's shaders; some compute programs need a GPU with 64-lane waves |
| Textures | Console tiled layouts and detiling for the modes the title uses | Render-target metadata planes |
| Series S mode | Runs through the menus to the loading screen | The world, as above |

## Getting started

Requirements: Windows 10/11 x64, a CPU with AVX2, a Direct3D 12 GPU with
shader model 6.6 (and mesh shaders for the world), Rust (pinned in
`rust-toolchain.toml`).

The title also needs several GiB of available Windows commit at startup.
Check **Committed** under **Task Manager → Performance → Memory**. If
`crashes.log` reports Windows error 1455, close other applications or increase
the Windows paging file size, then retry.

```powershell
cargo xtask install-hooks                # asset-policy check on every commit
copy victory.example.toml victory.toml   # then set your paths (outside the repo)
cargo test --workspace                   # needs no game data
cargo run -p victory -- config           # check your paths
```

### Play this fork (run.ps1)

Build once, then use the launcher; it keeps the shader cache and saves in
`%LOCALAPPDATA%\ztrx\cache` and `%LOCALAPPDATA%\ztrx\data` — the folder keeps
its old `ztrx` name so existing saves and shader caches still load; never
delete the data folder to fix a shader problem. Point `-Game` at your own copy of the
title's executable if it is not at the path in the script.

```powershell
cargo build --release -p victory
powershell -ExecutionPolicy Bypass -File run.ps1
powershell -ExecutionPolicy Bypass -File run.ps1 -Guide -Profile diag  # scripted first-run wizard
powershell -ExecutionPolicy Bypass -File run.ps1 -NoAmbient  # A/B: leave the title's own probe output
powershell -ExecutionPolicy Bypass -File run.ps1 -NoTune     # A/B: only ambient, no perf switches
```

The launcher sets `VICTORY_AMBIENT=0.6` and a bundle of perf switches A/B-tested
on this card: `VICTORY_LEVELS_ON_DEMAND=1`, `VICTORY_RELAY=2`,
`VICTORY_LATE_WAIT=3`, `VICTORY_WIDE_BACK=1`, `VICTORY_CARD_REHASH_RUNS=1`,
`VICTORY_JOIN_COPIES=1`, `VICTORY_WIDE_REFRESH=1`. `-NoTune` drops all of them.
`-Guide` sends `VICTORY_KEYS` for the first-run wizard and needs `-Profile diag`;
no buttons are pressed during normal play. Output is mirrored to `run.log`.

---

# Upstream integration notes (victory-fork, merged 2026-11-25)

The following notes come from upstream victory-fork and describe the fixes now merged into this tree. Environment switches are off unless stated.

```powershell
cargo build --release -p victory
```

## Play

```powershell
powershell -ExecutionPolicy Bypass -File scripts\play.ps1 -Game "<your game folder>\<the game's exe>"
```

`scripts\play.ps1` keeps the shader cache and saves in folders you choose
(`-Cache`, `-Data`) and presses no buttons for you. Controller: XInput pads
(a DualShock/DualSense through DS4Windows works). With no pad connected the
keyboard acts as one while the game window has focus.

## Faster settings (optional, off by default)

`VICTORY_RELAY=2`, or `VICTORY_LATE_WAIT=3 VICTORY_WIDE_BACK=1` cut frame
time on the test machines. Set them in PowerShell before running the script.

## Debugging switches

| Switch | Effect |
|---|---|
| `VICTORY_CAPTURE=<dir>` + `VICTORY_CAPTURE_FRAMES=<list>` | save those frames as PNG (diagnostics build) |
| `VICTORY_KEYS=30:Enter,35:X` | press keys at those seconds (diagnostics build) |
| `VICTORY_D3D12_DRED=1` | on a GPU failure, report the commands in flight |
| `VICTORY_PIPELINE_WAIT_MS=24` | shorter per-frame wait for pipelines still being built |

Diagnostics build: `cargo build --profile diag -p victory --features diagnostics`

## License

GPL-3.0-or-later (see `LICENSE`). Based on VIctory (Marvisak) and victory-fork (fxceless).
