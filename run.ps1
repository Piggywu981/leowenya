# One-shot launcher for GTA VI on NVIDIA GPUs, with settings tuned on
# RTX 5070 Laptop 8 GB. Based on DEVLOG A/B runs 2026-11-25.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File run.ps1
#   powershell -ExecutionPolicy Bypass -File run.ps1 -Guide      # walk the first-run wizard with scripted keys
#   powershell -ExecutionPolicy Bypass -File run.ps1 -NoAmbient  # A/B: leave ray-traced indirect light as-is
#   powershell -ExecutionPolicy Bypass -File run.ps1 -NoTune     # A/B: only ambient, no perf switches
#   powershell -ExecutionPolicy Bypass -File run.ps1 -Window      # A/B: clamp indirect draws in windows
#   powershell -ExecutionPolicy Bypass -File run.ps1 -Window -Gather  # A/B: also gather scattered records (needs -Window)
#   powershell -ExecutionPolicy Bypass -File run.ps1 -NoTextureNoWait  # A/B: texture refresh waits for the title's remap
#   powershell -ExecutionPolicy Bypass -File run.ps1 -HeapWorker    # A/B: texture uploads on their own thread (needs -LateWait/default tune)
param(
  [switch]$Guide,
  [switch]$NoAmbient,
  [switch]$NoTune,
  [switch]$NoMipSkip,
  [switch]$NoFetchInflight,
  [switch]$NoTextureNoWait,
  [switch]$HeapWorker,
  [switch]$Window,
  [switch]$Gather,
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
  # Texture refreshes must not wait for the title to hold its memory still:
  # measured here textures 28-206 ms -> 27-73 ms, and endevslab's A/B found
  # the lock wait was 964 ms of a 2780 ms frame. -NoTextureNoWait restores it.
  if ($NoTextureNoWait) {
    $env:VICTORY_TEXTURE_NO_WAIT = '0'
  } else {
    $env:VICTORY_TEXTURE_NO_WAIT = '1'
  }
  # VICTORY_WIDE_TEXTURES=1 is available but off: A/B on this 8 GB card showed
  # no clear gain (CCS03's gain was on a 3090 Ti where textures can reside).
  # mip-skip is on by default on small cards: drop the two most detailed mips
  # of host copies so textures can reside (A/B: texture prep 90-1700ms -> 6-20ms).
  # -NoMipSkip turns it off for comparison.
  if ($NoMipSkip) {
    $env:VICTORY_TEXTURE_MIP_SKIP = '0'
  }
  # Card-copy fetches fold into the submitting flight by default: A/B on this
  # card cut copying-back from 338-452 ms to 37-81 ms per frame.
  # -NoFetchInflight turns it off for comparison.
  # Window clamps (CCS03): 100-150 ms -> 35-80 ms of GPU time per frame here.
  # They MUST NOT run together with in-flight fetch: that combination lost
  # the device in CCS03's runs. -Window therefore forces fetch off.
  $fetchOff = $NoFetchInflight -or $Window
  if ($fetchOff) {
    $env:VICTORY_CARD_FETCH_INFLIGHT = '0'
  } else {
    $env:VICTORY_CARD_FETCH_INFLIGHT = '1'
  }
  if ($Window) {
    $env:VICTORY_INDIRECT_WINDOW = '1'
  } else {
    Remove-Item 'Env:VICTORY_INDIRECT_WINDOW' -ErrorAction SilentlyContinue
  }
  # Gather scattered indirect records for the list's prelude (victory-fork
  # 465b94f, 10.3 fps): needs windows on. -Gather forces -Window.
  if ($Gather) {
    $env:VICTORY_INDIRECT_WINDOW = '1'
    $env:VICTORY_INDIRECT_GATHER = '1'
    $env:VICTORY_CARD_FETCH_INFLIGHT = '0'
  } else {
    Remove-Item 'Env:VICTORY_INDIRECT_GATHER' -ErrorAction SilentlyContinue
  }
  # Texture uploads on our own thread. Needs VICTORY_LATE_WAIT (set above),
  # so it only takes effect with the default tune; upstream measured the boat
  # mission 6.2-6.7 -> 8.65-9.53 fps on an RTX 4070. Off unless -HeapWorker.
  if ($HeapWorker) {
    $env:VICTORY_HEAP_WORKER = '1'
  } else {
    Remove-Item 'Env:VICTORY_HEAP_WORKER' -ErrorAction SilentlyContinue
  }
} else {
  foreach ($v in 'VICTORY_LEVELS_ON_DEMAND','VICTORY_RELAY','VICTORY_LATE_WAIT',
                'VICTORY_WIDE_BACK','VICTORY_CARD_REHASH_RUNS','VICTORY_JOIN_COPIES',
                'VICTORY_WIDE_REFRESH','VICTORY_WIDE_TEXTURES',
                'VICTORY_TEXTURE_MIP_SKIP','VICTORY_TEXTURE_MIP_SKIP_MIN',
                'VICTORY_CARD_FETCH_INFLIGHT','VICTORY_INDIRECT_WINDOW','VICTORY_INDIRECT_GATHER',
                'VICTORY_TEXTURE_NO_WAIT','VICTORY_HEAP_WORKER') {
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
$winOn = ($Window -or $Gather) -and -not $NoTune
$fetchOn = -not $NoTune -and -not $NoFetchInflight -and -not $winOn
$gatherOn = $Gather -and -not $NoTune
$noWaitOn = -not $NoTune -and -not $NoTextureNoWait
$heapOn = $HeapWorker -and -not $NoTune
Write-Host "Launching $exe with AMBIENT=$(if($NoAmbient){'off'}else{'0.6'}), TUNE=$(-not $NoTune), WINDOW=$winOn, GATHER=$gatherOn, FETCH=$fetchOn, NOWAIT=$noWaitOn, HEAPWK=$heapOn, GUIDE=$Guide"
Write-Host "Log: $log"
& $exe run $Game --unimplemented zero --execute 2>&1 | Tee-Object -FilePath $log
Write-Host "Exited with $LASTEXITCODE"
