# Board bring-up, one step at a time.
#
# WHY STEP-BY-STEP
#   docs/21 lists seven bring-up stages in dependency order, and the order is
#   the point: if step 3 fails, everything measured at steps 4-7 is meaningless.
#   Flashing the full demo and reading whatever comes out cannot distinguish
#   "DDR3 never calibrated" from "the renderer is slow", because both look like
#   a screen with nothing on it.
#
#   Each step below adds exactly one new thing and states what to look for.
#
# WHAT THIS SCRIPT DOES AND DOES NOT DO
#   It does not flash anything and it does not look at the screen. Flashing needs
#   Efinity's programmer and possibly a downloader tool that has not been
#   confirmed yet (see docs/35). Visual checks -- colour, tearing, wrong rows, a
#   frozen picture -- cannot be automated at all.
#
#   What it does is keep the sequence, the expectations and the findings in one
#   place, so a session at the bench is a checklist rather than a memory test.
#
# USAGE
#   pwsh -File bringup.ps1                 # show the plan and current status
#   pwsh -File bringup.ps1 -Step 3         # details and commands for one step
#   pwsh -File bringup.ps1 -Done 1,2       # record which steps have passed
#   pwsh -File bringup.ps1 -Check          # run board-check.ps1 against a log
#
# NOTE: ASCII only.

param(
    [int]$Step = 0,
    [int[]]$Done = @(),
    [switch]$Check,
    [string]$Port = '',
    [string]$LogFile = '',
    [string]$StateFile = 'C:\fpga_work\scripts\bringup-state.json',
    [string]$ScriptsDir = 'C:\fpga_work\scripts'
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- the plan
$steps = @(
    @{ n = 1; t = 'DDR3 calibration'
       what = 'Flash the bitstream only. No CPU program needed for this step.'
       expect = 'Screen shows something (noise is fine) rather than "no signal"'
       why = 'A bitstream that does not configure, or a PLL that does not lock, makes every later step meaningless.'
       fails = 'Monitor does not detect a signal, or the board does not configure at all.' },

    @{ n = 2; t = 'CPU runs and talks'
       what = 'Flash a minimal program that prints one line then loops. Best built by linking against the 4K on-chip script so it fits in RAM (docs/35).'
       expect = 'One line of text on the serial port'
       why = 'Proves toolchain -> bitstream -> CPU -> UART end to end, with nothing else in the way.'
       fails = 'Nothing on the port. Check baud 115200 and that the program really is inside the bitstream.' },

    @{ n = 3; t = 'AXI slave responds'
       what = 'Flash the full demo.'
       expect = 'board-check.ps1 reports PASS for axi-slave-responds'
       why = 'The register file is the only way software talks to the accelerator.'
       fails = 'STATUS reads 0xFFFFFFFF -- the SoC cannot reach the registers.' },

    @{ n = 4; t = 'Solid fill reaches the screen'
       what = 'In the demo log, look for the software and hardware fill reports, then look at the display.'
       expect = 'The screen changes colour'
       why = 'First proof that a render result reaches the panel. Until this passes, the display path is unproven no matter what the numbers say.'
       fails = 'Log looks fine but the screen does not change: the scan-out address or stride is wrong.' },

    @{ n = 5; t = '4KB burst crossing'
       what = 'Fill a per-row gradient and inspect the display.'
       expect = 'Rows 4, 8, 12, ... look the same as every other row'
       why = 'With stride 2560 a row burst crosses a 4KB boundary every four rows. Whether ddr3_top tolerates that is unknown and cannot be tested off-hardware.'
       fails = 'Rows at those positions are wrong or repeat the previous row -- the burst must be split at 4KB.' },

    @{ n = 6; t = 'AXI ID isolation'
       what = 'Run a copy and read it back, many times.'
       expect = 'Every read-back matches for all iterations'
       why = 'soc.v is encrypted, so its AXI IDs are unknown. Ours sit in the low nibble to reduce the chance of collision, but that is a probability, not a guarantee.'
       fails = 'Intermittent mismatches that move around between runs -- that is an ID collision.' },

    @{ n = 7; t = 'Interrupt arrives'
       what = 'Look for the interrupt verdict in the log.'
       expect = 'completion-interrupt-arrives PASS, and no "no done interrupt" warning'
       why = 'The done signal is a one-cycle pulse. Whether the PLIC gateway latches it is exactly what this step settles.'
       fails = 'WARNING: no done interrupt -- the pulse is too short; the interrupt needs to become level-held with a software clear.' },

    @{ n = 8; t = 'Performance numbers'
       what = 'Record the software and hardware fill rates the demo prints, and the on-screen SW/HW readout.'
       expect = 'Hardware substantially faster; compare against docs/24'
       why = 'These are the numbers the competition asks for, and the first real measurement of the design.'
       fails = 'Hardware not faster, or far off the modelled figures -- see docs/24 for what each gap would mean.' },

    @{ n = 9; t = 'Long run'
       what = 'Leave the demo and a DDR3 stress test running.'
       expect = 'No errors over a long period'
       why = 'Interface Designer warned about noise coupling on GPIOR_P_09. Long runs are the only way to see it.'
       fails = 'Rare, non-reproducible data errors.' }
)

# ---------------------------------------------------------------- state
$state = @{}
if (Test-Path $StateFile) {
    try {
        $j = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $state[$p.Name] = $p.Value }
    } catch { Write-Host ('NOTE: could not read ' + $StateFile) -ForegroundColor Yellow }
}
foreach ($d in $Done) { $state[[string]$d] = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
if ($Done.Count -gt 0) {
    $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
    Write-Host ('Recorded steps ' + ($Done -join ',') + ' as done.') -ForegroundColor Green
}

# ---------------------------------------------------------------- optional check
if ($Check) {
    $bc = Join-Path $ScriptsDir 'board-check.ps1'
    if (-not (Test-Path $bc)) { Write-Host ('ERROR: ' + $bc + ' not found') -ForegroundColor Red; exit 2 }
    if ($Port -ne '') {
        & $bc -Port $Port
    } elseif ($LogFile -ne '') {
        & $bc -FromFile $LogFile
    } else {
        Write-Host 'ERROR: -Check needs either -Port COMx or -LogFile <path>' -ForegroundColor Red
        exit 2
    }
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------- show one step
if ($Step -gt 0) {
    $s = $steps | Where-Object { $_.n -eq $Step }
    if (-not $s) { Write-Host ('No step ' + $Step) -ForegroundColor Red; exit 2 }
    Write-Host ''
    Write-Host ('STEP ' + $s.n + ': ' + $s.t) -ForegroundColor Cyan
    Write-Host ('  what   : ' + $s.what)
    Write-Host ('  expect : ' + $s.expect)
    Write-Host ('  why    : ' + $s.why)
    Write-Host ('  if bad : ' + $s.fails)
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------- show the plan
Write-Host ''
Write-Host 'Board bring-up plan (docs/21 has the full reasoning)' -ForegroundColor Cyan
Write-Host ''
foreach ($s in $steps) {
    $mark = if ($state.ContainsKey([string]$s.n)) { '[done]' } else { '[    ]' }
    $colour = if ($state.ContainsKey([string]$s.n)) { 'Green' } else { 'Gray' }
    Write-Host ('  ' + $mark + ' ' + $s.n + '. ' + $s.t) -ForegroundColor $colour
}
Write-Host ''
Write-Host '  pwsh -File bringup.ps1 -Step N        details for one step'
Write-Host '  pwsh -File bringup.ps1 -Done 1,2      mark steps as passed'
Write-Host '  pwsh -File bringup.ps1 -Check -Port COM3'
Write-Host ''
Write-Host '  Reminder: this cannot see the screen. Steps 1, 4, 5 and 9 need eyes.'
Write-Host ''
exit 0
