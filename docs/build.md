# Building and debugging `snip.exe`

Short explainer for this repo's build loop and debug loop. It assumes the pure-MASM32,
no-CRT, x86-under-WOW64 setup the project uses, so it doubles as a note on what is unusual
about it. The x86 target itself is explained in
[`docs/adr/0002-x86-for-crinkler.md`](adr/0002-x86-for-crinkler.md).

## Prerequisites

- Windows 11, x86-64 host (the exe runs 32-bit under WOW64).
- Visual Studio 18 Community with the MSVC **x86** build tools and a Windows SDK. Neither
  `ml.exe` nor `link.exe` is on `PATH` by default; `build.cmd` handles that via
  `vcvars32.bat`.
- `tools/crinkler.exe` — the vendored compressing linker (Crinkler 3.0b, Win32 build, Zlib
  licence in `tools/crinkler.LICENSE.txt`). Needed for the `size` build only.
- The machine (and any machine the compressed exe runs on) needs **SSE4.2**: Crinkler 3.0 and
  its output require it.

## Layout

| Path            | What it holds                                                     |
| --------------- | ----------------------------------------------------------------- |
| `src/`          | Assembly sources and includes: `snip.asm` (entry), `shell.asm`, and the shared `snip.inc` / `win32.inc`. New area modules join the build by landing here. |
| `build/`        | Build outputs. `snip.exe` and the `*.obj` intermediates, plus `snip.pdb` in the debug variant; `objs.rsp` is deleted after a successful build. All gitignored **except** `build/snip.exe`, which is committed as the shipped size build. |
| `tools/`        | The vendored Crinkler executable and its licence.                  |
| `build.cmd`     | The build loop.                                                   |

## Building

```
build.cmd          # debug build: snip.exe + snip.pdb
build.cmd size     # size build:  snip.exe, compressed by Crinkler, no PDB
build.cmd clean    # delete build/
```

Two variants, both writing `build\snip.exe`, so the run path never changes:

| Variant         | Linked by      | Output                     | Size      |
| --------------- | -------------- | -------------------------- | --------- |
| `debug` (default) | `link /debug` | `snip.exe` + `snip.pdb`    | 29,696 B  |
| `size`          | Crinkler 3.0b  | `snip.exe`                 | 9,142 B   |

The `size` variant is not "the debug build with the PDB removed" — it is a different linker.
Crinkler resolves DLL imports by hash (four bytes each, instead of a full import table) and
compresses the image behind a self-extracting stub. `build.cmd size clean` cleans first and then
builds; a bare `build.cmd clean` only cleans.

**The `size` exe is committed.** `.gitignore` ignores `build/` but re-includes `build/snip.exe`,
so the Crinkler-compressed binary is tracked as the shipping artifact. Because both variants
write the same path, a later `debug` build overwrites the tracked copy with the larger,
symbol-carrying exe; run `build.cmd size` to restore the packed one before committing.

Under the hood:

```
for each src\*.asm:
    ml /nologo /c /coff /Zi /I "src." /Fo build\<name>.obj src\<name>.asm
    append build\<name>.obj to build\objs.rsp

rem debug
link /nologo /machine:x86 /subsystem:windows /entry:WinMainASM /nodefaultlib ^
     /incremental:no /opt:ref /opt:icf /release /debug ^
     /out:build\snip.exe @build\objs.rsp ^
     kernel32.lib user32.lib gdi32.lib gdiplus.lib comctl32.lib comdlg32.lib

rem size
tools\crinkler.exe /OUT:build\snip.exe /SUBSYSTEM:WINDOWS /ENTRY:WinMainASM /NODEFAULTLIB ^
     /COMPMODE:SLOW /TRANSFORM:CALLS /ORDERTRIES:2000 @build\objs.rsp ^
     kernel32.lib user32.lib gdi32.lib gdiplus.lib comctl32.lib comdlg32.lib
```

Ten things to know about those lines:

- **No CRT.** `/subsystem:windows` defaults the entry symbol to `WinMainCRTStartup`; with no
  C runtime linked, that symbol does not exist. We `PUBLIC` our own entry and name it with
  `/entry:WinMainASM`. `/nodefaultlib` enforces the absence of the CRT, and stops Crinkler
  from pulling in `msvcrt.dll` for us.
- **`/c /coff` is not optional.** `ml`'s default x86 object format is OMF; Crinkler reads COFF
  only. The plain linker accepts either, but the build uses COFF throughout.
- **The toolchain is discovered, not hard-coded.** `build.cmd` asks `vswhere` for
  `VC\Auxiliary\Build\vcvars32.bat` and `call`s it, so `ml`/`link` arrive via `PATH` and the
  32-bit SDK import libraries via `LIB`. That is why there are no `/libpath` switches here:
  pinning those to a specific SDK version is what breaks on the next upgrade.
- **The source list is globbed.** Every `src\*.asm` is assembled and the object paths go into
  `build\objs.rsp`, which both linkers read with `@`. Adding an area module means adding a
  file, not editing this script.
- **`comctl32.lib` is for ComboBoxEx.** The Shell's two drop-downs are `ComboBoxEx32`, not
  `ComboBox`, so the module links `comctl32` and registers the class at process init with
  `InitCommonControlsEx(ICC_USEREX_CLASSES)`. The 16×16 row glyphs are drawn at runtime with
  GDI into one masked image list — no icon resources, no `.rsrc`. See [`docs/shell.md`](shell.md).
- **`gdiplus.lib` is for antialiased ink.** GDI cannot antialias, so the Pen and Highlighter
  strokes are drawn with GDI+. `gdiplus.dll` is a real file on disk (not an API-set forwarder),
  so it links statically in both variants and needs no `combase`-style runtime resolution.
  `ink_init` starts GDI+ once from `snip.asm`; a failure leaves the annotation buttons inert.
  See [`docs/ink.md`](ink.md).
- **No `ole32`, and `combase` at runtime.** `ole32.lib`'s COM entry points
  (`CoInitializeEx`, `CoCreateInstance`, `CreateStreamOnHGlobal`, `GetHGlobalFromStream`) are
  exported only as *forwarders* to `api-ms-win-core-com-l1-1-0`, an API-set name with no file
  on disk. `link` follows the forward, but Crinkler reads the exporting DLL to hash its
  exports and dies with `Cannot find DLL API-MS-WIN-CORE-COM-L1-1-0.DLL`. So `encode.asm`
  loads `combase.dll` — the real implementation, which exports all four directly — and
  resolves them with `GetProcAddress` at startup. `comdlg32.lib` is the ordinary Save As
  dialog. See [`docs/encode.md`](encode.md).
- **The debug link strips and tidies.** `/incremental:no` drops the incremental link table and
  its `0xCC` padding; `/opt:ref` and `/opt/icf` drop unreferenced and duplicate code;
  `/release` sets the PE checksum. Without them `link` defaults to incremental, which pads
  `.text` by several kilobytes and leaves a `snip.ilk` behind.
- **The size build is Crinkler.** It hash-imports the DLL functions, compresses code and data
  as separate parts, and writes a self-contained exe. It emits no PDB, and it does **not**
  support manifests — neither matters here, because DPI awareness is set by API call, not a
  manifest. `TINYHEADER` is deliberately not used even though it saves ~44 bytes: Windows
  Defender quarantines its output (measured 2026-09-26).
- **Two Crinkler flags earn their keep.** `/TRANSFORM:CALLS` applies a reversible byte
  transform before compression (2,858 → 2,737 B); `/ORDERTRIES:2000` reorders the parts to fit
  the model better (→ 2,696 B, ~7 s). Neither changes runtime behaviour — the decompressor
  undoes the transform. Higher `ORDERTRIES` is a dead end: 50,000 buys 8 more bytes for a 69 s
  build. `/COMPMODE:SLOW` is already the maximum (there is no `VERYSLOW` in Crinkler 3.0), and
  the run reports "Bytes lost to hashing" under 2, so the compressor is at its limit.
- **Crinkler's Win32 build, not Win64.** A 64-bit Crinkler reads the real `System32`, finds
  64-bit DLLs, and skips them; the 32-bit tool under WOW64 is redirected to `SysWOW64` and
  finds the 32-bit export tables it needs. The vendored binary is the Win32 one.

`snip.exe` opens a window titled `Snipping Tool` with a New button and two `ComboBoxEx`
drop-downs — the snip mode and the delay, each row carrying a 16×16 glyph drawn at runtime —
and exits with code 0 when the window is closed (`WM_DESTROY` → `PostQuitMessage(0)`).
Pressing New starts a Snipping session: the Shell hides, the Overlay covers the virtual
screen, and a rectangular Selection can be dragged (ticket 02). Completing the Selection
blits its region straight off the screen into a Snip — an owned 32bpp straight-BGRA DIB
with a Pristine twin — and opens the Editor window sized to it, reused for every later
Snip (ticket 03). The Editor carries a toolbar whose New, Copy, and Save are live (ticket
05): Copy puts the Snip on the clipboard as `CF_DIBV5`, a registered `PNG`, and `CF_DIB`,
and Save writes a PNG through the standard dialog — both encoded by WIC straight from the
DIB. Pen, Highlighter, Eraser, and Undo are live too (ticket 06): strokes are held as a
command log and replayed onto the Working bitmap with GDI+, the Eraser removes whole strokes,
and Undo reverses the last operation. Sizes: `debug` **35,840 B** plus `snip.pdb`; `size`
(Crinkler) **11,016 B** — both remeasured 2026-10-12, well up from the 29,696 B / 9,142 B written
here at ticket 06: the Fluent control skin (tickets 01–04), the drop-down glyph cache, and the
face-repaint fix (see [`shell.md`](shell.md)) together cost +512 B debug, +82 B compressed.

## Debugging

**WinDbg is the debugger.** The modern `WinDbgX` is the interactive choice; classic
`windbg.exe` and `cdb.exe` live in
`C:\Program Files (x86)\Windows Kits\10\Debuggers\x64`. Use the **`debug`** variant: the
`size` variant has no symbols, and Crinkler input is not worth stepping through.

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

**x86 exception handling is not the x64 story.** There are no `.pdata`/`.xdata` unwind tables
and no `PROC FRAME`/`.pushreg`/`.allocstack` boilerplate. Structured exceptions chain through
`fs:[0]` only if we register a handler, which nothing does yet. The old
`dumpbin /unwindinfo` check does not apply to this target.

## Deliberately not used

- **A 64-bit build.** Crinkler has no x64 support, so the app is x86 to keep one small size
  build. See ADR-0002.
- **`TINYHEADER`.** Smaller output, but Defender removes it.
- **Visual Studio (`devenv`)** — needs a solution/project and offers nothing WinDbg does not
  for hand-written asm.
- **x64dbg** — not installed; would be a new dependency for no gain over WinDbg.

## Gotchas observed

- `/release` sets the PE checksum (so cdb no longer warns) and clears `/incremental`; the
  `.ilk` and the `0xCC` padding both disappear with it.
- The x86 exe **does** carry a `.reloc` section: the WNDCLASSEXW/etc. absolute addresses need
  it to rebase under ASLR. That is normal for this target and no longer something to chase.
- `ml` prints `Assembling: <path>` to stdout even with `/nologo`.
- **Antivirus is an active hazard.** Windows Defender removed the Crinkler `TINYHEADER` output
  within a second of it being written. The current `size` output (9,142 B, no TINYHEADER)
  survived and ran, but Crinkler output is a documented false-positive magnet. If a build
  silently produces no `snip.exe`, check Defender's protection history before debugging the
  build.
