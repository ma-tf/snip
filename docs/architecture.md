# Architecture

How `snip.exe` is put together, and the shape every subsystem explainer under `docs/`
follows. Read this before adding a module.

> **Explainer template.** This file is the template. Every subsystem explainer uses the same
> five headings — *What it is*, *Where it lives*, *How it works*, *Gotchas*, *See also* — so a
> reader can navigate any of them the same way. Keep each one short; the code is the source of
> truth and the explainer is the map.

## What it is

One pure-MASM32 Win32 executable, no C runtime, split into small named area modules that link
into a single `snip.exe`. It is 32-bit x86 (stdcall) and runs under WOW64 on 64-bit Windows;
that target is chosen so the size build can be compressed by Crinkler, which does not support
x64 objects. See [`docs/adr/0002-x86-for-crinkler.md`](adr/0002-x86-for-crinkler.md).

The split exists so any one piece can be held in the head at a time: each module owns one
concern and talks to the others through explicit context structs, not through globals.

The eventual areas, in the order the spec names them: `snip` (entry and process init),
`shell` (the main window), `capture`, `dib`, `overlay`, `select`, `geometry`, `mask`, `editor`,
`encode`. Ticket 06 added an eleventh, `ink` — the annotation engine, kept out of `editor` so
the command log and the window chrome change for their own reasons. **Landed so far:** `snip`,
`shell`, `geometry`, `capture`, `dib`, `overlay`, `select`, `editor`, `encode`, `ink`, and now
`mask` (ticket 07), `err` (ticket 11), and `theme` (ticket 19). Modules land as their tickets do;
the build has no list to update.

## Where it lives

| Path | What it holds |
| --- | --- |
| `src/*.asm` | One file per area module. Each is assembled to `build/<name>.obj` and linked. |
| `src/snip.inc` | **Our** interface: context structs, project constants and IDs, and the prototypes the modules call each other through. Platform-free. || `src/win32.inc` | The **platform** binding: one declaration of each Win32 import, SDK constant, and SDK struct layout we use. |
| `build/` | All outputs (`snip.obj`, `shell.obj`, `snip.exe`, `snip.pdb`, `objs.rsp`). Gitignored. |
| `tools/crinkler.exe` | The vendored compressing linker the `size` build uses. Win32 build. |
| `build.cmd` | The build loop. |

The two includes are split by **reason to change**: `snip.inc` changes when we change an
interface between our modules; `win32.inc` changes when we bind a new API. A module that calls
Win32 includes both; a module that does not (the eventual `geometry` and `mask`) can include
only `snip.inc`. Each declaration has exactly one home, so no two modules can drift apart on a
struct layout or a signature.

## How it works

**The build loop globs.** `build.cmd` assembles every `src\*.asm` and writes the object paths
to `build\objs.rsp`, then links `@build\objs.rsp`. New area module = new file in `src/`; no
existing file is edited. `ml /I "%SRC%."` is what lets `include snip.inc` resolve regardless
of the current directory. `/c /coff` is mandatory as well as convenient: `ml` defaults to OMF
on x86, and the size build's Crinkler reads COFF objects only.

**No CRT, so the entry is ours.** `/subsystem:windows` normally wants `WinMainCRTStartup`, so
both linkers pass `/entry:WinMainASM` and `/nodefaultlib`. `WinMainASM` (in `snip.asm`) is the
raw entry: a stdcall `PROC` that never returns and ends in `ExitProcess`. MASM decorates the
symbol to `_WinMainASM@0`; the linker and Crinkler both match the undecorated name.

**Arguments go through `INVOKE`.** 32-bit MASM pushes stdcall arguments for us when a function
has a typed `PROTO` in `win32.inc`. That is why every Win32 import is declared with parameter
types, and why a module-local function called via `INVOKE` needs a forward `PROTO`.

**Process init, then windows.** `WinMainASM` sets per-monitor DPI awareness v2 *before* any
window exists, fills `App`, calls `shell_create(&app)`, and runs the message pump. Every later
ticket inherits the DPI declaration.

**State lives in `App`, owned by `snip.asm`.** A window receives the pointer as
`CreateWindowExW`'s `lpParam`, stashes it at `GWLP_USERDATA` in `WM_CREATE`, and recovers it
with `GetWindowLongW` in later messages. (x86 has no `...LongPtrW` export; the 32-bit build
calls the plain form.) Globals are reserved for the entry point's handles; a singleton
window's own chrome (its class, its last menu position) may live module-private.

**Windows claim, modules own.** `shell_create` registers the Shell class and shows the window;
the controls are built in `WM_CREATE`, where `lpCreateParams` arrives inside `CREATESTRUCTW`.
The Shell's drop-downs are `ComboBoxEx32` (comctl32, icons drawn at runtime); that detail and
its gotchas live in [`docs/shell.md`](shell.md).

**The window follows the system theme; the controls do not.** `theme.asm` asks uxtheme's
`ShouldSystemUseDarkMode` (ordinal 138) once at startup, picks one of two hardcoded palettes, and
dresses each top-level window with DWM rounded corners and a themed title bar. Only the chrome and
the surfaces the app draws itself (the client, the Editor's toolbar strip, the Shell's hint) change
with the theme; the stock controls stay light, because a dark common control needs comctl32 v6 and
its startup manifest, which the single-exe Crinkler build cannot carry. See
[`docs/theme.md`](theme.md) and
[ADR-0003](adr/0003-theme-chrome-only.md).

**The Overlay is a surface, the Selection is the behaviour.** `overlay.asm` owns the window,
the premultiplied DIB, and the chrome; `select.asm` owns the session state machine and the
gestures — a drag, a trace, a window hover, a monitor hover — and registers `sel_wndproc` as
the Overlay class's WndProc. `select` calls into
`overlay` and never the reverse. `geometry.asm` holds the crop maths Win32-free. See
[`docs/overlay.md`](overlay.md) and [`docs/select.md`](select.md).

**The Delay is a Sleep between New and the Overlay.** `App.delay` is the Delay drop-down's
index; `select_begin` maps it to milliseconds (No delay / 3 / 5 / 10 seconds) and calls
`Sleep` after hiding our windows and before raising the Overlay — so the wait is
mode-independent and the desktop is clear while the user arranges. It is a plain `Sleep`, which
blocks the UI thread; the only windows that thread would serve are already hidden. See
[`docs/delay.md`](delay.md).

**A completed Selection becomes a Snip, then the Editor opens.** `select_finish` runs the
handoff in order: `dib_crop` blits the Selection's region straight off the screen
(`capture.asm`) into an owned 32bpp straight-BGRA bitmap with a Pristine twin, then
`sel_restore` brings the Shell and Editor back, then `editor_open` sizes and shows the
Editor. The capture happens while both our windows are hidden, so neither lands in the snip;
the region blit means no full-screen buffer is ever held. Window mode swaps the region blit
for `PrintWindow(PW_RENDERFULLCONTENT)` off the UI thread with a timeout, then a plain
`PrintWindow`, then the region blit as the last resort. Full-screen mode keeps the region
blit but takes it from one monitor's rectangle — the one under the pointer — not the whole
virtual screen. See
[`docs/capture.md`](capture.md).

**The Editor is resizable and fits an oversized Snip.** `editor.asm` owns one scale,
computed by `editor_view`: the Snip scaled down to fit the image area, capped at 100% and
centred, so a full-screen Snip is seen whole rather than as a clipped corner. The same fit
maps the mouse back to Snip pixels. The first Snip sizes the window to the image; once the
user resizes, a new Snip leaves the size alone. See [`docs/editor.md`](editor.md).

**The desktop is not one monitor at (0,0).** A Selection is virtual-relative — the
Overlay's client space — and `select_finish` adds the virtual-screen origin once, at the
boundary, so capture and the Editor work in screen pixels. Geometry is read fresh every
session and never cached; a `WM_DISPLAYCHANGE` mid-session aborts it, and `WM_DPICHANGED`
rescales the Overlay's chrome. See [`docs/multimonitor.md`](multimonitor.md).

**A Snip leaves through WIC.** The Editor's toolbar has New, Save, Copy, Pen, Highlighter,
Eraser, and Undo. Copy and Save hand the live Snip to `encode.asm`, which encodes it as a PNG
with WIC straight from the DIB — no `HBITMAP`, one `IStream` body shared by the file and the
clipboard — and publishes `CF_DIBV5`, a registered `PNG`, and `CF_DIB`. Save As is the common
`GetSaveFileNameW` dialog. The COM entry points come from `combase.dll` at runtime, because
`ole32`'s are forwarders Crinkler cannot read. See [`docs/encode.md`](encode.md).

**Annotations are a command log, not pixels.** Pen and Highlighter marks are strokes held in
`ink.asm` and replayed onto the Working bitmap with GDI+, whose antialiasing is why GDI+ is in
the build. The Eraser removes whole strokes and Undo reverses the last operation, both by
rewriting the log and replaying onto the Pristine twin — so the captured pixels are never
drawn on and Undo stops at the pristine Snip. See [`docs/ink.md`](ink.md).

**A free-form Snip is cut, not enclosed.** `mask.asm` holds the pure Trace geometry — sampling,
RDP simplification, bbox, degenerate test — while `dib.asm` fills a GDI+ `GraphicsPath` onto a
scratch bitmap whose alpha is the per-pixel coverage and applies it to the Snip. Winding fill
forgives a self-crossing loop; the Overlay previews the same edge antialiased. See
[`docs/freeform.md`](freeform.md).

**A failure reports, it does not crash.** `err.asm` is the whole error surface: one
`err_show(hwnd, id)` helper and the app's messages. The module that owns the operation reports
at the point of failure, so `encode.asm` and `dib.asm` stay UI-free and return their `HRESULT`
or `BOOL`. A failed capture leaves the previous Snip intact and the Editor open; only a startup
failure (COM, the WIC factory, or the Shell window unavailable) ends the process. See
[`docs/errors.md`](errors.md).

**Returns.** `eax` 0/nonzero for our own functions; Win32 `BOOL`/`HRESULT` values pass through
untouched.

**The keyboard map is a table, not key handlers.** `keys.asm` builds two `HACCEL`s and the pump
offers every message to `keys_translate` before dispatching it. `TranslateAcceleratorW` turns
`Alt+N`, `Alt+M`, `Alt+D`, `Ctrl+C`, `Ctrl+S`, and `Ctrl+Z` into `WM_COMMAND`s carrying
`IDA_*` ids, and `IsDialogMessageW` supplies Tab traversal and combo arrows. Routing is by
capability — the Editor's table first, then the Shell's — so the shortcuts fire regardless of
which window has focus. See [`docs/keyboard.md`](keyboard.md).

**Segments earn their file bytes.** Where a module declares its data decides whether it costs
bytes in `snip.exe`. Read-only strings go in `.const` (`.rdata`); zero-initialised globals go
in `.data?` (`.bss`), which the loader zero-fills and which holds no file bytes. Reach for
`.data` only when a value is both mutable *and* initialised at load time. This is what keeps
the linked build small and the Crinkler `size` build smaller still; see
[`docs/build.md`](build.md).

## Gotchas

- **`cx` is a register name.** A struct field called `cx` is a MASM syntax error; `win32.inc`
  prefixes the `CREATESTRUCTW` client-size fields with `_`.
- **`PROTO` must agree with the `PROC`.** A `PROTO` that declares parameters and a `PROC` that
  declares none is a conflict (A2111). Keep the two in step, and give a module-local callee a
  forward `PROTO` if `WM_CREATE` (or anything else) reaches it with `INVOKE`.
- **Stdlib symbols are decorated.** In `.model flat, stdcall`, `WinMainASM PROC` assembles to
  `_WinMainASM@0` in the COFF symbol table. `/entry:WinMainASM` and Crinkler's
  `/ENTRY:WinMainASM` both accept the undecorated name; don't hard-code the decorated form.
- **The size build is not debuggable.** Crinkler emits no PDB and no symbols; run `build.cmd
  debug` in WinDbg instead. x86 has no `.pdata`/unwind tables at all — SEH is the `fs:[0]`
  chain — so the old `PROC FRAME` / `.pushreg` convention does not apply here.
- **`GetStockObject(DEFAULT_GUI_FONT)`** is the font for stock controls; without `WM_SETFONT`
  they fall back to the ancient system font.

## See also

- [Building and debugging `snip.exe`](build.md) — the build and WinDbg loops.
- [The Shell](shell.md) — the window, the ComboBoxEx controls, and the drawn icons.
- [The Overlay](overlay.md) — the layered surface, the dim, and the readout chrome.
- [The Selection](select.md) — the Snipping session and the drag state machine.
- [The Delay](delay.md) — the wait between New and the Overlay.
- [Free-form snips](freeform.md) — the Trace geometry and the coverage Mask.
- [The Snip and the capture path](capture.md) — the region blit, alpha synthesis, and the
  Editor window.
- [The Editor view](editor.md) — resizing, fit-to-window, and the client→Snip mapping.
- [The keyboard map](keyboard.md) — the accelerators, the routing, and Tab traversal.
- [Copy and Save As](encode.md) — WIC encoding, the clipboard formats, and the Save dialog.
- [Ink](ink.md) — the annotation model, the command log, and the Eraser and Undo.
- [Errors](errors.md) — the message-box error surface and which failures are fatal.
- [The theme](theme.md) — the system light/dark follow, the palette, and the window chrome.
- [DPI and multi-monitor](multimonitor.md) — coordinate spaces, the re-read rules, and the
  Overlay's DPI-scaled chrome.
- [`CONTEXT.md`](../CONTEXT.md) — the vocabulary the code and the tickets share.
- [`docs/adr/`](adr/) — the decisions that are expensive to reverse.
- [Ticket 01](../.scratch/asm-snip-build/issues/01-multi-module-build-shell.md) — the module
  layout and the Shell.
