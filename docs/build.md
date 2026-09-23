# Building and debugging `snip.exe`

Short explainer for this repo's build loop and debug loop. It assumes the pure-MASM64,
no-CRT setup the project uses, so it doubles as a note on what is unusual about it.

## Prerequisites

- Windows 11, AMD64.
- Visual Studio 18 Community with the MSVC x64 build tools (MSVC 14.51) and a Windows SDK
  (10.0.26100). Neither `ml64.exe` nor `link.exe` is on `PATH` by default; `build.cmd`
  handles that.

## Layout

| Path            | What it holds                                                     |
| --------------- | ----------------------------------------------------------------- |
| `src/`          | Assembly sources. Currently one: `snip.asm`.                      |
| `build/`        | All build outputs (`snip.obj`, `snip.exe`, `snip.pdb`, `.ilk`). Gitignored. |
| `build.cmd`     | The build loop.                                                   |

## Building

```
build.cmd          # assemble + link
build.cmd clean    # delete build/
```

Under the hood:

```
ml64 /nologo /c /Zi /Fo build\snip.obj src\snip.asm
link /nologo /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib ^
     /debug /out:build\snip.exe build\snip.obj kernel32.lib user32.lib gdi32.lib
```

Three things to know about those lines:

- **No CRT.** `/subsystem:windows` defaults the entry symbol to `WinMainCRTStartup`; with no
  C runtime linked, that symbol does not exist. We `PUBLIC` our own entry and name it with
  `/entry:WinMainASM`. `/nodefaultlib` enforces the absence of the CRT.
- **The toolchain is discovered, not hard-coded.** `build.cmd` asks `vswhere` for
  `VC\Auxiliary\Build\vcvars64.bat` and `call`s it, so `ml64`/`link` arrive via `PATH` and the
  SDK import libraries via `LIB`. That is why there are no `/libpath` switches here: pinning
  those to a specific SDK version is what breaks on the next upgrade.
- **`/Zi` + `/debug`.** Assemble with `/Zi` and link with `/debug` to emit `build\snip.pdb`.

`snip.exe` opens a window titled `Snipping Tool (asm)` and exits with code 0 when the window
is closed (`WM_DESTROY` → `PostQuitMessage(0)`).

## Debugging

**WinDbg is the debugger.** The modern `WinDbgX` is the interactive choice; classic
`windbg.exe` and `cdb.exe` live in
`C:\Program Files (x86)\Windows Kits\10\Debuggers\x64`. It reads both our PDB and the
`.pdata`/`.xdata` unwind records MASM emits from `PROC FRAME` + `.allocstack`/`.pushreg`,
which is what makes a crash in hand-written asm debuggable at all.

`cdb.exe` is the same engine on the command line, which is what a script or an agent can
drive. For example, confirming symbols resolve without running the program:

```
cdb -c "x snip!WinMainASM; q" build\snip.exe
```

**Symbols need no configuration.** `link /debug` stamps the PDB's path into the executable
(`RSDS`), so the debugger finds `build\snip.pdb` automatically. Only OS DLL symbols need
help; point the symbol server at a local cache:

```
set _NT_SYMBOL_PATH=srv*C:\symbols*https://msdl.microsoft.com/download/symbols
```

**Quick sanity check.** `dumpbin /unwindinfo build\snip.exe` should list a record for every
non-leaf function. If a function is missing, its `PROC FRAME` / `.allocstack` prologue is
wrong, and a crash inside it will not unwind cleanly.

## Deliberately not used

- **Visual Studio (`devenv`)** — needs a solution/project and offers nothing WinDbg does not
  for hand-written asm.
- **x64dbg** — not installed; would be a new dependency for no gain over WinDbg.

## Gotchas observed

- `link /debug` without `/RELEASE` leaves the PE checksum unset, so cdb prints
  `WARNING: Unable to verify checksum for snip.exe` on launch. Harmless; symbols load anyway.
- `ml64` prints `Assembling: <path>` to stdout even with `/nologo`.
