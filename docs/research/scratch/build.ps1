# build.ps1 - assemble + link the scratch skeleton with absolute tool paths.
$ErrorActionPreference = 'Stop'

$msvc   = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64'
$umLib  = 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64'
$ucrt   = 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64'

$ml     = Join-Path $msvc 'ml64.exe'
$link   = Join-Path $msvc 'link.exe'

& $ml /nologo /c /Zi /Fo "$PSScriptRoot\skeleton.obj" "$PSScriptRoot\skeleton.asm"
if ($LASTEXITCODE -ne 0) { throw "ml64 failed: $LASTEXITCODE" }

& $link /nologo /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib `
    /debug /out:"$PSScriptRoot\skeleton.exe" "$PSScriptRoot\skeleton.obj" `
    /libpath:"$umLib" /libpath:"$ucrt" `
    kernel32.lib user32.lib gdi32.lib
if ($LASTEXITCODE -ne 0) { throw "link failed: $LASTEXITCODE" }

Write-Host "built $PSScriptRoot\skeleton.exe"
