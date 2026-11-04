# Full-chain check: syntax -> regression -> build -> artifact verification.
#
# WHY THIS EXISTS
#   The individual pieces already existed but nothing ran them together, and the
#   gaps between them were real:
#
#     * Regression and synthesis were run separately, so a change could pass
#       16 testbenches and still fail synthesis. That is not hypothetical: an
#       async_fifo_gray with a combinational read passed every simulation check
#       (153 + 95996) and then blew LUT4 from 11874 to 55072 and failed pnr.
#
#     * Nothing checked that the artifacts were actually REGENERATED. build-all
#       can report BUILD OK while the driver was skipped (fixed there), and a
#       stale .bit looks the same as a fresh one unless you compare timestamps.
#
#   So this script runs the whole chain and, crucially, verifies that every
#   artifact is NEWER than the moment the run started. That last check is what
#   turns "the commands exited 0" into "the outputs are actually from this run".
#
# STAGES
#   1. RTL syntax          iverilog -t null over every RTL file
#   2. Regression          run-regression.ps1 (all testbenches, auto-discovered)
#   3. Build               build-all.ps1 (map -> interface -> pnr -> pgm + driver)
#   4. Artifact freshness  .bit and .bin must be newer than the run start
#   5. Summary
#
# USAGE
#   pwsh -File full-chain.ps1
#   pwsh -File full-chain.ps1 -SkipBuild      # stages 1-2 only (fast)
#   pwsh -File full-chain.ps1 -SkipRegression
#
# NOTE: ASCII only.

param(
    [switch]$SkipBuild,
    [switch]$SkipRegression,
    [string]$SysDir   = 'C:\fpga_work\sys',
    [string]$SwDir    = 'C:\fpga_work\sw',
    [string]$ScriptsDir = 'C:\fpga_work\scripts',
    [string]$SrcDir   = 'C:\fpga_work\src',
    [string]$TbDir    = 'C:\fpga_work\tb',
    [string]$IverilogBin = 'C:\Users\25437\iverilog\bin',
    [string]$PrimDir  = 'C:\Efinity\2026.1\sim_models\verilog',
    # LAST ON PURPOSE. An earlier attempt put this right after $SkipBuild, which
    # is not the end of the list: a switch with no trailing comma, followed by
    # more parameters, is a parse error and the whole script stopped running
    # with a bare "Missing ')' in function parameter list".
    #
    # Runs every testbench under Questa as well. OFF by default: about three
    # minutes against 15 seconds, so day-to-day work should not pay for it. Turn
    # it on before anything that matters -- a commit claiming the RTL is correct,
    # or a submission.
    #
    # WHY IT IS WORTH THE TIME: iverilog -Wall is NOT a reliable detector for
    # "used before declared". It reported nineteen such signals in bitblt_top.v
    # and said nothing at all about prefetch_d in bitblt_video_out.v, nor about
    # five arrays in tb_bitblt_sprite_walker.v. Questa caught all three, and one
    # of them changed the synthesised LUT count by 268.
    [switch]$CrossSim
)

$ErrorActionPreference = 'Continue'
$env:Path += (';' + $IverilogBin)
$t0 = Get-Date

$stageFail = 0
function Head($n, $t) {
    Write-Host ''
    Write-Host ('=== ' + $n + ': ' + $t + ' ===') -ForegroundColor Cyan
}

# ================================================================ 1. RTL syntax
Head 1 'RTL syntax'

# This stage deliberately does NOT run iverilog over every .v file under rtl/.
#
# The first version did exactly that and reported 29 "syntax errors" -- every one
# of them in vendor-generated code (ddr3_controller/*, memory_test/*) that only
# Efinity's own synthesiser can parse. Those files really do participate in the
# build (they are listed in bitblt_system.xml), they are simply not iverilog's
# business. A check that always reports 29 false failures is worse than no check:
# people learn to scroll past it, and then miss the real one.
#
# What actually covers syntax here:
#   * stage 2 compiles and elaborates all 16 testbenches, which instantiate
#     every module we maintain;
#   * stage 3 runs map, which is the real full-syntax + elaboration gate for the
#     whole design including vendor IP.
#
# So this stage only confirms the toolchain is present and reports what will be
# covered downstream, rather than duplicating it badly.
$ourRtl = @()
foreach ($d in @((Join-Path $SysDir 'rtl'), $SrcDir)) {
    if (Test-Path $d) {
        $ourRtl += Get-ChildItem $d -File -Filter '*.v' -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notmatch '^tb_' }
    }
}
$tbCount = @()
foreach ($d in @((Join-Path $SysDir 'tb'), $TbDir)) {
    if (Test-Path $d) { $tbCount += Get-ChildItem $d -File -Filter 'tb_*.v' -ErrorAction SilentlyContinue }
}

if ($SkipRegression -and $SkipBuild) {
    Write-Host '  NOTE: both stage 2 and stage 3 skipped -- no syntax checking performed.' -ForegroundColor Yellow
} else {
    Write-Host ('  covered by stage 2 (' + $tbCount.Count + ' testbenches) and stage 3 (map)') -ForegroundColor Green
    Write-Host ('  top-level RTL files under our control: ' + $ourRtl.Count)
}

# ================================================================ 2. regression
if (-not $SkipRegression) {
    Head 2 'Regression (all testbenches)'
    $rg = Join-Path $ScriptsDir 'run-regression.ps1'
    if (-not (Test-Path $rg)) {
        Write-Host ('  FAILED  not found: ' + $rg) -ForegroundColor Red
        $stageFail++
    } else {
        $rgOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $rg 2>&1
        $sum = $rgOut | Select-String -Pattern 'PASS=\d+'
        if ($sum) { Write-Host ('  ' + $sum.Line.Trim()) }
        if ($LASTEXITCODE -eq 0) {
            Write-Host '  OK' -ForegroundColor Green
        } else {
            Write-Host '  FAILED' -ForegroundColor Red
            $rgOut | Select-String -Pattern 'FAIL|COMPILE FAILED' |
                Select-Object -First 8 | ForEach-Object { Write-Host ('    ' + $_.Line.Trim()) }
            $stageFail++
        }
    }
} else {
    Head 2 'Regression (SKIPPED)'
}

# ============================================================== 2b. cross-sim
# Every testbench under Questa, not a hand-picked few.
#
# The file lists are derived from the instantiation graph by work/cross_sim.py,
# because Questa's vlog does not expand wildcards -- that chore was the only
# reason this used to be manual, and manual meant it happened three times.
#
# See the -CrossSim switch above for why this is opt-in.
if ($CrossSim) {
    Head '2b' 'cross-sim (Questa, all testbenches)'
    # BOTH PATHS ARE ABSOLUTE, AND THEY HAVE TO BE.
    # This script is mirrored in two places -- the workspace scripts\ and
    # C:\fpga_work\scripts -- and it is normally run from the latter. So
    # $PSScriptRoot is C:\fpga_work\scripts, and '..\work\cross_sim.py' resolves
    # to C:\fpga_work\work\cross_sim.py, which does not exist. The first version
    # of this stage failed on exactly that and reported the path, which is how it
    # was found. The workspace location is fixed, so state it.
    #
    # Python likewise: this project's interpreter lives under the DSH runtime and
    # is not on PATH, so a bare `& python` fails silently.
    # ASCII PATH ON PURPOSE. scripts\*.ps1 are run from C:\fpga_work\scripts, and
    # this file is written as UTF-8 WITHOUT a BOM, so PowerShell 5.1 reads it as
    # GBK -- a Chinese path literal is already corrupted at load time. That is
    # exactly what happened: the stage reported
    #   not found at C:\Users\25437\Desktop\缂...\work\cross_sim.py
    # So the script is kept at a pure-ASCII location and referenced by one.
    # (The .py itself may hold Chinese paths internally: Python reads it as UTF-8.)
    $xs = 'C:\fpga_work\scripts\cross_sim.py'
    $pyExe = 'C:\Users\25437\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
    if (-not (Test-Path $xs)) {
        Write-Host ('  cross_sim.py not found at ' + $xs) -ForegroundColor Red
        $stageFail++
    } elseif (-not (Test-Path $pyExe)) {
        Write-Host ('  python not found at ' + $pyExe) -ForegroundColor Red
        Write-Host '  cross-sim CANNOT run -- do not read this as a pass.' -ForegroundColor Red
        $stageFail++
    } else {
        $env:PYTHONIOENCODING = 'utf-8'
        $xsOut = & $pyExe $xs 2>&1
        $xsTxt = ($xsOut | Out-String)
        foreach ($line in ($xsTxt -split "`n")) {
            if ($line -match 'passed :|failed :|FAIL|Error') {
                $col = if ($line -match 'failed : 0') { 'Green' } elseif ($line -match 'failed :') { 'Red' } else { 'Gray' }
                Write-Host ('  ' + $line.Trim()) -ForegroundColor $col
            }
        }
        if ($xsTxt -notmatch 'failed : 0') { $stageFail++ }
    }
} else {
    Write-Host '=== 2b: cross-sim -- SKIPPED (pass -CrossSim to run) ===' -ForegroundColor DarkGray
    Write-Host '  Every testbench under Questa takes ~3 min. iverilog -Wall does NOT' -ForegroundColor DarkGray
    Write-Host '  reliably catch "used before declared"; Questa does. Run this before' -ForegroundColor DarkGray
    Write-Host '  committing anything that claims the RTL is correct.' -ForegroundColor DarkGray
}

# =================================================================== 3. build
if (-not $SkipBuild) {
    Head 3 'Build (map -> interface -> pnr -> pgm + driver)'
    $ba = Join-Path $ScriptsDir 'build-all.ps1'
    if (-not (Test-Path $ba)) {
        Write-Host ('  FAILED  not found: ' + $ba) -ForegroundColor Red
        $stageFail++
    } else {
        $baOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $ba 2>&1
        $baOut | Select-String -Pattern '^\s+OK|FAILED|EFX_|BUILD|bitstream:|driver\s+:' |
            ForEach-Object { Write-Host ('  ' + $_.Line.Trim()) }
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  FAILED' -ForegroundColor Red
            $stageFail++
        } else {
            Write-Host '  OK' -ForegroundColor Green
        }
    }
} else {
    Head 3 'Build (SKIPPED)'
}

# ====================================================== 4. artifact freshness
Head 4 'Artifact freshness (must be newer than this run started)'

$artifacts = @(
    @{ n = 'bitstream'; p = (Join-Path $SysDir 'outflow\bitblt_system.bit'); min = 1000 },
    @{ n = 'driver   '; p = (Join-Path $SwDir  'bitblt_demo\build\bitblt_demo.bin'); min = 1 }
)

foreach ($a in $artifacts) {
    if (-not (Test-Path $a.p)) {
        Write-Host ('  MISSING  ' + $a.n + '  ' + $a.p) -ForegroundColor Red
        $stageFail++
        continue
    }
    $it = Get-Item $a.p
    $fresh = $it.LastWriteTime -ge $t0
    $kb = [math]::Round($it.Length / 1KB, 1)
    $tooSmall = ($it.Length / 1KB) -lt $a.min
    if ($fresh -and -not $tooSmall) {
        Write-Host ('  OK       ' + $a.n + '  ' + $kb + ' KB  ' + $it.LastWriteTime.ToString('HH:mm:ss')) -ForegroundColor Green
    } elseif (-not $fresh) {
        # This is the check that matters: the file exists and the build said OK,
        # but it predates this run, so it is NOT evidence that anything worked.
        Write-Host ('  STALE    ' + $a.n + '  ' + $kb + ' KB  ' + $it.LastWriteTime.ToString('HH:mm:ss') + '  (older than run start)') -ForegroundColor Red
        $stageFail++
    } else {
        Write-Host ('  TOO SMALL ' + $a.n + '  ' + $kb + ' KB  (expected at least ' + $a.min + ' KB)') -ForegroundColor Red
        $stageFail++
    }
}

# ============================================================ 5. timing + CDC
# WHY THIS STAGE EXISTS
#   pnr computes slack and writes bitblt_system.timing.rpt, and it runs a
#   synchroniser check into bitblt_system.cdc.rpt. NOTHING READ EITHER OF THEM:
#   full-chain confirmed that pnr had RUN, not that what it produced was
#   acceptable. A design whose worst slack went negative would still have
#   reported BUILD OK.
#
#   That is the same shape as the two elaboration bugs stage 3 already caught
#   (a duplicated port connection and an undeclared signal -- neither of which
#   iverilog objected to). Those were found because something downstream
#   checked. This stage is that idea applied to what pnr produces.
#
# WHAT IT ASSERTS
#   * every Setup (Max) clock relationship has slack > 0
#   * every Hold  (Min) clock relationship has slack > 0
#   * the synchroniser warning count is reported
function Get-TimingSlack {
    param([string]$ReportPath)
    $rows = @()
    if (-not (Test-Path $ReportPath)) { return $rows }
    $lines = Get-Content $ReportPath -Encoding UTF8
    $kind = ''
    foreach ($l in $lines) {
        if ($l -match '^Setup \(Max\) Clock Relationship') { $kind = 'Setup'; continue }
        if ($l -match '^Hold \(Min\) Clock Relationship')  { $kind = 'Hold';  continue }
        if ($l -match 'Clock Relationship Summary \(end\)') { $kind = ''; continue }
        if ($kind -eq '') { continue }
        if ($l -match '^\s*(\S+)\s+(\S+)\s+([\d.]+)\s+(-?[\d.]+)\s+\(') {
            $rows += [pscustomobject]@{
                Kind   = $kind
                Launch = $Matches[1]
                Slack  = [double]$Matches[4]
            }
        }
    }
    return $rows
}

if (-not $SkipBuild) {
    $timRpt = Join-Path $SysDir 'outflow\bitblt_system.timing.rpt'
    $cdcRpt = Join-Path $SysDir 'outflow\bitblt_system.cdc.rpt'

    Write-Host ''
    Write-Host '=== 5: Timing + CDC ===' -ForegroundColor Cyan

    $slacks = Get-TimingSlack -ReportPath $timRpt
    if ($slacks.Count -eq 0) {
        Write-Host '        no timing rows parsed -- report missing or format changed' -ForegroundColor Yellow
        $stageFail++
    } else {
        $bad = 0
        foreach ($r in $slacks) {
            $note = ''
            if ($r.Slack -le 0) { $note = '   <== VIOLATED'; $bad++ }
            Write-Host ('        {0,-6} {1,-22} slack {2,7:N3} ns{3}' -f $r.Kind, $r.Launch, $r.Slack, $note)
        }
        if ($bad -gt 0) {
            Write-Host ('        ' + $bad + ' timing violation(s)') -ForegroundColor Red
            $stageFail++
        } else {
            $min = ($slacks | Measure-Object -Property Slack -Minimum).Minimum
            Write-Host ('        all ' + $slacks.Count + ' relationships met, worst slack ' + $min.ToString('N3') + ' ns') -ForegroundColor Green
        }
    }

    if (Test-Path $cdcRpt) {
        $cdc = Get-Content $cdcRpt -Encoding UTF8 -Raw
        # ANAEMIC MATCHING WAS A FALSE POSITIVE. Counting every occurrence of
        # "warning" also counted the all-clear sentence "No Synchronizer
        # warnings to report", which made this stage report one warning on a
        # clean design. A check that cries wolf is worse than no check: the
        # reader learns to ignore it. So the all-clear phrasing is recognised
        # first and explicitly.
        if ($cdc -match 'No\s+Synchronizer\s+warnings\s+to\s+report') {
            Write-Host '        CDC: no synchronizer warnings' -ForegroundColor Green
        } else {
            # Count lines that actually look like a finding. The report's
            # explanatory preamble mentions "skew" and "synchronizer inputs"
            # without reporting anything, so a bare keyword count is not enough.
            $n = 0
            foreach ($line in ($cdc -split "`n")) {
                if ($line -match '^\s*(WARNING|Warning|ERROR|Error)\b') { $n++ }
            }
            if ($n -gt 0) {
                Write-Host ('        CDC: ' + $n + ' warning line(s) -- see bitblt_system.cdc.rpt') -ForegroundColor Yellow
            } else {
                Write-Host '        CDC: report present, no all-clear line and no warning lines' -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host '        CDC report absent' -ForegroundColor Yellow
    }
}

# ====================================================== 6. synthesis warnings
# WHY THIS STAGE EXISTS
#   Efinity has been writing warnings to bitblt_system.warn.log all along, and
#   nothing read them. A duplicate declaration of vid_fb_width -- the fifth time
#   in this project that a signal ended up declared twice -- sat in that log
#   from the build that introduced it until someone happened to look. The log is
#   cumulative (16735 lines), so the count is meaningless; only the segment from
#   the most recent synthesis run applies.
#
#   This is the same situation the timing report was in before stage 5: the tool
#   computed something useful and no step consumed it.
#
# WHAT FAILS, AND WHAT MERELY PRINTS
#   Failing on every warning would be worse than failing on none, because the
#   third-party SoC and DDR3 IP produce hundreds that are not ours to fix. A
#   check that cries wolf gets ignored, which is exactly how the timing report
#   came to be unread.
#
#   So three categories FAIL -- they are always defects, never style:
#     declared twice / already declared   -> a real duplicate
#     multiple drivers                    -> real contention
#     inferred latch                      -> real, and dangerous in a state machine
#
#   Everything else is listed with a count, per file, so a NEW warning is
#   visible without the existing noise being presented as failure.
function Get-SynthWarnings {
    param([string]$LogPath)
    $rows = @()
    if (-not (Test-Path $LogPath)) { return $rows }
    $all = Get-Content $LogPath -Encoding UTF8
    # Only the segment after the LAST synthesis start.
    $start = 0
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        if ($all[$i] -match 'Efinity Synthesis Started') { $start = $i; break }
    }
    for ($i = $start; $i -lt $all.Count; $i++) {
        if ($all[$i] -match 'WARNING') { $rows += $all[$i] }
    }
    return $rows
}

if (-not $SkipBuild) {
    $warnLog = Join-Path $SysDir 'outflow\bitblt_system.warn.log'

    Write-Host ''
    Write-Host '=== 6: Synthesis warnings ===' -ForegroundColor Cyan

    $warns = Get-SynthWarnings -LogPath $warnLog
    if ($warns.Count -eq 0) {
        Write-Host '        no warnings in this run' -ForegroundColor Green
    } else {
        $hard = @()
        foreach ($w in $warns) {
            if ($w -match 'already declared|second declaration|multiple driver|inferred latch|latch inferred') {
                $hard += $w
            }
        }
        if ($hard.Count -gt 0) {
            Write-Host ('        ' + $hard.Count + ' DEFECT-class warning(s):') -ForegroundColor Red
            foreach ($h in $hard) {
                Write-Host ('          ' + $h.Trim().Substring(0, [Math]::Min(118, $h.Trim().Length))) -ForegroundColor Red
            }
            $stageFail++
        } else {
            Write-Host ('        none of the defect classes (duplicate declaration, multiple driver, inferred latch)') -ForegroundColor Green
        }

        # Ours vs theirs. The third-party SoC and DDR3 IP dominate the log; a
        # count per file keeps a NEW entry visible without burying it.
        # MATCH THE BARE FILENAME, NOT THE PATH. Requiring 'rtl/' in the line
        # matched only 34 of 197 warnings: many name the file inside quotes
        # without any path, e.g. "parameter 'FREQ' becomes localparam in
        # 'system_top'". Matching just the filename matches 188 of 197, and the
        # ours/theirs split is then decided by the name and not by how the path
        # happened to be rendered.
        $ours = @{}
        $theirs = 0
        foreach ($w in $warns) {
            $m = [regex]::Match($w, '([A-Za-z0-9_]+\.v)')
            if ($m.Success) {
                $f = $m.Groups[1].Value
                if ($f -match '^(bitblt|system_top|Axi_Mux|alpha)') {
                    if ($ours.ContainsKey($f)) { $ours[$f]++ } else { $ours[$f] = 1 }
                } else { $theirs++ }
            } else { $theirs++ }
        }
        $total = $warns.Count
        Write-Host ('        ' + $total + ' warning(s) this run, ' + $theirs + ' from third-party IP or unlabelled') -ForegroundColor Gray
        if ($ours.Count -gt 0) {
            foreach ($k in ($ours.Keys | Sort-Object)) {
                Write-Host ('          ' + $k.PadRight(24) + $ours[$k]) -ForegroundColor Yellow
            }
        } else {
            Write-Host '          none attributed to our own RTL' -ForegroundColor Green
        }
    }
}

# ================================================================ 7. summary
Write-Host ''
Write-Host '================ full-chain summary ================'
$sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
if ($stageFail -eq 0) {
    Write-Host ('FULL CHAIN OK  (' + $sec + ' s)') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FULL CHAIN FAILED: ' + $stageFail + ' stage(s)  (' + $sec + ' s)') -ForegroundColor Red
    exit 1
}
