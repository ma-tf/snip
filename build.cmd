@echo off
rem ===========================================================================
rem build.cmd - assemble and link snip.exe
rem
rem Usage:  build.cmd [debug|size] [clean]
rem
rem Finds the MSVC toolchain with vswhere, calls vcvars64.bat so ml64/link and
rem the SDK import libraries are on PATH/LIB, then assembles every src\*.asm into
rem build\<name>.obj and links them all into build\snip.exe. A new area module
rem joins the program simply by landing in src\ - there is no list to edit.
rem
rem Two variants differ only in debug info:
rem   debug (default)  /debug      -> snip.exe + snip.pdb    4,608 bytes
rem   size             /debug:none -> snip.exe, no snip.pdb  4,096 bytes
rem Both write build\snip.exe, so the run path never changes. See docs/build.md.
rem
rem Sources are pure MASM x64. /nodefaultlib + our own /entry: keep the CRT out.
rem ===========================================================================
setlocal

set "ROOT=%~dp0"
set "SRC=%ROOT%src"
set "OUT=%ROOT%build"

rem --- variant ---------------------------------------------------------------
rem debug (default) keeps the PDB and the RSDS path WinDbg loads automatically.
rem size drops it: no debug directory, and (with .pdata merged into .rdata and
rem .data moved to .bss) the image is one 512-byte block smaller.
set "MODE=debug"
set "LINKDEBUG=/debug"

rem "clean" on its own deletes build\ and stops, as before.
if /I "%~1"=="clean" (
    if exist "%OUT%" rmdir /s /q "%OUT%"
    echo cleaned %OUT%
    goto :eof
)

rem Optional mode, then an optional "clean" that also rebuilds.
if /I "%~1"=="debug" shift
if /I "%~1"=="size"  ( set "MODE=size" & set "LINKDEBUG=/debug:none" & shift )
if /I "%~1"=="clean" (
    if exist "%OUT%" rmdir /s /q "%OUT%"
    echo cleaned %OUT%
)

if not exist "%OUT%" mkdir "%OUT%"

rem --- locate vcvars64.bat ---------------------------------------------------
set "VCVARS="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * ^
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
        -find VC\Auxiliary\Build\vcvars64.bat`) do set "VCVARS=%%i"
)
if not defined VCVARS set "VCVARS=%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
    echo error: vcvars64.bat not found. Install the MSVC x64 build tools, or edit this script.
    exit /b 1
)

rem vcvars prints a banner and a stray errorlevel; quiet it and ignore its code.
call "%VCVARS%" >nul

rem --- assemble every source -------------------------------------------------
rem /I lets a source in src\ `include snip.inc` no matter the current directory.
if exist "%OUT%\objs.rsp" del "%OUT%\objs.rsp"
for %%f in ("%SRC%\*.asm") do (
    ml64 /nologo /c /Zi /I "%SRC%" /Fo "%OUT%\%%~nf.obj" "%%~f"
    if errorlevel 1 (
        echo error: ml64 failed on %%~nxf
        exit /b 1
    )
    echo "%OUT%\%%~nf.obj">>"%OUT%\objs.rsp"
)

rem --- link ------------------------------------------------------------------
rem The object list lives in a response file so no path is ever re-quoted by cmd.
rem /incremental:no drops the incremental-link table and its 0xCC padding (and
rem snip.ilk); /opt:ref,/opt:icf trim unreferenced and duplicate code; /release
rem sets the PE checksum. /merge:.pdata=.rdata folds the 512-byte unwind section
rem into .rdata, which is also read-only, so .text stays RX and nothing is lost.
link /nologo /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib ^
    /incremental:no /opt:ref /opt:icf /release /merge:.pdata=.rdata ^
    %LINKDEBUG% /out:"%OUT%\snip.exe" @"%OUT%\objs.rsp" ^
    kernel32.lib user32.lib gdi32.lib comctl32.lib
if errorlevel 1 (
    echo error: link failed
    exit /b 1
)

rem The size build writes no PDB; drop any left by an earlier debug build.
if /I "%MODE%"=="size" if exist "%OUT%\snip.pdb" del "%OUT%\snip.pdb"

rem objs.rsp is a one-shot intermediate; the next build regenerates it.
del "%OUT%\objs.rsp" >nul 2>&1

for %%f in ("%OUT%\snip.exe") do echo built %%f  (%%~zf bytes, %MODE%)
endlocal
