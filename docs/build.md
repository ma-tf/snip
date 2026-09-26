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
| `src/`          | Assembly sources and includes: `snip.asm` (entry), `shell.asm`, and the shared `snip.inc` / `win32.inc`. New area modules join the build by landing here. |
| `build/`        | Build outputs. `snip.exe` and the `*.obj` intermediates, plus `snip.pdb` in the debug variant; `objs.rsp` is deleted after a successful link. Gitignored. |
| `build.cmd`     | The build loop.                                                   |

## Building

```
build.cmd          # debug build: snip.exe + snip.pdb
build.cmd size     # size build:  snip.exe, no PDB
build.cmd clean    # delete build/
```

Two variants, same code, differing only in debug info — both write `build\snip.exe`, so
the run path never changes:

| Variant         | Link flag     | Output                     | Size      |
| --------------- | ------------- | -------------------------- | --------- |
| `debug` (default) | `/debug`    | `snip.exe` + `snip.pdb`    | 6,144 B   |
| `size`          | `/debug:none` | `snip.exe`                 | 6,144 B   |

The two variants are the same size at the moment: the debug directory (`RSDS` record +
type info) fits inside the `.rdata` block's slack, so it costs no extra block. When
`.rdata` grows past the next 512-byte boundary, `debug` will cost a block more than
`size`. Use `debug` while working in WinDbg and `size` when you want the leanest
artifact. `build.cmd size clean` cleans first and then builds; a bare `build.cmd clean`
only cleans.

Under the hood:

```
for each src\*.asm:
    ml64 /nologo /c /Zi /I src /Fo build\<name>.obj src\<name>.asm
    append build\<name>.obj to build\objs.rsp

link /nologo /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib ^
     /incremental:no /opt:ref /opt:icf /release /merge:.pdata=.rdata ^
     /debug /out:build\snip.exe @build\objs.rsp ^
     kernel32.lib user32.lib gdi32.lib comctl32.lib
```

(That is the `debug` variant; `size` swaps `/debug` for `/debug:none`.)

Seven things to know about those lines:

- **No CRT.** `/subsystem:windows` defaults the entry symbol to `WinMainCRTStartup`; with no
  C runtime linked, that symbol does not exist. We `PUBLIC` our own entry and name it with
  `/entry:WinMainASM`. `/nodefaultlib` enforces the absence of the CRT.
- **The toolchain is discovered, not hard-coded.** `build.cmd` asks `vswhere` for
  `VC\Auxiliary\Build\vcvars64.bat` and `call`s it, so `ml64`/`link` arrive via `PATH` and the
  SDK import libraries via `LIB`. That is why there are no `/libpath` switches here: pinning
  those to a specific SDK version is what breaks on the next upgrade.
- **The source list is globbed.** Every `src\*.asm` is assembled and the object paths go into
  `build\objs.rsp`, which `link` reads with `@`. Adding an area module means adding a file, not
  editing this script. `/I src` is what lets a source say `include snip.inc`.
- **The link strips and tidies.** `/incremental:no` drops the incremental link table and its
  `0xCC` padding; `/opt:ref` and `/opt:icf` drop unreferenced and duplicate code; `/release`
  sets the PE checksum. Without them `link` defaults to incremental, which pads `.text` by
  several kilobytes and leaves a `snip.ilk` behind — an executable whose size says nothing
  about how much it does.
- **Sections are packed.** `/merge:.pdata=.rdata` folds the unwind section into the read-only
  data section, so the image carries one fewer 512-byte block. `.pdata` is read-only too, so
  nothing is lost: the exception directory still points at the merged copy and WinDbg still
  unwinds.
- **`/Zi` + `/debug`.** Assemble with `/Zi` and link with `/debug` to emit `build\snip.pdb`.
  The `size` variant links `/debug:none` instead and deletes any stale PDB.
- **`comctl32.lib` is for ComboBoxEx.** The Shell's two drop-downs are `ComboBoxEx32`, not
  `ComboBox`, so the module links `comctl32` and registers the class with
  `InitCommonControlsEx(ICC_USEREX_CLASSES)` at process init. See `docs/shell.md`.

`snip.exe` opens a window titled `Snipping Tool` with three stock controls — a New button, a
mode drop-down, and a Delay drop-down, each row of which carries a small icon — and exits with
code 0 when the window is closed (`WM_DESTROY` → `PostQuitMessage(0)`).

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

- `/release` sets the PE checksum (so cdb no longer warns) and clears `/incremental`; the `.ilk`
  and the `0xCC` padding both disappear with it.
- The exe has no `.reloc` section: nothing carries a static absolute address. Add a pointer
  table in `.data` and one reappears — the loader then needs it to rebase under ASLR.
- `ml64` prints `Assembling: <path>` to stdout even with `/nologo`.
