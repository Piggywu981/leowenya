# BVH builder visual A/B method (for after the bvh-fix merge)

When bvh-fix's thread-dimensions fix lands in main, the question is no longer
"are shaders refused" (that is already 0) but: does
`VICTORY_BVH_BUILDER=1` stay alive and does the 3D world get its ray-traced
indirect light (the dark interiors brighten). This is a two-arm A/B with the
same scene, cache and switches; the only difference is the builder switch.

`bvh-ab.ps1` wraps one arm. Run it twice, once per switch value, then compare
the summaries and look at the captured screens with see-now.

```
# Arm A — builder off (the current default)
powershell -ExecutionPolicy Bypass -File tools\bvh-ab.ps1 -Builder 0
# Arm B — builder on (bright interiors, but crashes before the fix)
powershell -ExecutionPolicy Bypass -File tools\bvh-ab.ps1 -Builder 1
```

Each arm writes `bvh-ab-off.log` / `bvh-ab-on.log` in the repo root and prints
a short summary: whether the process survived the window, whether the builder
reported "runs" or "stays off", the refused/do-not-translate/dropped counts,
and the last stable world frame line. Logs are gitignored (`run*.log` is not —
these are `bvh-ab-*.log`, so add them to the ignore list if you want them out
of `git status`; they are kept on disk on purpose).

## What to compare

1. **Survival**: before the fix, builder=1 crashes with `0xC0000005` roughly
   10 s after "the ray-tracing structure builder runs". After the fix it must
   survive the whole window. The script reports exit and any new crash log in
   `%LOCALAPPDATA%\ztrx\data\<id>\temp\`.
2. **Builder state**: grep the log for "the ray-tracing structure builder
   runs" / "stays off". If it stays off, the build-fix merge did not take
   effect (or a builder program still lacks a pipeline — the warning names
   them).
3. **Picture**: with see-now, walk to the same place in both arms (the first
   interior with no direct sun is the useful spot) and compare: the builder-off
   arm has black shadowed areas (only the ambient stand-in); the builder-on arm
   should show bounce light in those areas. A picture difference with the
   frame count unchanged is the expected win.
4. **Frame cost**: compare the stable-world ms/frame in the log. Ray tracing
   costs frames; a bright but unplayable build is still a result worth
   reporting, not a pass.

## Caveats

- If see-now's floating window was closed by the user, do not reopen it; use
  the log survival/builder-state evidence instead and say the picture was not
  observed.
- Keep the two arms apart in time (one GPU); never run both at once.
- The shader cache is shared; the builder switch is not part of its key, so a
  cache hit is fine here — the builder decision is made at pipeline creation,
  not at translation.
- This file is written before the fix lands; update the survival expectation
  when the merge happens if the crash signature changes.
