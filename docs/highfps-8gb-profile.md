# High-FPS 8 GB Profile

Machine-validated default for RTX 5070 Laptop 8 GB / 32 GB RAM with the Series S host.

## Launch

```powershell
.\tools\launch-highfps-8gb.ps1 -GameExe 'C:\path\to\game_scarlett_master.exe'
```

Dry-run the exact argument list:

```powershell
.\tools\launch-highfps-8gb.ps1 -GameExe 'C:\path\to\game_scarlett_master.exe' -PreviewOnly
```

## Profile

- Series S, DLSS Performance (960x540 internal -> 1920x1080 output)
- Frame Generation 2
- `VICTORY_LATE_WAIT=3`
- `VICTORY_ASYNC_SUBMIT=1`
- `VICTORY_CARD_ROOM_FOR_TARGETS_MB=3072`
- `VICTORY_CARD_ROOM_FOR_BUFFERS=1`
- `VICTORY_SLOT_EVICT=0`
- `VICTORY_WATER_LIGHT=1`
- `VICTORY_VIEW_REMAP=1`
- Texture fill/catchup/pool enabled; THIN and JOIN_PARTS disabled

## Measured result

A 240-second live run produced a 20.6 fps steady-state median. The final eight steady samples were 22.15 fps / 45.2 ms with 42-46 generated display fps, zero DLSS failures and zero hard errors.

Heavy texture scenes can still dip to 8-14 fps because the 8 GB texture room remains under pressure. Frame Generation doubles display cadence; it does not double real render fps.
