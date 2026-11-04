# Compile ONLY the RISC-V application -- no synthesis, no place and route.
#
# WHY THIS EXISTS
#   build-all.ps1 runs the whole Efinity flow, which is minutes of work. An
#   experiment that changes only C code (a new sweep, a different sprite size)
#   needs none of it: the bitstream is unchanged and only bitblt_demo.bin has
#   to be rebuilt. Re-synthesising identical RTL costs minutes per iteration.
#
# WHAT IT IS NOT
#   It does not flash the board and it does not touch the bitstream. A stale
#   bitblt_demo.bin is the one failure mode to watch for, so the script prints
#   the size and the write time of what it produced.
#
# USAGE
#   pwsh -File build-sw.ps1
#   pwsh -File build-sw.ps1 -SwDir C:\fpga_work\sw
#
# The compile and link flags are copied verbatim from build-all.ps1. If one
# changes, the other must: they are deliberately identical strings.
#
# NOTE: ASCII only.

param(
    [string]$SwDir = 'C:\fpga_work\sw',
    [string]$Toolchain = 'C:\fpga_work\toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
)

$ErrorActionPreference = 'Continue'

$gcc  = Join-Path $Toolchain 'riscv-none-elf-gcc.exe'
$objc = Join-Path $Toolchain 'riscv-none-elf-objcopy.exe'
if (-not (Test-Path $gcc)) {
    Write-Host ('ERROR: toolchain not found: ' + $gcc) -ForegroundColor Red
    exit 2
}

$bsp = Join-Path $SwDir 'bsp\efinix\EfxSapphireSoc'
$sa  = Join-Path $SwDir 'standalone'
$out = Join-Path $SwDir 'bitblt_demo\build'
New-Item -ItemType Directory -Path (Join-Path $out 'obj') -Force | Out-Null

$cf = @('-march=rv32im_zicsr','-mabi=ilp32','-DUSE_GP','-g3','-Os',
        ('-I' + (Join-Path $bsp 'include')),
        ('-I' + (Join-Path $sa  'include')),
        ('-I' + (Join-Path $sa  'driver')),
        '-DSYSTEM_UART_A_APB=SYSTEM_UART_0_IO_APB',
        '-DSYSTEM_GPIO_A_APB=SYSTEM_GPIO_0_IO_APB',
        '-DSYSTEM_I2C_A_APB=SYSTEM_I2C_0_IO_APB')

$bad = 0
foreach ($one in @('main.c', 'game.c', 'game_input.c')) {
    $oneSrc = Join-Path $SwDir ('bitblt_demo\src\' + $one)
    $oneObj = Join-Path $out ('obj\' + [IO.Path]::GetFileNameWithoutExtension($one) + '.o')
    Write-Host ('  cc   ' + $one)
    # Capture first, then read the exit code: reading $LASTEXITCODE after a
    # pipeline gives the LAST PIPELINE STAGE's status, not the compiler's.
    $log = & $gcc @cf -Wall -c $oneSrc -o $oneObj 2>&1
    $rc  = $LASTEXITCODE
    if ($rc -ne 0) {
        $log | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        $bad++
    } else {
        $log | Select-String -Pattern 'error|warning' |
            ForEach-Object { Write-Host ('       ' + $_) -ForegroundColor Yellow }
    }
}

if ($bad -ne 0) { Write-Host 'COMPILE FAILED' -ForegroundColor Red; exit 1 }

Write-Host '  link'
$log = & $gcc @cf -o (Join-Path $out 'bitblt_demo.elf') `
    (Join-Path $out 'obj\start.o') (Join-Path $out 'obj\trap.o') `
    (Join-Path $out 'obj\main.o') (Join-Path $out 'obj\game.o') (Join-Path $out 'obj\game_input.o') `
    ('-L' + (Join-Path $sa 'common')) '-specs=nosys.specs' '-lgcc' '-nostartfiles' '-ffreestanding' `
    ('-Wl,-Bstatic,-T,' + (Join-Path $bsp 'linker\default.ld')) '-lm' '-lc' 2>&1
if ($LASTEXITCODE -ne 0) {
    $log | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host 'LINK FAILED' -ForegroundColor Red
    exit 1
}
$log | Select-String -NotMatch 'RWX permissions' |
    ForEach-Object { Write-Host ('       ' + $_) -ForegroundColor Yellow }

& $objc -O binary (Join-Path $out 'bitblt_demo.elf') (Join-Path $out 'bitblt_demo.bin') 2>&1 | Out-Null
& $objc -O ihex   (Join-Path $out 'bitblt_demo.elf') (Join-Path $out 'bitblt_demo.hex') 2>&1 | Out-Null

$bin = Get-Item (Join-Path $out 'bitblt_demo.bin')
Write-Host ''
Write-Host ('BUILD OK  ' + $bin.FullName) -ForegroundColor Green
Write-Host ('  size    : ' + $bin.Length + ' bytes')
Write-Host ('  written : ' + $bin.LastWriteTime)
