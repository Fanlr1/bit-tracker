# Board bring-up harness.
#
# WHAT IT DOES
#   Reads the board's UART, captures the demo output, and decides pass/fail from
#   the transcript -- so a run can be judged without a human reading it.
#
# WHY A SCRIPT RATHER THAN EYES
#   The bring-up sequence in docs/21 has seven steps and several amount to "look
#   for whether this line appeared". Reading that by eye across repeated
#   re-flashes is where mistakes happen, and a line that scrolled past looks the
#   same as one that never came. This captures everything and applies fixed rules.
#
# WHY -FromFile EXISTS
#   A check that has never been shown to fail is not a check -- a lesson this
#   project has already paid for several times. -FromFile runs the same decision
#   rules against a transcript captured earlier, so the rules can be tested
#   without a board attached.
#
# WHAT IT CANNOT DO
#   It cannot see the screen. Colour, tearing, wrong rows and a frozen picture
#   are visual and must still be checked by a person.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File board-check.ps1 -List
#   powershell -ExecutionPolicy Bypass -File board-check.ps1 -Port COM3
#   powershell -ExecutionPolicy Bypass -File board-check.ps1 -FromFile board_log.txt
#
# NOTE: ASCII only. A CJK .ps1 without a BOM breaks the Windows PowerShell parser.

param(
    [string]$Port = '',
    [int]$Baud = 115200,
    [int]$TimeoutSec = 180,
    [string]$OutFile = 'board_log.txt',
    [string[]]$Expect = @(),
    [string]$FromFile = '',
    [switch]$List
)

$ErrorActionPreference = 'Continue'

# ============================================================ list ports
if ($List) {
    Write-Host 'Serial ports visible to Windows:'
    $found = $false
    foreach ($p in [System.IO.Ports.SerialPort]::GetPortNames()) {
        $found = $true
        Write-Host ('  ' + $p)
    }
    if (-not $found) {
        Write-Host '  (none)'
        Write-Host ''
        Write-Host 'No serial ports at all usually means the USB-UART driver is missing,'
        Write-Host 'or the board is not powered / not plugged in.'
    }
    exit 0
}

# ============================================================ get a transcript
$joined = ''
$gotEnd = $false

if (-not [string]::IsNullOrWhiteSpace($FromFile)) {
    # ---- offline: judge an existing transcript ----
    if (-not (Test-Path $FromFile)) {
        Write-Host ('ERROR: no such file: ' + $FromFile) -ForegroundColor Red
        exit 2
    }
    $lines = @(Get-Content $FromFile -Encoding UTF8)
    $joined = ($lines -join "`n")
    $gotEnd = ($joined -match '\[TEST:SUMMARY\]') -or ($joined -match '=== demo complete ===')
    Write-Host ('Judging transcript: ' + (Resolve-Path $FromFile).Path)
    Write-Host ('  ' + $lines.Count + ' lines')

} else {
    # ---- live: capture from the serial port ----
    if ([string]::IsNullOrWhiteSpace($Port)) {
        Write-Host 'ERROR: -Port is required (use -List to see what is available)' -ForegroundColor Red
        exit 2
    }

    if ($Baud -ne 115200) {
        Write-Host ('NOTE: baud is ' + $Baud + ' but BSP_UART_BAUDRATE is 115200;')
        Write-Host '      check bsp.h before trusting the output.'
    }

    $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One
    $sp.ReadTimeout = 1000

    try { $sp.Open() }
    catch {
        Write-Host ('ERROR: cannot open ' + $Port + ' : ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host 'If the port is busy, close any serial terminal still holding it.'
        exit 2
    }

    Write-Host ('Listening on ' + $Port + ' at ' + $Baud + ' baud, up to ' + $TimeoutSec + ' s.')
    Write-Host 'Reset the board now (or it may already be running).'
    Write-Host '------------------------------------------------------------------'

    $buf = ''
    $raw = ''
    $t0  = Get-Date
    $buf = ''

    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        $chunk = ''
        try { $chunk = $sp.ReadExisting() } catch { $chunk = '' }

        if ($chunk) {
            Write-Host -NoNewline $chunk
            $raw += $chunk
            while ($raw.Contains("`n")) {
                $i = $raw.IndexOf("`n")
                $one = $raw.Substring(0, $i).TrimEnd("`r")
                $raw = $raw.Substring($i + 1)
                $buf += $one + "`n"
                if ($one -match '\[TEST:SUMMARY\]')      { $gotEnd = $true }
                if ($one -match '=== demo complete ===') { $gotEnd = $true }
            }
            if ($gotEnd) { break }
        } else {
            Start-Sleep -Milliseconds 100
        }
    }

    try { $sp.Close() } catch { }

    $joined = $buf
    Set-Content -Path $OutFile -Value $joined -Encoding UTF8
    Write-Host ''
    Write-Host ('log saved to ' + (Resolve-Path $OutFile).Path)
}

Write-Host ''
Write-Host '=================================================================='

# ============================================================ decision rules
#
# The firmware emits tagged verdicts of the form
#
#     [TEST:PASS] name
#     [TEST:FAIL] name (reason)
#     [TEST:SUMMARY] total=N fail=K
#
# so the primary rule is simply "read the firmware's own verdicts". That is far
# more robust than pattern-matching prose, because reworded messages would
# silently stop matching.
#
# A few structural checks remain, for failure modes where the firmware never
# gets to print a verdict at all (a hang, or a transcript that stops early).

$checks = @()

# ---- primary: whatever the firmware reported ----
$passNames = @()
$failNames = @()
foreach ($m in [regex]::Matches($joined, '\[TEST:PASS\]\s*(\S+)')) { $passNames += $m.Groups[1].Value }
foreach ($m in [regex]::Matches($joined, '\[TEST:FAIL\]\s*(\S+)')) { $failNames += $m.Groups[1].Value }

if ($passNames.Count -eq 0 -and $failNames.Count -eq 0) {
    $checks += @{
        name = 'firmware reported any verdict'
        ok   = $false
        hint = 'No [TEST:PASS] or [TEST:FAIL] line appeared. Either the firmware predates the tagged output, or it hung before reaching the first verdict.'
    }
} else {
    foreach ($n in $passNames) {
        $checks += @{ name = ('firmware: ' + $n); ok = $true; hint = '' }
    }
    foreach ($n in $failNames) {
        $checks += @{ name = ('firmware: ' + $n); ok = $false; hint = 'The firmware itself reported this as a failure.' }
    }
}

# ---- secondary: structural checks that do not depend on the firmware ----
if ($joined -match 'STATUS reads all ones') {
    $checks += @{
        name = 'AXI slave reachable (prose check)'
        ok   = $false
        hint = 'STATUS read back as 0xFFFFFFFF, so the SoC cannot reach the accelerator registers. Check the AXI address map and that the bitstream really contains the slave.'
    }
}

if ($joined -match 'engine reported ERROR') {
    $checks += @{
        name = 'no engine error (prose check)'
        ok   = $false
        hint = 'The BitBlt engine set its error flag, which points at a bad AXI response on the master side.'
    }
}

if ($joined -match 'WARNING: no done interrupt') {
    $checks += @{
        name = 'interrupt arrived (prose check)'
        ok   = $false
        hint = 'The done interrupt never arrived. This is one of the unknowns the first board run is meant to settle.'
    }
}

# THE SOFTWARE-VS-HARDWARE SPEED COMPARISON USED TO BE PARSED HERE.
#
# It matched 'software fill:\s*(\d+)\s*cycles/frame' and the hardware
# equivalent, and failed the run when neither was found. Those output formats no
# longer exist: main.c now emits a tagged line, and the comparison is a firmware
# assertion like any other --
#
#   test_result("hardware-faster-than-software", (hw_pf < sw_pf), ...)
#
# -- so it arrives as [TEST:PASS] or [TEST:FAIL] and is already counted above.
# The prose matcher was left behind by that change, which left it able to do
# exactly one thing: report "frame rate numbers captured" as FAILED on a board
# that was working perfectly. A stale check that fails a healthy system is worse
# than no check, because the first real failure gets dismissed as "that thing
# again".
#
# The three prose checks above are kept deliberately: their value is that they do
# NOT depend on the firmware being current. This one lacked that property -- it
# depended on exact output wording -- so it is removed rather than updated.

foreach ($e in $Expect) {
    $checks += @{
        name = ('transcript matches /' + $e + '/')
        ok   = ($joined -match $e)
        hint = 'Requested pattern not found.'
    }
}

# ============================================================ report
$fail = 0
foreach ($c in $checks) {
    if ($c.ok) {
        Write-Host ('  PASS  ' + $c.name) -ForegroundColor Green
    } else {
        Write-Host ('  FAIL  ' + $c.name) -ForegroundColor Red
        Write-Host ('        ' + $c.hint)
        $fail++
    }
}

Write-Host ''
if ($gotEnd) {
    Write-Host '  (transcript reached an end marker)'
} else {
    Write-Host '  WARNING: no end marker within the timeout -- capture may be incomplete' -ForegroundColor Yellow
    $fail++
}

Write-Host ''
Write-Host '  This script cannot see the display. Colour, tearing, correct rows'
Write-Host '  and a frozen picture still need a human look.'
Write-Host ''

if ($fail -eq 0) {
    Write-Host ('BOARD CHECK: PASS (' + $checks.Count + ' checks)') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('BOARD CHECK: ' + $fail + ' problem(s)') -ForegroundColor Red
    exit 1
}
