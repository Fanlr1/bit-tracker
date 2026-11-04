# Sync the GFX v2 sources from the workspace into the build tree.
#
# WHY THIS EXISTS
#   The Efinity project reads C:/fpga_work/gfx2, never the workspace. Every edit
#   has to be copied, and forgetting one silently builds the previous revision --
#   a failure mode this project has already paid for more than once.
#
# USAGE
#   pwsh -File sync-gfx2.ps1
#   pwsh -File sync-gfx2.ps1 -WhatIf     # list what would be copied
#
# NOTE: ASCII only.
param(
    [switch]$WhatIf,
    [string]$Dst = 'C:\fpga_work\gfx2',
    [string]$SwDst = 'C:\fpga_work\sw\gfx_demo\src'
)

$ws = Split-Path $PSScriptRoot -Parent
$pairs = @(
    @{ from = (Join-Path $ws 'rtl\gfx');             to = (Join-Path $Dst 'rtl\gfx');  filter = '*.v' },
    @{ from = (Join-Path $ws 'rtl');                 to = (Join-Path $Dst 'rtl');      filter = 'system_top_gfx.v' },
    @{ from = (Join-Path $ws 'fpga');                to = $Dst;                        filter = 'gfx2_system.xml' },
    @{ from = (Join-Path $ws 'fpga');                to = $Dst;                        filter = 'gfx2_system.peri.xml' },
    @{ from = (Join-Path $ws 'work\gfx_demo\src');   to = $SwDst;                      filter = '*.c' },
    @{ from = (Join-Path $ws 'work\gfx_demo\src');   to = $SwDst;                      filter = '*.h' }
)

$n = 0
foreach ($p in $pairs) {
    if (-not (Test-Path $p.from)) { Write-Host ('  MISSING SOURCE: ' + $p.from) -ForegroundColor Red; continue }
    if (-not (Test-Path $p.to))   { New-Item -ItemType Directory -Path $p.to -Force | Out-Null }
    Get-ChildItem -Path $p.from -Filter $p.filter -File | ForEach-Object {
        $dstFile = Join-Path $p.to $_.Name
        if ($WhatIf) {
            Write-Host ('  would copy ' + $_.Name + ' -> ' + $p.to)
        } else {
            Copy-Item $_.FullName $dstFile -Force
        }
        $n++
    }
}
if ($WhatIf) {
    Write-Host ('(dry run) ' + $n + ' file(s) would be copied')
} else {
    Write-Host ('synced ' + $n + ' file(s) into ' + $Dst)
}
