# One arm of a settle/copy-path A/B on the release exe.
#   powershell -ExecutionPolicy Bypass -File tools\settle-ab.ps1 -Var VICTORY_WIDE_MERGE -Value 0 -Tag wm_off -Seconds 150
#   powershell -ExecutionPolicy Bypass -File tools\settle-ab.ps1 -Var VICTORY_WIDE_MERGE -Value 1 -Tag wm_on  -Seconds 150
#
# Methodology (after bvh-fix's "uneven sample stage" trap):
#  * same exe, same default tune, ONE variable differs;
#  * fixed window; parse only the WORLD-STABLE segment: the first settle summary
#    whose (shader-writes + title-read) > 400 ms marks world entry (T0), and
#    every metric is kept only for logical lines timestamped >= T0 + 5 s;
#  * report n / median / p10 / p90 / min / max per metric so arms can be checked
#    for comparability before any causal claim.
param(
    [Parameter(Mandatory)][string]$Var,
    [Parameter(Mandatory)][string]$Value,   # '__UNSET__' removes the variable
    [Parameter(Mandatory)][string]$Tag,
    [int]$Seconds = 360,
    [string]$Profile = 'release',
    [string]$Game = 'G:\Leonida\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe',
    [string[]]$Extra = @()   # extra "VAR=VALUE" overrides applied AFTER $Var (e.g. -Extra 'VICTORY_LATE_WAIT=0')
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "target\$Profile\victory.exe"
if (-not (Test-Path $exe)) { throw "No exe: $exe" }
if (-not (Test-Path $Game)) { throw "No game exe: $Game" }
$log = Join-Path $root "ab-$Tag.log"

# === identical default tune for every arm (mirrors run.ps1 / bvh-ab.ps1) ===
$env:VICTORY_GAME_DIR = Split-Path -Parent $Game
$env:VICTORY_CACHE_DIR = "$env:LOCALAPPDATA\ztrx\cache"
$env:VICTORY_DATA_DIR  = "$env:LOCALAPPDATA\ztrx\data"
$env:VICTORY_AMBIENT   = '0.6'
foreach ($k in 'VICTORY_LEVELS_ON_DEMAND','VICTORY_RELAY','VICTORY_LATE_WAIT',
               'VICTORY_WIDE_BACK','VICTORY_CARD_REHASH_RUNS','VICTORY_JOIN_COPIES',
               'VICTORY_WIDE_REFRESH','VICTORY_TEXTURE_NO_WAIT','VICTORY_CARD_FETCH_INFLIGHT',
               'VICTORY_WIDE_MERGE','VICTORY_CARD_WINDOWS_MB',
               'VICTORY_INPLACE','VICTORY_INPLACE_MB') {
  Remove-Item "Env:$k" -ErrorAction SilentlyContinue
}
$env:VICTORY_LEVELS_ON_DEMAND  = '1'
$env:VICTORY_RELAY             = '2'
$env:VICTORY_LATE_WAIT         = '3'
$env:VICTORY_WIDE_BACK         = '1'
$env:VICTORY_CARD_REHASH_RUNS  = '1'
$env:VICTORY_JOIN_COPIES       = '1'
$env:VICTORY_WIDE_REFRESH      = '1'
$env:VICTORY_TEXTURE_NO_WAIT   = '1'
$env:VICTORY_CARD_FETCH_INFLIGHT = '1'
# The sole variable under test:
if ($Value -eq '__UNSET__') { Remove-Item "Env:$Var" -ErrorAction SilentlyContinue }
else { Set-Item "Env:$Var" $Value }
# Extra overrides (for arms needing two variables, e.g. INPLACE=2 + LATE_WAIT=0).
foreach ($e in $Extra) {
  $eq = $e.IndexOf('=')
  if ($eq -gt 0) {
    $ek = $e.Substring(0, $eq); $ev = $e.Substring($eq + 1)
    if ($ev -eq '__UNSET__') { Remove-Item "Env:$ek" -ErrorAction SilentlyContinue }
    else { Set-Item "Env:$ek" $ev }
  }
}
# Scripted first-run keys so every arm reaches the world the same way.
$env:VICTORY_KEYS = '10:Down,14:Down,18:Enter,28:Down,32:Down,36:Enter,' +
    '46:Down,50:Down,54:Enter,64:Down,68:Down,72:Enter,84:Down,88:Down,92:Enter,' +
    '104:Down,108:Down,112:Enter'

Write-Host "ARM tag=$Tag $Var=$Value profile=$Profile window=${Seconds}s -> $log"
$saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try {
  $proc = Start-Process -FilePath $exe `
    -ArgumentList @('run', $Game, '--unimplemented', 'zero', '--execute') `
    -PassThru -RedirectStandardOutput "${log}.out" -RedirectStandardError "${log}.err"
  if (-not $proc.WaitForExit($Seconds * 1000)) {
    Write-Host "window elapsed; stopping PID $($proc.Id)"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $proc.WaitForExit(5000) | Out-Null
    $survived = $true; $exitCode = 'window-timeout (stopped intentionally)'
  } else { $survived = $false; $exitCode = $proc.ExitCode }
} finally { $ErrorActionPreference = $saved }
Get-Process victory -ErrorAction SilentlyContinue | ForEach-Object {
  Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
# merge streams into one searchable log
$all = ''
foreach ($p in @("${log}.err", "${log}.out")) { if (Test-Path $p) { $all += (Get-Content $p -Raw -ErrorAction SilentlyContinue) } }
$all | Out-File $log -Encoding utf8
Remove-Item "${log}.err","${log}.out" -Force -ErrorAction SilentlyContinue

# === parse logical lines (timestamped line + its wrapped continuation) ===
$raw = Get-Content $log
$logical = New-Object System.Collections.Generic.List[string]
foreach ($ln in $raw) {
  if ($ln -match '^\d{4}-\d\d-\d\dT[\d:.]+Z') { $logical.Add($ln) }
  elseif ($logical.Count -gt 0) { $logical[$logical.Count-1] = $logical[$logical.Count-1] + ' ' + $ln.Trim() }
}
$settle = New-Object System.Collections.Generic.List[object]
$frame  = New-Object System.Collections.Generic.List[object]
$inpl   = New-Object System.Collections.Generic.List[object]
foreach ($L in $logical) {
  $tsm = [regex]::Match($L, '^([\d]{4}-\d\d-\d\dT[\d:.]+)Z')
  if (-not $tsm.Success) { continue }
  $t = [datetime]::Parse($tsm.Groups[1].Value)
  if ($L -match 'of the waiting for the card in settles') {
    $m = [regex]::Match($L, 'shader writes ([\d.]+), title memory read ([\d.]+)')
    if ($m.Success) {
      $sw = [double]$m.Groups[1].Value; $rd = [double]$m.Groups[2].Value
      $settle.Add([pscustomobject]@{t=$t; sw=$sw; rd=$rd; sum=$sw+$rd})
    }
  }
  if ($L -match 'title memory in place: (\d+) windows (\d+) MB, (\d+) title buffers (\d+) MB') {
    $inpl.Add([pscustomobject]@{
      t=$t
      winN=[int]$Matches[1]; winMB=[int]$Matches[2]
      bufN=[int]$Matches[3]; bufMB=[int]$Matches[4]
    })
  }
  if ($L -match 'INFO victory_gpu::host: [\d.]+ fps') {
    $mf = [regex]::Match($L, '([\d.]+) ms/frame')
    $cp = [regex]::Match($L, 'copies ([\d.]+) ms ([\d.]+) MB')
    $gp = [regex]::Match($L, '([\d.]+) on the GPU')
    $cb = [regex]::Match($L, '([\d.]+) copying back ([\d.]+) MB')
    if ($mf.Success) {
      $frame.Add([pscustomobject]@{
        t=$t; ms=[double]$mf.Groups[1].Value
        copiesMs=$(if($cp.Success){[double]$cp.Groups[1].Value}else{0})
        copiesMB=$(if($cp.Success){[double]$cp.Groups[2].Value}else{0})
        gpu=$(if($gp.Success){[double]$gp.Groups[1].Value}else{0})
        copybackMs=$(if($cb.Success){[double]$cb.Groups[1].Value}else{0})
        copybackMB=$(if($cb.Success){[double]$cb.Groups[2].Value}else{0})
      })
    }
  }
}
# world entry from settle summaries
$t0 = $null
foreach ($s in $settle) { if ($s.sum -gt 400) { $t0 = $s.t; break } }
$stable = $null
if ($t0) { $stable = $t0.AddSeconds(15) }
$swS = @($settle | Where-Object { $stable -and $_.t -ge $stable } | ForEach-Object {$_.sw})
$rdS = @($settle | Where-Object { $stable -and $_.t -ge $stable } | ForEach-Object {$_.rd})
$sumS= @($settle | Where-Object { $stable -and $_.t -ge $stable } | ForEach-Object {$_.sum})
$fms = @($frame  | Where-Object { $stable -and $_.t -ge $stable } | ForEach-Object {$_.ms})
$cms = @($frame  | Where-Object { $stable -and $_.t -ge $stable } | ForEach-Object {$_.copiesMs})
$cmb = @($frame  | Where-Object { $stable -and $_.t -ge $stable } | ForEach-Object {$_.copiesMB})
$ipStable = @($inpl | Where-Object { $stable -and $_.t -ge $stable })
$ipWinMB  = @($ipStable | ForEach-Object {$_.winMB})
$ipBufMB  = @($ipStable | ForEach-Object {$_.bufMB})
# notTranslated: shader does not translate lines, unique hash on the physical next line
$notTransHashes = @()
for ($i = 0; $i -lt $raw.Count - 1; $i++) {
  if ($raw[$i] -match 'shader does not translate') {
    $hh = [regex]::Match($raw[$i + 1], 'hash=([0-9a-f]{16})')
    if ($hh.Success) { $notTransHashes += $hh.Groups[1].Value }
  }
}
$notTransUnique = @($notTransHashes | Select-Object -Unique)
# TDR / driver error / device-lost signals anywhere in the merged log
$tdrHits = @([regex]::Matches($all, '(?i)(TDR|timeout detection and recovery|device removed|DXGI_ERROR_DEVICE_REMOVED|device hung|gpu hang|0x887a0006)')).Count

function Stat([double[]]$a) {
  if ($a.Count -eq 0) { return [ordered]@{n=0} }
  $s = @($a | Sort-Object)
  return [ordered]@{
    n=$s.Count
    min=[math]::Round($s[0],1)
    p10=[math]::Round($s[[int]($s.Count*0.10)],1)
    med=[math]::Round($s[[int]($s.Count*0.50)],1)
    p90=[math]::Round($s[[int]($s.Count*0.90)],1)
    max=[math]::Round($s[-1],1)
  }
}
$result = [ordered]@{
  tag=$Tag; var=$Var; value=$Value; profile=$Profile; seconds=$Seconds
  t0=$(if($t0){$t0.ToString('HH:mm:ss')}else{'never-entered-world'})
  survived=$survived; exit=$exitCode
  settleRows=$settle.Count; frameRows=$frame.Count
  sw=[pscustomobject](Stat $swS); rd=[pscustomobject](Stat $rdS); sum=[pscustomobject](Stat $sumS)
  frameMs=[pscustomobject](Stat $fms); copiesMs=[pscustomobject](Stat $cms); copiesMB=[pscustomobject](Stat $cmb)
  inplaceRows=$inpl.Count; inplaceStableRows=$ipStable.Count
  inplaceWinMB=[pscustomobject](Stat $ipWinMB); inplaceBufMB=[pscustomobject](Stat $ipBufMB)
  notTranslatedLines=$notTransHashes.Count; notTranslatedUnique=$notTransUnique.Count
  tdrHits=$tdrHits
}
$result | ConvertTo-Json -Depth 5 | Out-File (Join-Path $root "ab-$Tag.json") -Encoding utf8
Write-Host '=== ARM RESULT ==='
$result | ConvertTo-Json -Depth 5
Write-Host "log=$log json=ab-$Tag.json"
