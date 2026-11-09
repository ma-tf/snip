# snip

A screen capture and annotation tool for Windows, written in x86 MASM assembly
against Win32. No C runtime; the Crinkler size build is about 11 KB.

## Features

- Rectangle, Window, Full screen, and Free-form capture
- Delay: none, 3, 5, or 10 seconds
- Pen, Highlighter, Eraser, Undo
- Copy (`CF_DIBV5`, PNG, `CF_DIB`) and Save As PNG
- Per-monitor DPI, multi-monitor Overlay, light/dark theme

## Build

Requires Windows 11, Visual Studio with the MSVC x86 tools, and the Windows SDK.

```bat
build.cmd        rem debug build
build.cmd size   rem Crinkler build, no PDB
build.cmd clean
build\snip.exe
```

The `size` build needs SSE4.2 and is not debuggable.

## Use

Pick a mode and delay, press **New**, mark a selection, then annotate and copy or
save. `Esc` or right-click cancels a capture.

| Key | Action |
| --- | --- |
| `Alt+N` | start a snip |
| `Alt+M` / `Alt+D` | open mode / delay drop-down |
| `Ctrl+C` / `Ctrl+S` | copy / save |
| `Ctrl+Z` | undo |
| `Tab` / `Space` | move focus / activate |

## Docs

- [`docs/architecture.md`](docs/architecture.md) — how the modules fit together
- [`docs/build.md`](docs/build.md) — build and debug details
- [`CONTEXT.md`](CONTEXT.md) — project vocabulary
