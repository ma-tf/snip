# Architecture

How `snip.exe` is put together, and the shape every subsystem explainer under `docs/`
follows. Read this before adding a module.

> **Explainer template.** This file is the template. Every subsystem explainer uses the same
> five headings — *What it is*, *Where it lives*, *How it works*, *Gotchas*, *See also* — so a
> reader can navigate any of them the same way. Keep each one short; the code is the source of
> truth and the explainer is the map.

## What it is

One pure-MASM64 Win32 executable, no C runtime, split into small named area modules that link
into a single `snip.exe`. The split exists so any one piece can be held in the head at a time:
each module owns one concern and talks to the others through explicit context structs, not
through globals.

The eventual areas, in the order the spec names them: `snip` (entry and process init),
`shell` (the main window), `capture`, `dib`, `overlay`, `select`, `geometry`, `mask`, `editor`,
`encode`. Modules land as their tickets do; the build has no list to update.

## Where it lives

| Path | What it holds |
| --- | --- |
| `src/*.asm` | One file per area module. Each is assembled to `build/<name>.obj` and linked. |
| `src/snip.inc` | **Our** interface: context structs, project constants and IDs, and the prototypes the modules call each other through. Platform-free. |
| `src/win32.inc` | The **platform** binding: one declaration of each Win32 import, SDK constant, and SDK struct layout we use. |
| `build/` | All outputs (`snip.obj`, `shell.obj`, `snip.exe`, `snip.pdb`, `objs.rsp`). Gitignored. |
| `build.cmd` | The build loop. |

The two includes are split by **reason to change**: `snip.inc` changes when we change an
interface between our modules; `win32.inc` changes when we bind a new API. A module that calls
Win32 includes both; a module that does not (the eventual `geometry` and `mask`) can include
only `snip.inc`. Each declaration has exactly one home, so no two modules can drift apart on a
struct layout or a signature.

## How it works

**The build loop globs.** `build.cmd` assembles every `src\*.asm` and writes the object paths
to `build\objs.rsp`, then links `@build\objs.rsp`. New area module = new file in `src/`; no
existing file is edited. `ml64 /I "%SRC%"` is what lets `include snip.inc` resolve regardless
of the current directory.

**No CRT, so the entry is ours.** `/subsystem:windows` normally wants `WinMainCRTStartup`, so
`build.cmd` passes `/entry:WinMainASM` and `/nodefaultlib`. `WinMainASM` (in `snip.asm`) is the
raw entry: it owns shadow space and 16-byte stack alignment, and ends in `ExitProcess` — never
`ret`.

**Process init, then windows.** `WinMainASM` sets per-monitor DPI awareness v2 *before* any
window exists, fills `App`, calls `shell_create(&app)`, and runs the message pump. Every later
ticket inherits the DPI declaration.

**State lives in `App`, owned by `snip.asm`.** A window receives the pointer as
`CreateWindowExW`'s `lpParam`, stashes it at `GWLP_USERDATA` in `WM_CREATE`, and recovers it
with `GetWindowLongPtrW` in later messages. Globals are reserved for the entry point's handles;
a singleton window's own chrome (its class, its last menu position) may live module-private.

**Windows claim, modules own.** `shell_create` registers the Shell class and shows the window;
the controls are built in `WM_CREATE`, where `lpCreateParams` arrives inside `CREATESTRUCTW`.

**Returns.** `eax` 0/nonzero for our own functions; Win32 `BOOL`/`HRESULT` values pass through
untouched.

**Segments earn their file bytes.** Where a module declares its data decides whether it costs
bytes in `snip.exe`. Read-only strings go in `.const` (`.rdata`); zero-initialised globals go
in `.data?` (`.bss`), which the loader zero-fills and which holds no file bytes. Reach for
`.data` only when a value is both mutable *and* initialised at load time — any `.data` byte
drags a 512-byte file block into the image. This is what keeps the build at ~4 KB; see
[`docs/build.md`](build.md).

## Gotchas

- **`cx` is a register name.** A struct field called `cx` is a MASM syntax error; `win32.inc`
  prefixes the `CREATESTRUCTW` client-size fields with `_`.
- **`PROTO` must agree with the `PROC`.** A `PROTO :QWORD` and a `PROC FRAME` with no
  parameters is a conflict (A2111). Declare our labels with `PROTO` and no parameter list, and
  document the signature in a comment.
- **Every non-leaf function is `PROC FRAME`** with `.pushreg`/`.allocstack` before
  `.endprolog`. `dumpbin /unwindinfo` should list one record per function; a missing record
  means a crash there cannot unwind.
- **Stack arguments start at `[rsp+20h]`**, after 32 bytes of shadow space. `CreateWindowExW`
  has twelve parameters, so it is the one call where the stack args are laid out by hand.
- **`GetStockObject(DEFAULT_GUI_FONT)`** is the font for stock controls; without `WM_SETFONT`
  they fall back to the ancient system font.

## See also

- [Building and debugging `snip.exe`](build.md) — the build and WinDbg loops.
- [`CONTEXT.md`](../CONTEXT.md) — the vocabulary the code and the tickets share.
- [`docs/adr/`](adr/) — the decisions that are expensive to reverse.
- [Ticket 01](../.scratch/asm-snip-build/issues/01-multi-module-build-shell.md) — the module
  layout and the Shell.
