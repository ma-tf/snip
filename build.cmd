@echo off
rem ===========================================================================
rem build.cmd - assemble and link snip.exe
rem
rem Usage:  build.cmd [clean]
rem
rem Finds the MSVC toolchain with vswhere, calls vcvars64.bat so ml64/link and
rem the SDK import libraries are on PATH/LIB, then assembles src\snip.asm into
rem build\snip.obj and links build\snip.exe.
rem
rem Sources are pure MASM x64. /nodefaultlib + our own /entry: keep the CRT out.
rem ===========================================================================
setlocal

set "ROOT=%~dp0"
set "SRC=%ROOT%src"
set "OUT=%ROOT%build"

if /I "%~1"=="clean" (
    if exist "%OUT%" rmdir /s /q "%OUT%"
    echo cleaned %OUT%
    goto :eof
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

rem --- assemble ---------------------------------------------------------------
ml64 /nologo /c /Zi /Fo "%OUT%\snip.obj" "%SRC%\snip.asm"
if errorlevel 1 (
    echo error: ml64 failed
    exit /b 1
)

rem --- link -------------------------------------------------------------------
link /nologo /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib ^
    /debug /out:"%OUT%\snip.exe" "%OUT%\snip.obj" ^
    kernel32.lib user32.lib gdi32.lib
if errorlevel 1 (
    echo error: link failed
    exit /b 1
)

for %%f in ("%OUT%\snip.exe") do echo built %%f  (%%~zf bytes)
endlocal
