# One-shot launcher for GTA VI on NVIDIA GPUs, with settings tuned on
# RTX 5070 Laptop 8 GB. Based on DEVLOG A/B runs 2026-11-25.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File run.ps1
#   powershell -ExecutionPolicy Bypass -File run.ps1 -Guide      # walk the first-run wizard with scripted keys
#   powershell -ExecutionPolicy Bypass -File run.ps1 -NoAmbient  # A/B: leave ray-traced indirect light as-is
#   powershell -ExecutionPolicy Bypass -File run.ps1 -NoTune     # A/B: only ambient, no perf switches
param(
  [switch]$Guide,
  [switch]$NoAmbient,
  [switch]$NoTune,
  [switch]$MipSkip,
  [string]$Game = 'G:\Leonida\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe',
  [string]$Profile = 'release'   # release (faster) or diag (capture/keys)
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$exe = if ($Profile -eq 'diag') {
  Join-Path $root 'target\diag\victory.exe'
} else {
  Join-Path $root 'target\release\victory.exe'
}
if (-not (Test-Path $exe)) { throw "Build first: cargo build --release -p victory (or --profile diag)" }

# --- paths: data is separate from cache; never delete data to fix a shader problem ---
$env:VICTORY_GAME_DIR = Split-Path -Parent $Game
$env:VICTORY_CACHE_DIR = "$env:LOCALAPPDATA\ztrx\cache"
$env:VICTORY_DATA_DIR  = "$env:LOCALAPPDATA\ztrx\data"

# --- indirect light: constant until ray tracing runs (a2ee402) ---
if ($NoAmbient) {
  $env:VICTORY_AMBIENT = 'off'   # leave the title's own probe output
} else {
  $env:VICTORY_AMBIENT = '0.6'
}

# --- performance switches, A/B-tested on this card 2026-11-25 ---
if (-not $NoTune) {
  $env:VICTORY_LEVELS_ON_DEMAND = '1'   # only hold mip levels the title uses
  $env:VICTORY_RELAY            = '2'   # land copy-backs beside the submitting thread
  $env:VICTORY_LATE_WAIT        = '3'   # late waits + present behind flights
  $env:VICTORY_WIDE_BACK        = '1'
  $env:VICTORY_CARD_REHASH_RUNS = '1'
  $env:VICTORY_JOIN_COPIES      = '1'   # one kernel step for adjacent copies
  $env:VICTORY_WIDE_REFRESH     = '1'   # refresh copies on a thread
  # VICTORY_WIDE_TEXTURES=1 is available but off: A/B on this 8 GB card showed
  # no clear gain (CCS03's gain was on a 3090 Ti where textures can reside).
  # -MipSkip: drop the two most detailed mips of host copies on small cards so
  # textures can reside; trades a little detail for fewer black surfaces.
  if ($MipSkip) {
    $env:VICTORY_TEXTURE_MIP_SKIP = '2'
    $env:VICTORY_TEXTURE_MIP_SKIP_MIN = '512'
  }
} else {
  foreach ($v in 'VICTORY_LEVELS_ON_DEMAND','VICTORY_RELAY','VICTORY_LATE_WAIT',
                'VICTORY_WIDE_BACK','VICTORY_CARD_REHASH_RUNS','VICTORY_JOIN_COPIES',
                'VICTORY_WIDE_REFRESH','VICTORY_WIDE_TEXTURES',
                'VICTORY_TEXTURE_MIP_SKIP','VICTORY_TEXTURE_MIP_SKIP_MIN') {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
  }
}

# --- first-run wizard: Enter=A, Down moves the cursor; 5s on photosensitivity ---
if ($Guide -and $Profile -eq 'diag') {
  $env:VICTORY_KEYS = '10:Down,14:Down,18:Enter,28:Down,32:Down,36:Enter,' +
    '46:Down,50:Down,54:Enter,64:Down,68:Down,72:Enter,84:Down,88:Down,92:Enter,' +
    '104:Down,108:Down,112:Enter'
} elseif (-not $Guide) {
  Remove-Item Env:VICTORY_KEYS -ErrorAction SilentlyContinue
}

$log = Join-Path $root 'run.log'
Write-Host "Launching $exe with AMBIENT=$(if($NoAmbient){'off'}else{'0.6'}), TUNE=$(-not $NoTune), GUIDE=$Guide"
Write-Host "Log: $log"
& $exe run $Game --unimplemented zero --execute 2>&1 | Tee-Object -FilePath $log
Write-Host "Exited with $LASTEXITCODE"
