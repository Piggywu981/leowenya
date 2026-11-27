# Post-process all arm logs from a settle A/B into one comparable table.
#   powershell -ExecutionPolicy Bypass -File tools\ab-post.ps1 -Tags wm_off,wm_on
#
# For each arm: find world entry T0 (first settle summary with sw+rd>400),
# keep only logical lines timestamped >= T0+15 s, and reduce the four periodic
# copystat diagnostics plus the frame line to medians.  Prints a compact matrix
# so two arms can be checked for comparability (same scene, similar n).
param([Parameter(Mandatory)][string]$Tags)   # comma-separated arm tags

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot

function ReadLogical([string]$path) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($ln in (Get-Content $path -ErrorAction SilentlyContinue)) {
    if ($ln -match '^\d{4}-\d\d-\d\dT[\d:.]+Z') { $out.Add($ln) }
    elseif ($out.Count -gt 0) { $out[$out.Count-1] = $out[$out.Count-1] + ' ' + $ln.Trim() }
  }
  return $out
}
function Med([double[]]$a) {
  if ($a.Count -eq 0) { return $null }
  $s = @($a | Sort-Object)
  return [math]::Round($s[[int]($s.Count*0.5)], 1)
}
function Grab($lines, $pattern, $regex, $groups) {
  $vals = @()
  foreach ($L in $lines) {
    if ($L -notmatch $pattern) { continue }
    $m = [regex]::Match($L, $regex)
    if (-not $m.Success) { continue }
    $row = @{}
    foreach ($g in $groups.Keys) { $row[$g] = [double]$m.Groups[$groups[$g]].Value }
    $vals += [pscustomobject]$row
  }
  return ,$vals
}

foreach ($tag in ($Tags -split ',')) {
  $path = Join-Path $root "ab-$tag.log"
  if (-not (Test-Path $path)) { Write-Host "[$tag] MISSING $path"; continue }
  $lines = ReadLogical $path
  # world entry from settle summaries
  $t0 = $null
  foreach ($L in $lines) {
    if ($L -match 'of the waiting for the card in settles') {
      $m = [regex]::Match($L, 'shader writes ([\d.]+), title memory read ([\d.]+)')
      if ($m.Success -and ([double]$m.Groups[1].Value + [double]$m.Groups[2].Value) -gt 400) {
        $tm = [regex]::Match($L, '^([\d]{4}-\d\d-\d\dT[\d:.]+)Z')
        if ($tm.Success) { $t0 = [datetime]::Parse($tm.Groups[1].Value); break }
      }
    }
  }
  $stable = $(if ($t0) { $t0.AddSeconds(15) } else { $null })
  $sel = @()
  foreach ($L in $lines) {
    if (-not $stable) { break }
    $tm = [regex]::Match($L, '^([\d]{4}-\d\d-\d\dT[\d:.]+)Z')
    if ($tm.Success -and [datetime]::Parse($tm.Groups[1].Value) -ge $stable) { $sel += $L }
  }
  Write-Host "=== $tag  t0=$(if($t0){$t0.ToString('HH:mm:ss')}else{'NONE'})  stableLines=$($sel.Count) ==="

  # settle wait: sw / rd / sum (sum = median of per-row sw+rd, NOT med(sw)+med(rd))
  $settle = Grab $sel 'of the waiting for the card in settles' 'shader writes ([\d.]+), title memory read ([\d.]+)' @{sw=1;rd=2}
  if ($settle.Count) {
    $sw   = Med @($settle | ForEach-Object {$_.sw})
    $rd   = Med @($settle | ForEach-Object {$_.rd})
    $sumM = Med @($settle | ForEach-Object {$_.sw + $_.rd})
    Write-Host ("  settle n={0}  sw_med={1}  rd_med={2}  sum_med={3}" -f $settle.Count,$sw,$rd,$sumM)
  }
  # frame account: what shaders wrote (the exact bucket WIDE_MERGE targets)
  $fa = Grab $sel 'frame account per frame' 'what shaders wrote: ([\d.]+) ms finding ([\d.]+) pieces that differ, ([\d.]+) ms putting them back' @{findMs=1;pieces=2;putBackMs=3}
  if ($fa.Count) {
    Write-Host ("  frameacct n={0}  find_ms_med={1}  pieces_med={2}  putback_ms_med={3}" -f $fa.Count,(Med @($fa|ForEach-Object{$_.findMs})),(Med @($fa|ForEach-Object{$_.pieces})),(Med @($fa|ForEach-Object{$_.putBackMs})))
  }
  # frame line
  $fr = Grab $sel 'INFO victory_gpu::host: [\d.]+ fps' '([\d.]+) ms/frame' @{ms=1}
  if ($fr.Count) { Write-Host ("  frame  n={0}  ms_med={1}" -f $fr.Count,(Med @($fr|ForEach-Object{$_.ms}))) }
  # copies per frame
  $cp = Grab $sel 'copies per frame:' 'title copies [\d.]+ ([\d.]+) MB; [\d.]+ refreshes ([\d.]+) MB' @{copyMB=1;refreshMB=2}
  if ($cp.Count) { Write-Host ("  copies n={0}  copyMB_med={1}  refreshMB_med={2}" -f $cp.Count,(Med @($cp|ForEach-Object{$_.copyMB})),(Med @($cp|ForEach-Object{$_.refreshMB}))) }
  # waiting for card histogram
  $wc = Grab $sel 'waiting for the card per frame:' 'nothing back to the title \(([\d.]+) ms of the waiting\)' @{nothingBack=1}
  if ($wc.Count) { Write-Host ("  cardwait n={0}  nothingBack_med={1}" -f $wc.Count,(Med @($wc|ForEach-Object{$_.nothingBack}))) }
  # recording per frame
  $rc = Grab $sel 'recording per frame' 'shader-written ranges: [\d.]+ steps in [\d.]+ submissions, snapshots ([\d.]+) ms, ([\d.]+) MB compared back' @{snapMs=1;backMB=2}
  if ($rc.Count) { Write-Host ("  record  n={0}  snapshot_ms_med={1}  comparedback_MB_med={2}" -f $rc.Count,(Med @($rc|ForEach-Object{$_.snapMs})),(Med @($rc|ForEach-Object{$_.backMB}))) }
}
