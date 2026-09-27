@echo off
rem ===========================================================================
rem build.cmd - assemble and link snip.exe
rem
rem Usage:  build.cmd [debug|size] [clean]
rem
rem Finds the MSVC x86 toolchain with vswhere, calls vcvars32.bat so ml/link and
rem the 32-bit SDK import libraries are on PATH/LIB, then assembles every
rem src\*.asm into build\<name>.obj and links them all into build\snip.exe. A new
rem area module joins the program simply by landing in src\ - there is no list
rem to edit.
rem
rem Two variants:
rem   debug (default)  link /debug      -> snip.exe + snip.pdb   4096 bytes
rem   size             Crinkler         -> snip.exe alone         1038 bytes
rem Both write build\snip.exe, so the run path never changes. The size variant
rem is compressed by the vendored tools\crinkler.exe; it is NOT debuggable - no
rem PDB, no symbols. See docs/build.md and docs/adr/0002-x86-for-crinkler.md.
rem
rem Sources are pure MASM x86. /nodefaultlib + our own /entry: keep the CRT out.
rem ===========================================================================
setlocal

set "ROOT=%~dp0"
set "SRC=%ROOT%src"
set "OUT=%ROOT%build"
set "CRINKLER=%ROOT%tools\crinkler.exe"

rem --- variant ---------------------------------------------------------------
set "MODE=debug"

rem "clean" on its own deletes build\ and stops, as before.
if /I "%~1"=="clean" (
    if exist "%OUT%" rmdir /s /q "%OUT%"
    echo cleaned %OUT%
    goto :eof
)

rem Optional mode, then an optional "clean" that also rebuilds.
if /I "%~1"=="debug" shift
if /I "%~1"=="size"  ( set "MODE=size" & shift )
if /I "%~1"=="clean" (
    if exist "%OUT%" rmdir /s /q "%OUT%"
    echo cleaned %OUT%
)

if not exist "%OUT%" mkdir "%OUT%"

rem --- locate vcvars32.bat ---------------------------------------------------
set "VCVARS="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * ^
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
        -find VC\Auxiliary\Build\vcvars32.bat`) do set "VCVARS=%%i"
)
if not defined VCVARS set "VCVARS=%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars32.bat"
if not exist "%VCVARS%" (
    echo error: vcvars32.bat not found. Install the MSVC x86 build tools, or edit this script.
    exit /b 1
)

rem vcvars prints a banner and a stray errorlevel; quiet it and ignore its code.
call "%VCVARS%" >nul

if /I "%MODE%"=="size" if not exist "%CRINKLER%" (
    echo error: %CRINKLER% not found. The size build links with Crinkler;
    echo        see docs/build.md. Use "build.cmd debug" for the linked build.
    exit /b 1
)

rem --- assemble every source -------------------------------------------------
rem /c /coff: Crinkler reads COFF objects only (ml's default x86 format is OMF).
rem /I lets a source in src\ `include snip.inc` no matter the current directory.
if exist "%OUT%\objs.rsp" del "%OUT%\objs.rsp"
for %%f in ("%SRC%\*.asm") do (
    ml /nologo /c /coff /Zi /I "%SRC%." /Fo "%OUT%\%%~nf.obj" "%%~f"
    if errorlevel 1 (
        echo error: ml failed on %%~nxf
        exit /b 1
    )
    echo "%OUT%\%%~nf.obj">>"%OUT%\objs.rsp"
)

rem --- link / compress -------------------------------------------------------
rem LIBS has no ole32: its COM functions are forwards to an API-set DLL with no
rem file on disk, which Crinkler cannot read. encode.asm resolves them from
rem combase.dll at runtime instead. See encode.asm and docs/build.md.
set "LIBS=kernel32.lib user32.lib gdi32.lib gdiplus.lib comctl32.lib comdlg32.lib"

if /I "%MODE%"=="size" goto :size

rem debug: the ordinary linked build, with a PDB beside the exe.
rem /incremental:no drops the incremental-link table and its 0xCC padding (and
rem snip.ilk); /opt:ref,/opt:icf trim unreferenced and duplicate code; /release
rem sets the PE checksum. The entry is WinMainASM (decorated _WinMainASM@0; the
rem linker matches the name we give it).
link /nologo /machine:x86 /subsystem:windows /entry:WinMainASM /nodefaultlib ^
    /incremental:no /opt:ref /opt:icf /release ^
    /debug /out:"%OUT%\snip.exe" @"%OUT%\objs.rsp" ^
    %LIBS%
if errorlevel 1 (
    echo error: link failed
    exit /b 1
)
goto :done

:size
rem size: Crinkler replaces link. It hash-imports DLL functions and compresses
rem the image behind a self-extracting stub, so the import table and strings
rem cost far less. It emits no PDB. TINYHEADER is deliberately NOT used: it
rem shrinks the file ~44 bytes but Windows Defender quarantines its output.
rem /TRANSFORM:CALLS is a reversible byte transform applied before compression;
rem /ORDERTRIES reorders the parts to help the model: both cost nothing at
rem runtime and take the file from 2,858 to 2,696 bytes. ORDERTRIES is kept
rem modest (2,000, ~7s); 50,000 buys only 8 more bytes for a 69s build.
"%CRINKLER%" /OUT:"%OUT%\snip.exe" /SUBSYSTEM:WINDOWS /ENTRY:WinMainASM /NODEFAULTLIB ^
    /COMPMODE:SLOW /TRANSFORM:CALLS /ORDERTRIES:2000 ^
    @"%OUT%\objs.rsp" %LIBS%
if errorlevel 1 (
    echo error: Crinkler failed
    exit /b 1
)
rem No debug info in the size build; drop any PDB left by an earlier debug build.
if exist "%OUT%\snip.pdb" del "%OUT%\snip.pdb"

:done
rem objs.rsp is a one-shot intermediate; the next build regenerates it.
del "%OUT%\objs.rsp" >nul 2>&1

for %%f in ("%OUT%\snip.exe") do echo built %%f  (%%~zf bytes, %MODE%)
endlocal
