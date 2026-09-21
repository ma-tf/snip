# Minimal MASM64 Win32 GUI skeleton

Label: wayfinder:research
Type: research
Status: resolved
Blocked by: none

## Question

What is the exact, minimal MASM64 program that opens a Win32 window and pumps messages — with no C runtime?

Establish as facts: the entry point and how to link without the CRT (`/entry`, `/subsystem:windows`), the x64 calling convention details that trip up hand-written asm (shadow space, 16-byte stack alignment at the call, non-volatile registers), which import libraries are needed (`kernel32.lib`, `user32.lib`, `gdi32.lib`), whether `WNDCLASSEXW` / `CreateWindowExW` / `GetMessageW` can be called directly, and how to get unwind info (`/Zi` plus `.pushreg` / `.allocstack`, or a hand-written `.pdata`) so a crashing window can actually be debugged.

Verify by assembling and linking the skeleton, not by reading alone.

Deliverable: a known-good skeleton plus the facts, written to `docs/research/masm64-win32-skeleton.md`.

## Answer

Resolved by assembling, linking and running a skeleton on this machine (Windows 11 26200,
MSVC 14.51.36231, SDK 10.0.26100.0). Findings, source, and full evidence live in
[`docs/research/masm64-win32-skeleton.md`](../../../docs/research/masm64-win32-skeleton.md);
scratch artifacts in [`docs/research/scratch/`](../../../docs/research/scratch/).

**Build that worked** (absolute-path route; a `vcvars64.bat` route also works):

```
ml64 /nologo /c /Zi /Fo skeleton.obj skeleton.asm
link /nologo /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib /debug ^
     /out:skeleton.exe skeleton.obj ^
     /libpath:"C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64" ^
     /libpath:"C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64" ^
     kernel32.lib user32.lib gdi32.lib
```

**Facts established (all verified, not recalled):**

- **Entry/no CRT**: `/subsystem:windows` defaults the entry symbol to `WinMainCRTStartup`;
  linking our object without `/entry` gives `LNK2001: unresolved external symbol
  WinMainCRTStartup`. Fix: `PUBLIC` your own label and pass `/entry:<label>`. `/nodefaultlib`
  is optional here (no CRT was pulled in either way) but enforces purity.
- **Imports**: `kernel32.lib` + `user32.lib` cover the skeleton; `gdi32.lib` links fine and is
  needed once we draw. Final `dumpbin /dependents` showed only `KERNEL32.dll` and `USER32.dll`.
- **Direct Win32**: `WNDCLASSEXW` (sizeof 80), `CreateWindowExW` (12 args) and `GetMessageW`
  are called straight through the import stubs — `EXTERN FooW:PROC`, `option casemap:none`, no
  interop layer. End-to-end verified: class `AsmSkel`, window `AsmSkeleton`, `WM_CLOSE` →
  `DefWindowProcW` → `PostQuitMessage` → `ExitProcess(0)`.
- **Unwind**: `PROC FRAME` + `.pushreg`/`.allocstack` + `.endprolog` makes MASM emit
  `.pdata`/`.xdata` automatically — **even without `/Zi`**. `/Zi` + link `/DEBUG` only add
  symbols/PDB. `dumpbin /unwindinfo` shows correct records for both functions.

**Top three gotchas:**

1. No CRT = no default entry: `/subsystem:windows` wants `WinMainCRTStartup`, so you must
   `PUBLIC` your own entry and pass `/entry:<label>`.
2. The caller owns x64 stack hygiene: 32-byte shadow space per call, `RSP` 16-byte aligned at
   the call site (`sub rsp, 28h` for a simple frame), stack args from `[rsp+20h]`, and
   nonvolatile registers (`RBX`/`RBP`/`RDI`/`RSI`/`R12`–`R15`/`XMM6`–`XMM15`) preserved.
3. Unwind info is what makes a crash debuggable; MASM gives it for free from `PROC FRAME` and
   `.allocstack`/`.pushreg`, independent of `/Zi`.

Extra traps: `mov [mem], OFFSET label` doesn't encode on x64 (use `lea`); `IDC_ARROW` must be
resolved with `LoadCursorW(MAKEINTRESOURCEW(32512))` rather than used as a raw ordinal; and
`RegisterClassExW` requires `cbSize = 80`.
