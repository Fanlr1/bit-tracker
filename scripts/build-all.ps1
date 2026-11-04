# One-shot build: bitstream + driver + resource/timing summary.
#
# WHY THIS EXISTS
#   The Efinity flow is four separate steps (map, interface, pnr, pgm). Running
#   them by hand invites two mistakes that have both happened here:
#
#     * skipping a step, so the .bit on disk is from an older netlist while the
#       reports look fresh -- this produced a stale bitstream that was nearly
#       flashed;
#     * not looking at the reports afterwards, so a resource collapse or a
#       timing failure goes unnoticed.
#
#   This runs all four in order, stops at the first failure, and prints the
#   numbers that matter at the end.
#
# 2026-10-16: EVERY STEP NOW LOGS TO work\logs AND A FAILURE PRINTS ITS OWN
#   EVIDENCE. Previously each step ran as "& $Efinity ... *> $null", so when one
#   failed the script could only say "FAILED exit=1" -- and twice that sent us
#   hunting a phantom resource problem when the real cause was a stale efx_map
#   process holding a lock on outflow\bitblt_system.log, or an "interface" run
#   that returned 0 without writing the pin constraints (pnr then reported
#   Missing Interface Pins). Both are now visible immediately.
#
#   Stale Efinity processes are killed before step 1, for the same reason.
#
# USAGE
#   pwsh -File build-all.ps1                 # full flow + driver
#   pwsh -File build-all.ps1 -SkipPgm        # stop before bitstream generation
#   pwsh -File build-all.ps1 -RtlOnly        # synthesis only (fast check)
#
# NOTE: ASCII only. A .ps1 with CJK text but no BOM breaks the Windows
# PowerShell parser.

param(
    [switch]$SkipPgm,
    [switch]$RtlOnly,
    [string]$SysDir  = 'C:\fpga_work\sys',
    [string]$SwDir   = 'C:\fpga_work\sw',
    [string]$Efinity = 'C:\Efinity\2026.1\bin\efx_run.bat',
    [string]$Toolchain = 'C:\fpga_work\toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
)

$ErrorActionPreference = 'Continue'
$fail = 0
$t0 = Get-Date

$LogDir = Join-Path (Split-Path $PSScriptRoot) 'work\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Show-Failure($log) {
    if (-not (Test-Path $log)) { return }
    Write-Host '    ---- last non-empty lines ----' -ForegroundColor Yellow
    Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '\S' } | Select-Object -Last 12 |
        ForEach-Object { Write-Host ('    | ' + $_.Trim()) }
    Write-Host '    ---- error-ish lines ----' -ForegroundColor Yellow
    $hits = Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-String -Pattern 'ERROR|Error|error|FAIL|Fail|Missing|exceed|insufficient|Cannot|cannot|Traceback|not found' |
        Select-Object -First 10
    if ($hits) { $hits | ForEach-Object { Write-Host ('    ! ' + $_.Line.Trim()) } }
    else { Write-Host '    (no obviously-error line -- read the log)' }
    Write-Host ('    full log: ' + $log) -ForegroundColor Yellow
}

function Step($name, $logName, $block) {
    Write-Host ''
    Write-Host ('=== ' + $name + ' ===') -ForegroundColor Cyan
    $log = Join-Path $LogDir $logName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $block *> $log
    $rc = $LASTEXITCODE
    $sw.Stop()
    if ($rc -eq 0) {
        Write-Host ('    OK  (' + [math]::Round($sw.Elapsed.TotalSeconds,1) + ' s)   log: ' + $logName) -ForegroundColor Green
    } else {
        Write-Host ('    FAILED  exit=' + $rc) -ForegroundColor Red
        Show-Failure $log
        $script:fail++
    }
    return $rc
}

# ---------------------------------------------------------------- project XML
$xml = Join-Path $SysDir 'bitblt_system.xml'
if (-not (Test-Path $xml)) {
    Write-Host ('ERROR: project file not found: ' + $xml) -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $Efinity)) {
    Write-Host ('ERROR: efx_run not found: ' + $Efinity) -ForegroundColor Red
    exit 2
}

Push-Location $SysDir

# ---------------------------------------------------------------- 0. hygiene
# A stale Efinity process holds a lock on outflow\bitblt_system.log and makes the
# NEXT flow die with "[WinError 32] ... being used by another process", which the
# summary can only report as "FAILED exit=1". Kill them before starting.
$stale = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^efx' })
if ($stale.Count -gt 0) {
    Write-Host ('NOTE: ' + $stale.Count + ' stale Efinity process(es) -- terminating before the build') -ForegroundColor Yellow
    $stale | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}

# ---------------------------------------------------------------- 1. map
Step 'map (synthesis)' 'build-map.log' { & $Efinity 'bitblt_system.xml' --flow map } | Out-Null

# ---------------------------------------------------------------- 2. interface
# Omitting this step silently ignores the .peri.xml, which is how the pin and
# PLL configuration disappears without any error.
if ($fail -eq 0 -and -not $RtlOnly) {
    Step 'interface (pins/PLL)' 'build-interface.log' { & $Efinity 'bitblt_system.xml' --flow interface } | Out-Null
}

# ---------------------------------------------------------------- 3. pnr
if ($fail -eq 0 -and -not $RtlOnly) {
    Step 'pnr (place & route)' 'build-pnr.log' { & $Efinity 'bitblt_system.xml' --flow pnr } | Out-Null
}

# ---------------------------------------------------------------- 4. pgm
if ($fail -eq 0 -and -not $SkipPgm -and -not $RtlOnly) {
    Step 'pgm (bitstream)' 'build-pgm.log' { & $Efinity 'bitblt_system.xml' --flow pgm } | Out-Null
}

# ---------------------------------------------------------------- 5. driver
# Track whether the driver was actually built. Skipping it is legitimate (a
# bitstream-only run needs no toolchain) but it must NOT look like success:
# previously a missing toolchain silently skipped this whole section, $fail
# stayed 0, and the script printed BUILD OK with no bitblt_demo.bin on disk.
$driverState = 'not attempted'
if ($RtlOnly) {
    $driverState = 'skipped (-RtlOnly)'
} elseif ($fail -ne 0) {
    $driverState = 'skipped - an earlier step failed'
} elseif (-not (Test-Path $Toolchain)) {
    $driverState = 'SKIPPED - toolchain not found'
    Write-Host ''
    Write-Host ('  NOTE: driver NOT built. Toolchain not found at:') -ForegroundColor Yellow
    Write-Host ('        ' + $Toolchain) -ForegroundColor Yellow
    Write-Host '        The bitstream output is unaffected, but bitblt_demo.bin' -ForegroundColor Yellow
    Write-Host '        was NOT regenerated. Pass -Toolchain to point at it.' -ForegroundColor Yellow
}

if ($fail -eq 0 -and -not $RtlOnly -and (Test-Path $Toolchain)) {
    $driverState = 'built'
    $gcc  = Join-Path $Toolchain 'riscv-none-elf-gcc.exe'
    $objc = Join-Path $Toolchain 'riscv-none-elf-objcopy.exe'
    $bsp  = Join-Path $SwDir 'bsp\efinix\EfxSapphireSoc'
    $sa   = Join-Path $SwDir 'standalone'
    $src  = Join-Path $SwDir 'bitblt_demo\src\main.c'
    $out  = Join-Path $SwDir 'bitblt_demo\build'

    $cf = @('-march=rv32im_zicsr','-mabi=ilp32','-DUSE_GP','-g3','-Os',
            ('-I' + (Join-Path $bsp 'include')),
            ('-I' + (Join-Path $sa  'include')),
            ('-I' + (Join-Path $sa  'driver')),
            '-DSYSTEM_UART_A_APB=SYSTEM_UART_0_IO_APB',
            '-DSYSTEM_GPIO_A_APB=SYSTEM_GPIO_0_IO_APB',
            '-DSYSTEM_I2C_A_APB=SYSTEM_I2C_0_IO_APB')

    Step 'compile driver' 'build-driver-compile.log' {
        # Two translation units now. game.c holds the bullet-hell logic and
        # compiles on its own; keeping it separate is what allows a host build
        # with the blt_* calls stubbed out.
        # Three translation units now. game_input.c holds the UART keyboard reader,
        # kept separate so game.c has no knowledge of UARTs -- the host harness
        # supplies its own game_input_poll() and the same game.c is used both ways.
foreach ($one in @('main.c', 'game.c', 'game_input.c')) {
            $oneSrc = Join-Path $SwDir ('bitblt_demo\src\' + $one)
            $oneObj = Join-Path $out ('obj\' + [IO.Path]::GetFileNameWithoutExtension($one) + '.o')
            & $gcc @cf -Wall -c $oneSrc -o $oneObj 2>&1 |
                Select-String -Pattern '\.c.*(error|warning)'
        }
    } | Out-Null

    if ($fail -eq 0) {
        Step 'link driver' 'build-driver-link.log' {
            & $gcc @cf -o (Join-Path $out 'bitblt_demo.elf') `
                (Join-Path $out 'obj\start.o') (Join-Path $out 'obj\trap.o') (Join-Path $out 'obj\main.o') (Join-Path $out 'obj\game.o') (Join-Path $out 'obj\game_input.o') `
                ('-L' + (Join-Path $sa 'common')) '-specs=nosys.specs' '-lgcc' '-nostartfiles' '-ffreestanding' `
                ('-Wl,-Bstatic,-T,' + (Join-Path $bsp 'linker\default.ld')) '-lm' '-lc' 2>&1 |
                Select-String -NotMatch 'RWX permissions'
        } | Out-Null

        if ($fail -eq 0) {
            & $objc -O binary (Join-Path $out 'bitblt_demo.elf') (Join-Path $out 'bitblt_demo.bin') 2>&1 | Out-Null
            & $objc -O ihex   (Join-Path $out 'bitblt_demo.elf') (Join-Path $out 'bitblt_demo.hex') 2>&1 | Out-Null
        }
    }
}

# ---------------------------------------------------------------- summary
Write-Host ''
Write-Host '================ summary ================'

# A failed build leaves the PREVIOUS run's reports on disk, and printing them
# without comment looks exactly like a successful build. That happened once
# already: pnr failed, yet the summary showed the resource counts and timing
# from an earlier run and the numbers were nearly believed.
#
# Two defences: shout when the build failed, and stamp every report with the
# time it was written so stale data is visible at a glance.
if ($fail -ne 0) {
    Write-Host ''
    Write-Host '  ***********************************************************' -ForegroundColor Red
    Write-Host '  * THIS BUILD FAILED. Any report shown below is from an    *' -ForegroundColor Red
    Write-Host '  * EARLIER run -- check the timestamp before believing it. *' -ForegroundColor Red
    Write-Host '  ***********************************************************' -ForegroundColor Red
    Write-Host ''
}

$mapRpt = Join-Path $SysDir 'outflow\bitblt_system.map.rpt'
if (Test-Path $mapRpt) {
    $mr = Get-Item $mapRpt
    Write-Host ('resources:   (map report written ' + $mr.LastWriteTime.ToString('MM-dd HH:mm:ss') + ')')
    Get-Content $mapRpt -Encoding UTF8 |
        Select-String -Pattern '^\s*EFX_(LUT4|FF|DSP48|RAM10)\s+:' |
        ForEach-Object { '  ' + $_.Line.Trim() }
} else {
    Write-Host 'resources: map report not found' -ForegroundColor Yellow
}

$timRpt = Join-Path $SysDir 'outflow\bitblt_system.timing.rpt'
if (Test-Path $timRpt) {
    $tr = Get-Item $timRpt
    Write-Host ('timing (setup, worst path per clock):   (timing report written ' + $tr.LastWriteTime.ToString('MM-dd HH:mm:ss') + ')')
    $lines = Get-Content $timRpt -Encoding UTF8
    $s = ($lines | Select-String -Pattern 'Setup \(Max\) Clock Relationship' | Select-Object -First 1).LineNumber
    if ($s) {
        $lines[$s..([Math]::Min($s + 7, $lines.Count - 1))] | ForEach-Object { '  ' + $_ }
        # Flag a thin margin explicitly -- it has silently gone from 0.47 to
        # 0.19 ns and back across unrelated RTL edits.
        $lines[$s..([Math]::Min($s + 7, $lines.Count - 1))] |
            Select-String -Pattern '\s(\d+\.\d+)\s+\(R-R\)' -AllMatches |
            ForEach-Object {
                foreach ($m in $_.Matches) {
                    if ([double]$m.Groups[1].Value -lt 0.25) {
                        Write-Host ('  WARNING: slack ' + $m.Groups[1].Value + ' ns is thin') -ForegroundColor Yellow
                    }
                }
            }
    }
} else {
    Write-Host 'timing: report not found (run pnr)' -ForegroundColor Yellow
}

$bit = Join-Path $SysDir 'outflow\bitblt_system.bit'
if (Test-Path $bit) {
    $b = Get-Item $bit
    Write-Host ('bitstream: ' + [math]::Round($b.Length/1KB,1) + ' KB   ' + $b.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
} else {
    Write-Host 'bitstream: not generated' -ForegroundColor Yellow
}

$bin = Join-Path $SwDir 'bitblt_demo\build\bitblt_demo.bin'
if (Test-Path $bin) {
    $b = Get-Item $bin
    Write-Host ('driver   : ' + [math]::Round($b.Length/1KB,1) + ' KB   ' + $b.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + '   [' + $driverState + ']')
} else {
    Write-Host ('driver   : NO bitblt_demo.bin on disk   [' + $driverState + ']') -ForegroundColor Yellow
}

Pop-Location

Write-Host ''
if ($fail -eq 0) {
    Write-Host ('BUILD OK  (' + [math]::Round(((Get-Date) - $t0).TotalSeconds,1) + ' s)') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('BUILD FAILED: ' + $fail + ' step(s)') -ForegroundColor Red
    exit 1
}
