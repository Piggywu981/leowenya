# Wave64 → wave32 observer

`wave64-observe.ps1` reads a `victory` diag run log and prints the evidence that
a wave64→wave32 lowering change is meant to move. It is a pure log parser: it
does not touch the game, the GPU or the tree.

```
powershell -ExecutionPolicy Bypass -File tools\wave64-observe.ps1 run.log
powershell -ExecutionPolicy Bypass -File tools\wave64-observe.ps1 new.log -Baseline wave64-baseline.json
```

## What it reports and why

The host is an NVIDIA RTX 5070 Laptop with 32-lane waves. The console emits
64-lane waves. Any shader still carrying `WaveSize(64)` is refused by D3D12
with `E_INVALIDARG (0x80070057)`; its draws are dropped, so the picture and the
frame both lose them. The observer prints:

- `hostWaveMin/Max` — the host's wave width (a 32-lane card reads `32`);
- `refusedCount` + hash list — programs that translated but whose pipeline was
  refused. These are the primary target of the lowering work: the fix is in the
  emitter, not the translator. Before the lowering work this is **7** compute
  programs (`02384a60`, `2cc4c197`, `2da4beb3`, `369cbe90`, `5dc3b259`,
  `6b82bc7d`, `6f225b64`);
- `notTranslated` — programs that fail translation outright, a different line
  (`f133e35e`, a lane mask exchanged where not every lane runs). Before the
  lowering work this is **1**;
- `topDropReasons` / `peakDroppedPerFrame` — the on-screen cost. Before the
  lowering work the world drops about **1870 draws/frame** for "a stage of the
  ray-tracing structure builder, which is off", plus one per refused program.
  This is the number that should fall once the builder's wave64 programs can be
  lowered to 32 lanes and the builder is enabled.

The baseline snapshot `wave64-baseline.json` was captured before the lowering
work (2026-11-26, diag build, world scene at ~5000 draws). After a lowering run,
pass it with `-Baseline` to get a direct before→after delta. Keep the raw logs
too: they are gitignored (`run*.log`) but stay on disk for re-checking.

The refused-program hashes match the independent analysis in bvh-fix's
`docs/wave64-builder-diagnosis.md`; the observer is the repeatable form of that
one-off measurement.
