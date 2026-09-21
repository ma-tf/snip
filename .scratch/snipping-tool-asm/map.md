# Snipping Tool replica in x64 assembly

Label: wayfinder:map
Status: open

## Destination

A functional, runnable x64 `.exe` on Windows 11 that reproduces the classic Snipping Tool's core surface — the four snip modes, the delay, on-snip annotation, copy and save — written in pure MASM64 assembly against Win32, and built in steps the author understands.

## Notes

- **Platform**: Windows 11 (build 26200), AMD64.
- **Toolchain**: MASM64 (`ml64`) + `link` + Windows SDK, from VS 18 Community / MSVC 14.51 — located at `C:\Program Files\Microsoft Visual Studio\18\Community`. None of them are on PATH, so a build script must call `vcvars64` or use absolute paths.
- **Purity**: pure asm. No C/C++ translation units linked in. COM is permitted (`ole32`, GDI+, WIC) — it is how the image encoder stays pure. Any exception must be documented in the ticket that needs it.
- **Learning is half the point**: every subsystem lands with a short explainer under `docs/`. Prefer small, understandable units over clever ones.
- **Reference**: classic Snipping Tool (Win7/8.1) — two-window shape (main window + annotation editor), four modes, Pen / Highlighter / Eraser, Copy, Save As.
- **DPI and multi-monitor are in scope from day one**: per-monitor DPI awareness v2, overlay spanning the virtual screen.
- **Skills**: default to `grilling` + `domain-modeling`; use `research` for facts outside the repo.
- **Tracker**: local markdown (see `docs/agents/issue-tracker.md`). No git repo yet, so research findings land as files under `docs/research/`, not branches.

## Decisions so far

- [Minimal MASM64 Win32 GUI skeleton](issues/01-masm64-win32-skeleton.md): `ml64 /c` then `link /subsystem:windows /entry:WinMainASM` with explicit SDK `/libpath`s builds and runs — verified on this machine. Without the CRT, `/entry:` is mandatory, the caller owns shadow space and 16-byte stack alignment, and `PROC FRAME` + `.pushreg`/`.allocstack` emits debuggable unwind info for free.

## Not yet specified

- Main window shell: control layout, the Options dialog's contents, always-on-top behaviour, and how it hands off to a snipping session.
- Error handling and failure modes: capture failure, encoder failure, a locked clipboard — and whether there is any user-facing error surface at all.
- Keyboard access: accelerators, Escape/Enter semantics, focus and tab order across the two windows.
- Multi-monitor edge cases: mixed DPI across monitors, monitors at negative origins, a topology change mid-snip.
- Memory strategy for the large DIBs: one arena vs per-allocation, freeing and pooling.
- The `docs/` explainer template — settles with the first subsystem doc.
- Latency and smoothness targets, especially annotation on a 4K canvas.

## Out of scope

- Screen recording / MP4 capture.
- OCR "text actions".
- Auto-save to `Pictures\Screenshots`.
- A Print Screen global hook.
- Tray icon and global hotkey.
- JPEG / GIF and other output formats beyond PNG (and BMP as a trivial fallback).
- Distribution: installer, code signing, portability, ARM64.
- Matching Snip & Sketch / Win11 visual styling.
