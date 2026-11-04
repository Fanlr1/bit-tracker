# Questa batch-simulation wrapper for this project.
#
# WHAT IT DOES
#   1. Sets SALT_LICENSE_SERVER (Questa-Altera Starter REQUIRES this variable --
#      LM_LICENSE_FILE does NOT work with it)
#   2. Runs vlib / vlog / vsim from a pure-ASCII working directory
#      (Questa's sqlite3 crashes on non-ASCII paths)
#   3. Decides pass/fail from the SIMULATION OUTPUT, not just vsim's exit code
#   4. Kills the run if it exceeds -TimeoutSec
#
# USAGE
#   pwsh -File C:\fpga_work\scripts\sim.ps1 -Top tb_counter -Files "counter.v tb_counter.v"
#
#   pwsh -File C:\fpga_work\scripts\sim.ps1 -Top tb_alpha_blend `
#        -Files "alpha_blend.v tb_alpha_blend.v" `
#        -PrimLibs "C:\Efinity\2026.1\sim_models\verilog\efx_dsp48.v"
#
#   add -Gui to open the GUI instead of a batch run.
#
# WHY THE EXIT CODE ALONE IS NOT ENOUGH (2026-10-06 audit finding)
#   vsim exits 0 whenever the simulator itself ran to completion. A testbench
#   that prints
#       RESULT: FAILED with 3 error(s)
#   and then calls $finish still leaves vsim with exit code 0, so the old
#   version of this script printed SIMULATION OK in green. None of the 11
#   testbenches called $fatal or $stop, so this path was never exercised -- it
#   simply had never been triggered, which is not the same as being correct.
#
# WHY PASS TEXT IS NOT TRUSTED
#   Some testbenches print PASS unconditionally right after the FAIL check, so a
#   failing case can emit both "FAIL ..." and "PASS ..." in the same log. This
#   script therefore keys on FAILURE markers only. A run that prints no verdict
#   at all is also treated as a failure, so a silent testbench cannot slip
#   through.
#
# DESIGN NOTE -- WHY -Files IS A [string] AND NOT [string[]]
#   Under -File, PowerShell does NOT collect multiple bare arguments into an
#   array parameter; it binds only the first and treats the rest as positional.
#   (That bug once pushed "tb\tb_alpha_blend.v" into -Work and broke the run.)
#   So the list arrives as ONE string and we split it here. Spaces, commas and
#   plus signs are all accepted as separators.
#
# NOTE: ASCII-only on purpose -- a CJK .ps1 without a BOM breaks the parser.

param(
    [Parameter(Mandatory = $true)][string]$Top,
    [Parameter(Mandatory = $true)][string]$Files,
    [string]$PrimLibs = '',
    [string]$Work = 'C:\fpga_work',
    [int]$TimeoutSec = 600,
    [switch]$Gui,
    # For measurement-only testbenches that print numbers and no verdict.
    #
    # The default below treats "no verdict found" as a failure, which is the
    # right default: a silently broken testbench must not look like a pass. But
    # tb_fifo_latency measures a FIFO's latency and has nothing to pass or fail,
    # so the strict rule flags it red every time -- and a check that cries wolf
    # is one people learn to ignore, which costs more than the check is worth.
    #
    # This switch is opt-in per run, so the strict default stays in force
    # everywhere else. It is deliberately named so that using it is a visible
    # decision in the command line rather than a silent property of a file.
    [switch]$ExpectNoVerdict
)

$fileList = @($Files    -split '[\s,+]+' | Where-Object { $_ -ne '' })
$primList = @($PrimLibs -split '[\s,+]+' | Where-Object { $_ -ne '' })

$Q   = 'C:\altera_pro\26.1.1\questa_fse\win64'
$Lic = 'C:\Users\25437\flexlm\LR-196860_License.dat'

if (-not (Test-Path $Q))   { Write-Host "ERROR: Questa not found at $Q" -ForegroundColor Red; exit 2 }
if (-not (Test-Path $Lic)) { Write-Host "ERROR: license not found at $Lic" -ForegroundColor Red; exit 2 }

# Questa-Altera Starter checks SALT_LICENSE_SERVER, not LM_LICENSE_FILE
$env:SALT_LICENSE_SERVER = $Lic

function Invoke-Bounded {
    # NOTE: the parameter is $ArgList, NOT $Args. $Args is a PowerShell
    # automatic variable; binding to it raised a terminating
    # ParameterBindingValidationException from Start-Process, which aborted the
    # script before it reached the verdict logic -- so the run reported success
    # without ever launching the simulator. Same failure shape this script
    # exists to eliminate, which is why it is called out here.
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec, [string]$Tag)
    $so = Join-Path $env:TEMP ($Tag + '_out.txt')
    $se = Join-Path $env:TEMP ($Tag + '_err.txt')

    # Start-Process re-joins the list into a command line, so any argument
    # containing a space (e.g. 'run -all; quit -f') must be quoted here or it
    # gets split into separate arguments.
    $quoted = @()
    foreach ($a in $ArgList) {
        if ($a -match '\s') { $quoted += ('"' + $a + '"') } else { $quoted += $a }
    }

    $p = $null
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $quoted -NoNewWindow -PassThru `
                           -RedirectStandardOutput $so -RedirectStandardError $se `
                           -ErrorAction Stop
    } catch {
        Write-Host ("FAILED to launch " + $Exe + " : " + $_.Exception.Message) -ForegroundColor Red
        Write-Host "  A failed launch is a failed run, not a pass."
        return @{ Text = ''; Code = 125; TimedOut = $false; LaunchFailed = $true }
    }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        Write-Host ("TIMEOUT after " + $TimeoutSec + " s -- process killed") -ForegroundColor Red
        Write-Host "  A testbench with an unbounded 'while' never returns if the DUT"
        Write-Host "  stops producing results, so a hang is itself a failure."
        return @{ Text = ''; Code = 124; TimedOut = $true; LaunchFailed = $false }
    }
    $txt = ''
    if (Test-Path $so) { $txt += (Get-Content $so -Raw -Encoding UTF8) }
    if (Test-Path $se) { $txt += (Get-Content $se -Raw -Encoding UTF8) }
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    return @{ Text = $txt; Code = $p.ExitCode; TimedOut = $false; LaunchFailed = $false }
}

Push-Location $Work
try {
    if (-not (Test-Path (Join-Path $Work 'work'))) {
        Write-Host "-- vlib work --"
        & "$Q\vlib.exe" work | Out-Null
    }

    $sources = @()
    $sources += $fileList
    $sources += $primList

    Write-Host ("  files    : " + ($fileList -join ', '))
    if ($primList.Count -gt 0) { Write-Host ("  primlibs : " + ($primList -join ', ')) }
    else                       { Write-Host  "  primlibs : (none)" }
    Write-Host ""

    Write-Host "-- vlog --"
    & "$Q\vlog.exe" @sources
    if ($LASTEXITCODE -ne 0) { Write-Host "vlog FAILED (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }

    Write-Host ""
    Write-Host "-- vsim $Top --"
    if ($Gui) {
        & "$Q\vsim.exe" $Top
        exit 0
    }

    $r = Invoke-Bounded -Exe "$Q\vsim.exe" -ArgList @('-c', '-do', 'run -all; quit -f', $Top) `
                        -TimeoutSec $TimeoutSec -Tag 'vsim'
    Write-Host $r.Text
    Write-Host ""

    $txt = [string]$r.Text
    $rc  = [int]$r.Code

    # --- decide from the OUTPUT, keying on failure markers only ---
    $hitFail  = $false
    $why      = ''

    if ($r.LaunchFailed) { $hitFail = $true; $why = 'the simulator could not be launched' }

    if (-not $hitFail -and $r.TimedOut) { $hitFail = $true; $why = 'timeout (no completion)' }

    if (-not $hitFail -and $rc -ne 0) { $hitFail = $true; $why = "vsim exit code $rc" }

    if (-not $hitFail) {
        $patterns = @(
            'RESULT:\s*FAIL',
            'FAILED\s+with\s+\d+\s+error',
            '\*\*\*\s*FAIL',
            '(?m)^\s*FAIL\b',
            'Errors:\s*[1-9]\d*',
            'Fatal:'
        )
        foreach ($p in $patterns) {
            if ($txt -match $p) { $hitFail = $true; $why = ("output matched /" + $p + "/"); break }
        }
    }

    # --- a testbench that prints no verdict at all is NOT a pass ---
    #
    # Unless the caller said this run is measurement-only, in which case there
    # is genuinely nothing to pass or fail and demanding a verdict would flag
    # every run red.
    if (-not $hitFail) {
        $anyVerdict = ($txt -match 'RESULT:|all checks OK|PASS:')
        if (-not $anyVerdict -and -not $ExpectNoVerdict) {
            $hitFail = $true
            $why = 'no pass/fail verdict found in the output'
        } elseif (-not $anyVerdict -and $ExpectNoVerdict) {
            Write-Host "NOTE: no verdict printed, accepted because -ExpectNoVerdict was given" -ForegroundColor Yellow
        }
    }

    Write-Host "--------------------------------------------------"
    if ($hitFail) {
        Write-Host ("SIMULATION FAILED   (" + $why + ")") -ForegroundColor Red
        exit 1
    } else {
        Write-Host "SIMULATION OK   (no failure markers in the output)" -ForegroundColor Green
        exit 0
    }
}
finally {
    Pop-Location
}
