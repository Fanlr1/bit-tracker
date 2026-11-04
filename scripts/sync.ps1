# Sync RTL sources from the project workspace into the ASCII simulation area.
#
# WHY: Questa's internal sqlite3 cannot open paths containing non-ASCII characters
# (the project workspace lives under Desktop\<CJK>\...), so every simulation run
# must happen under a pure-ASCII path. This script is the one-way bridge.
#
# USAGE:
#   pwsh -File C:\fpga_work\scripts\sync.ps1 -Source "<project workspace>"
# or set the environment variable FPGA_SRC once and just run:
#   pwsh -File C:\fpga_work\scripts\sync.ps1
#
# NOTE: this file is deliberately ASCII-only. A .ps1 containing CJK but saved
# without a BOM gets mis-decoded by PowerShell and breaks at parse time.

param(
    [string]$Source = $env:FPGA_SRC,
    [string]$Dest   = 'C:\fpga_work',
    [string]$Libs = 'C:\Efinity\2026.1\sim_models\verilog'
)

if (-not $Source) {
    Write-Host "ERROR: no source path. Pass -Source or set FPGA_SRC." -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $Source)) {
    Write-Host "ERROR: source path does not exist: $Source" -ForegroundColor Red
    exit 2
}

$srcDst = Join-Path $Dest 'src'
$tbDst  = Join-Path $Dest 'tb'
New-Item -ItemType Directory -Path $srcDst, $tbDst -Force | Out-Null

$copied = 0

function Copy-Set {
    param([string]$From, [string]$To, [string]$Filter)
    if (-not (Test-Path $From)) { return }
    Get-ChildItem -Path $From -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue | ForEach-Object {
        $target = Join-Path $To $_.Name
        Copy-Item $_.FullName $target -Force
        Write-Host ("  " + $_.Name)
        $script:copied++
    }
}

Write-Host "source : $Source"
Write-Host "dest   : $Dest"
Write-Host ""
Write-Host "-- RTL (.v) --"
Copy-Set -From (Join-Path $Source 'rtl') -To $srcDst -Filter '*.v'
Copy-Set -From (Join-Path $Source 'src') -To $srcDst -Filter '*.v'
Write-Host "-- testbench (tb_*.v) --"
Copy-Set -From (Join-Path $Source 'tb')  -To $tbDst  -Filter 'tb_*.v'

Write-Host ""
Write-Host "copied $copied file(s)."
Write-Host ""
Write-Host "NOTE: Efinity primitive models (needed for DSP/RAM/FF primitives) live at:"
Write-Host "      $Libs"
Write-Host "      Pass them to vlog explicitly, e.g. efx_dsp48.v"
