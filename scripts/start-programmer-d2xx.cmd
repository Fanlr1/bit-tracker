@echo off
REM ==================================================================
REM  !!  DO NOT USE  --  CONFIRMED DEAD END, KEPT FOR THE RECORD  !!
REM ==================================================================
REM  This script used to launch Efinity Programmer with
REM  EFX_HIFTDI_ENABLE=1, hoping the D2XX/HiFTDI backend would let
REM  JTAG work while the official FTDI driver keeps the COM ports.
REM
REM  IT DOES NOT WORK. Evidence (2026-10-11, Efinity 2026.1.132):
REM
REM    * The device IS discovered via D2XX -- the Programmer showed
REM      "USB Target: (local) Quad RS232-HS / ID: 0403:6011".
REM    * But the JTAG engine then fails:
REM
REM        JtagEngine.configure() takes 2 positional arguments but 3 were given
REM        Switching to SPI mode because JTAG is not connected...
REM
REM      Root cause is in Efinity's own fork of PyFTDI:
REM        efx_pgm\hiftdi\jtag.py:448   def configure(self, url: str) -> None
REM      The caller passes a second argument. HiFTDI is a half-finished
REM      fork; this is not a configuration mistake on our side.
REM
REM    * It also silently switched Programming Mode to "SPI Active",
REM      which WRITES FLASH -- not what we want for routine bring-up.
REM
REM  WHAT TO DO INSTEAD:
REM    Keep Interface 1 (channel B = JTAG) bound to libusb-win32 via
REM    zadig, and leave Interfaces 0/2/3 on the official FTDI driver so
REM    the VCP COM ports survive. Then launch the Programmer normally.
REM
REM    See: work\board-prep\README.md and 板上调试-交接说明.md
REM ==================================================================

echo.
echo  ============================================================
echo   This launcher is a DEAD END and intentionally does nothing.
echo.
echo   HiFTDI/D2XX JTAG is broken in Efinity 2026.1.
echo   Use zadig -^> libusb-win32 on Interface 1 instead,
echo   then start the Programmer normally.
echo  ============================================================
echo.
pause
