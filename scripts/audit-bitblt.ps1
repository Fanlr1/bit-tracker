# BitBlt project audit -- cross-layer consistency checks.
#
# WHY THIS EXISTS
#   Two classes of bug have hit this project repeatedly and neither is caught by
#   the existing testbenches:
#
#     (a) "False PASS" -- the synthesiser silently deletes logic and still
#         reports map: PASS. Found twice, both times only by eyeballing resource
#         numbers.
#     (b) Cross-layer mismatches -- values individually correct in each file but
#         disagreeing when wired together. The AXI ID collision found in the
#         2026-10-06 audit was exactly this: Axi_Mux emits 8-bit IDs, ddr3_top
#         accepts 4, and two masters ended up sharing low nibble 0x0.
#
#   Unit tests, end-to-end simulation and synthesis all passed while (b) was
#   present; only manual cross-checking found it. This script automates that
#   cross-checking.
#
# NOTE ON STRING QUOTING
#   Verilog literals contain an apostrophe (8'h10), so every regex below that
#   matches one uses a SINGLE-quoted PowerShell string with the apostrophe
#   doubled (''). Writing these in double quotes makes the parser treat the
#   apostrophe as a delimiter and produces errors that point at unrelated later
#   lines -- which cost a round of debugging when this script was first written.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File C:\fpga_work\scripts\audit-bitblt.ps1
#   Exit code 0 = all checks passed, 1 = at least one failed.

$ErrorActionPreference = 'Continue'

$sys = 'C:\fpga_work\sys'
$sw  = 'C:\fpga_work\sw'

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host ('  PASS  ' + $name) }
    else {
        Write-Host ('  FAIL  ' + $name + '   ' + $detail) -ForegroundColor Red
        $script:fail = $script:fail + 1
    }
}

Write-Host ''
Write-Host '=== 1. AXI ID uniqueness (ddr3 truncates to 4 bits) ===' -ForegroundColor Cyan

$slv = Get-Content "$sys\rtl\bitblt_axi_slave.v" -Encoding UTF8 -Raw
$bt = Get-Content "$sys\rtl\bitblt_top.v"  -Encoding UTF8 -Raw
$st = Get-Content "$sys\rtl\system_top.v"  -Encoding UTF8 -Raw

# single-quoted: the apostrophe in 8'h is written as '' so the parser is happy
$patTop = 'AXI_ID\(8''h([0-9A-Fa-f]{2})\)'
$patSys = 'AXI_ID\s*\(8''h([0-9A-Fa-f]{2})\)'

$ids = @()
foreach ($m in [regex]::Matches($bt, $patTop)) { $ids += [Convert]::ToInt32($m.Groups[1].Value, 16) }
foreach ($m in [regex]::Matches($st, $patSys)) { $ids += [Convert]::ToInt32($m.Groups[1].Value, 16) }

if ($ids.Count -eq 0) {
    Check 'found AXI IDs' $false 'no AXI_ID(8''h..) matched -- did the syntax change?'
} else {
    $shown = ($ids | ForEach-Object { '0x{0:X2}' -f $_ }) -join ', '
    Write-Host ('  found ' + $ids.Count + ' master IDs: ' + $shown)

    # Expect exactly four: three BitBlt engines plus the video read port. An
    # earlier version only failed when the count was ZERO, so if system_top.v
    # could not be read (no Test-Path guard) the video ID silently dropped out
    # and the remaining three still had unique low nibbles -- a PASS with the
    # one ID that originally caused the collision missing.
    Check 'found 4 master IDs (3 BitBlt + 1 video)' ($ids.Count -eq 4) `
          ('actual ' + $ids.Count + ' -- a missing one means a file could not be read')

    $low = @($ids | ForEach-Object { $_ -band 0xF })
    $dup = @($low | Group-Object | Where-Object { $_.Count -gt 1 })
    $dupTxt = ($dup | ForEach-Object { '0x{0:X}' -f [int]$_.Name }) -join ','
    Check 'low 4 bits unique' ($dup.Count -eq 0) ('duplicate low nibble: ' + $dupTxt)

    $below8 = @($low | Where-Object { $_ -lt 8 })
    $b8txt  = ($below8 | ForEach-Object { '0x{0:X}' -f $_ }) -join ','
    Check 'our IDs stay in 8..F (0..7 left to the SoC)' ($below8.Count -eq 0) `
          ('these low nibbles are below 8: ' + $b8txt)
}

Write-Host ''
Write-Host '=== 2. memory regions do not overlap ===' -ForegroundColor Cyan

$FB_BASE   = 0x08000000
$FB_BYTES  = 640 * 480 * 4
$SPR_BASE  = 0x09000000
$SPR_BYTES = 64 * 64 * 4
$PROG_ORIG = 0x00001000
$PROG_LEN  = 124 * 1024

$regions = @(
    @{ n = 'program'; s = $PROG_ORIG;           e = $PROG_ORIG + $PROG_LEN - 1 }
    @{ n = 'FB A';    s = $FB_BASE;             e = $FB_BASE + $FB_BYTES - 1 }
    @{ n = 'FB B';    s = $FB_BASE + $FB_BYTES; e = $FB_BASE + 2 * $FB_BYTES - 1 }
    @{ n = 'sprite';  s = $SPR_BASE;            e = $SPR_BASE + $SPR_BYTES - 1 }
)

$overlap = $false
for ($i = 0; $i -lt $regions.Count; $i++) {
    for ($j = $i + 1; $j -lt $regions.Count; $j++) {
        $a = $regions[$i]; $b = $regions[$j]
        if ($a.s -le $b.e -and $b.s -le $a.e) {
            Write-Host ('  OVERLAP ' + $a.n + ' <-> ' + $b.n) -ForegroundColor Red
            $overlap = $true
        }
    }
}
Check 'no region overlap' (-not $overlap) 'see OVERLAP lines above'

foreach ($r in $regions) {
    Check ($r.n + ' fits in 28-bit DDR3 space') ($r.e -le 0x0FFFFFFF) ('ends at 0x{0:X8}' -f $r.e)
}

Write-Host ''
Write-Host '=== 3. duplicated constants agree (driver vs RTL) ===' -ForegroundColor Cyan

$mcPath = "$sw\bitblt_demo\src\main.c"
if (-not (Test-Path $mcPath)) {
    Check 'driver main.c exists' $false $mcPath
} else {
    $mc = Get-Content $mcPath -Encoding UTF8 -Raw

    $drvFb = -1
    if ($mc -match 'FB_BASE\s+0x([0-9A-Fa-f]+)u') { $drvFb = [Convert]::ToInt64($Matches[1], 16) }
    Check 'driver FB_BASE parsed' ($drvFb -ge 0) 'could not parse FB_BASE from main.c'

    $hwFb = -1
    if ($slv -match 'r_fb_base\s*<=\s*32''h([0-9A-Fa-f_]+)') {
        $hwFb = [Convert]::ToInt64(($Matches[1] -replace '_', ''), 16)
    }
    Check 'RTL reset fb_base parsed' ($hwFb -ge 0) 'could not parse r_fb_base from system_top/axi_slave'
    Check 'RTL reset fb_base == driver FB_BASE' ($drvFb -eq $hwFb) `
          ('driver=0x{0:X} rtl=0x{1:X}' -f $drvFb, $hwFb)

    $drvStride = 640 * 4
    $hwStride = -1
    if ($slv -match 'r_fb_cfg\s*<=\s*32''h([0-9A-Fa-f_]+)') {
        $hwStride = ([Convert]::ToInt64(($Matches[1] -replace '_', ''), 16)) -band 0xFFFF
    }
    Check 'RTL reset stride == 640*4' ($drvStride -eq $hwStride) ('expect 2560, rtl=' + $hwStride)
}

Write-Host ''
Write-Host '=== 4. module resources vs baseline (false-PASS guard) ===' -ForegroundColor Cyan
#
# WHY THIS COMPARES NUMBERS, NOT NAMES
#   The first version of this guard only counted occurrences of module names in
#   the netlist. That cannot catch the failure this project has actually hit
#   twice: the module survives but its logic collapses. In the recorded incident
#   u_bitblt appeared 15192 times in the netlist while holding 1 FF and 1 LUT.
#   A name that is present says nothing about whether the logic behind it is.
#
#   So read the resource report and compare against a stored baseline. Ordinary
#   edits move these counts by a few percent; a collapse moves them by orders of
#   magnitude. The tolerance is loose on purpose.

$mv   = "$sys\outflow\bitblt_system.map.v"
$res  = "$sys\outflow\bitblt_system.res.csv"
$base = 'C:\fpga_work\scripts\baseline-res.json'

if (-not (Test-Path $mv)) {
    Check 'netlist exists' $false 'run --flow map first'
} else {
    # name presence is still checked, as a cheap first line
    foreach ($m in @('u_bitblt', 'u_video_out', 'u_regs', 'u_axi_mux', 'u_ddr3_top')) {
        $n = (Select-String -Path $mv -Pattern ([regex]::Escape($m)) -Encoding UTF8 -AllMatches |
              Measure-Object).Count
        Check ('netlist contains ' + $m) ($n -gt 0) '0 occurrences -- possible silent optimisation'
    }
}

if (-not (Test-Path $res)) {
    Check 'res.csv exists' $false 'run --flow map first'
} elseif (-not (Test-Path $base)) {
    Check 'resource baseline exists' $false $base
} else {
    $b   = Get-Content $base -Raw -Encoding UTF8 | ConvertFrom-Json
    $tol = [double]$b.tolerance
    Write-Host ('  tolerance: resource must stay above ' + [int]($tol * 100) + '% of baseline')

    # res.csv columns: Module  FFs  SRLs  ADDs  LUTs  COMB4s  RAMs  DSP/MULTs
    # Values look like "1354(4)"; the parenthesised part is dropped.
    #
    # The module column carries a hierarchy marker: '+' for an instance, a
    # space for a level boundary. The baseline names instances without the
    # '+', so strip it here. Getting this wrong makes every lookup miss, which
    # is exactly what the "Check" call below guards against -- a lookup that
    # silently returned "not found" would turn all six comparisons into
    # checks that can never fail.
    $rows = @{}
    foreach ($line in (Get-Content $res -Encoding UTF8)) {
        $c = $line -split "`t"
        if ($c.Count -lt 8) { continue }
        $nm = $c[0].Trim()
        if ($nm -notmatch '^[+ ]') { continue }
        $nm = $nm.TrimStart('+').Trim()
        # Instances whose parameters were worth reporting carry them in the
        # name, e.g. u_video_out:bitblt_video_out(AXI_ID=8'b011110). The
        # baseline uses the bare instance path, so drop the parameter list.
        $nm = $nm -replace '\(.*\)\s*$', ''
        $ff  = ($c[1].Trim() -replace '\(.*\)', '') -as [int]
        $lut = ($c[4].Trim() -replace '\(.*\)', '') -as [int]
        $dsp = ($c[7].Trim() -replace '\(.*\)', '') -as [int]
        if ($null -ne $ff) { $rows[$nm] = @{ ff = $ff; lut = $lut; dsp = $dsp } }
    }
    Check 'res.csv parsed' ($rows.Count -gt 0) 'no module rows matched the expected column layout'

    foreach ($p in $b.modules.PSObject.Properties) {
        $name = $p.Name
        $exp  = $p.Value
        $act  = $rows[$name]

        if ($null -eq $act) {
            Check ($name + ' present in res.csv') $false 'module missing from the resource report entirely'
            continue
        }

        foreach ($k in @('ff', 'lut', 'dsp')) {
            $e = [int]$exp.$k
            $a = [int]$act[$k]
            if ($e -le 0) { continue }             # nothing to compare against
            $floor = [int][math]::Floor($e * $tol)
            Check ($name + ' ' + $k + ' >= ' + $floor + ' (baseline ' + $e + ')') ($a -ge $floor) `
                  ('actual ' + $a + ' -- logic may have been optimised away')
        }
    }

    $g = Get-Content "$sys\outflow\bitblt_system.map.rpt" -Encoding UTF8
    foreach ($r in @(@{n = 'EFX_LUT4'; f = 'LUT4'}, @{n = 'EFX_FF'; f = 'FF'}, @{n = 'EFX_DSP48'; f = 'DSP48'})) {
        $line = $g | Select-String -Pattern ('^\s*' + $r.n + '\s+:') | Select-Object -First 1
        if ($line) {
            $v = [int](($line.Line -split ':')[1].Trim())
            $floor = if ($r.f -eq 'LUT4') { 8000 } elseif ($r.f -eq 'FF') { 8000 } else { 12 }
            Check ('top-level ' + $r.f + ' >= ' + $floor) ($v -ge $floor) ('actual ' + $v)
        }
    }
}

Write-Host ''
Write-Host '=== 5. widths across the Axi_Mux -> ddr3_top boundary ===' -ForegroundColor Cyan

$ddrParam = Get-Content "$sys\rtl\ddr3_controller\ddr3_parameter.vh" -Encoding UTF8 -Raw
$idW = -1; $awW = -1
if ($ddrParam -match '`define\s+AXI_ID_WIDTH\s+(\d+)')   { $idW = [int]$Matches[1] }
if ($ddrParam -match '`define\s+AXI_ADDR_WIDTH\s+(\d+)') { $awW = [int]$Matches[1] }

Check 'ddr3 AXI_ID_WIDTH parsed'   ($idW -gt 0) 'not found in ddr3_parameter.vh'
Check 'ddr3 AXI_ADDR_WIDTH parsed' ($awW -gt 0) 'not found in ddr3_parameter.vh'
Check 'AXI_ID_WIDTH is 4 (check 1 assumes this)' ($idW -eq 4) ('actual=' + $idW + ' -- revise the low-nibble logic if this changes')

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host 'AUDIT: all checks passed' -ForegroundColor Green
    exit 0
} else {
    Write-Host ('AUDIT: ' + $script:fail + ' check(s) failed') -ForegroundColor Red
    exit 1
}
