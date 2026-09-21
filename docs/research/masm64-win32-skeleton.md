# Minimal MASM64 Win32 GUI skeleton (no CRT)

Ticket: [`.scratch/snipping-tool-asm/issues/01-masm64-win32-skeleton.md`](../../.scratch/snipping-tool-asm/issues/01-masm64-win32-skeleton.md)
Researched: 2026-09-21. Toolchain: VS 18 Community, MSVC 14.51.36231 (`ml64` 14.51), Windows SDK 10.0.26100.0.

**Everything below was assembled, linked and run on this machine**, not recalled. The scratch
artifacts live in [`docs/research/scratch/`](scratch/): `skeleton.asm`, `build.ps1`, `skeleton.exe`.

---

## Verdict

A pure-MASM64 Win32 window with no C runtime is straightforward, but it requires four things
that aren't obvious when you come from `cl.exe`:

1. **You must supply your own entry point** and name it to the linker. `/subsystem:windows`
   defaults the entry symbol to `WinMainCRTStartup` (the CRT's), so a CRT-less link fails with
   `LNK2001: unresolved external symbol WinMainCRTStartup` until you pass `/entry:<yourlabel>`.
2. **The stack is the caller's problem** on x64: 32 bytes of shadow space for every call, and
   `RSP` 16-byte aligned at the call site. `sub rsp, 28h` after entry is the canonical fix.
3. **Unwind metadata is not optional in practice** if you want to debug a crash, but it is easy:
   `PROC FRAME` + `.allocstack`/`.pushreg` + `.endprolog`, and MASM emits `.pdata`/`.xdata`
   automatically. `/Zi` only adds symbols.
4. **Call Win32 directly**: declare `EXTERN FooW:PROC`, keep `option casemap:none`, link
   `kernel32.lib user32.lib gdi32.lib`. No CRT, no COM, no thunks needed.

---

## Build command that worked

Both routes produced the same working `skeleton.exe` (pe32+, imports only `KERNEL32.dll`
and `USER32.dll`).

### Route A — via `vcvars64.bat` (canonical, puts `ml64`/`link`/libs on PATH)

```bat
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
ml64 /nologo /c /Zi /Fo skeleton.obj skeleton.asm
link /nologo /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib /debug ^
     /out:skeleton.exe skeleton.obj kernel32.lib user32.lib gdi32.lib
```

Verified with `cmd /c "call vcvars64.bat && ml64 ... && link ..."` → `VCVARS_BUILD_OK`.

### Route B — absolute paths, no PATH dependency (safer for a build script)

```powershell
$msvc  = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64'
$umLib = 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64'
$ucrt  = 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64'

& "$msvc\ml64.exe" /nologo /c /Zi /Fo skeleton.obj skeleton.asm
& "$msvc\link.exe" /nologo /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib `
    /debug /out:skeleton.exe skeleton.obj `
    /libpath:$umLib /libpath:$ucrt `
    kernel32.lib user32.lib gdi32.lib
```

See [`scratch/build.ps1`](scratch/build.ps1) for the runnable version.

`ml64` options that matter: `/c` (assemble only), `/Zi` (CodeView symbols), `/Fo` (output
object). MASM's `/Zi` is *not* what produces unwind info — see [Unwind info](#unwind-info).

---

## Entry point and linking without the CRT

**Fact:** `/SUBSYSTEM:WINDOWS` selects `WinMainCRTStartup` as the default entry symbol; the
`/ENTRY` option overrides it. The docs table lists `WinMainCRTStartup` (or `wWinMainCRTStartup`)
as the default for `/SUBSYSTEM:WINDOWS` ([/ENTRY](https://learn.microsoft.com/en-us/cpp/build/reference/entry-entry-point-symbol?view=msvc-170),
[/SUBSYSTEM](https://learn.microsoft.com/en-us/cpp/build/reference/subsystem-specify-subsystem?view=msvc-170)).

**Verified:** linking the skeleton without `/entry` fails exactly as the docs imply:

```
LINK : error LNK2001: unresolved external symbol WinMainCRTStartup
... fatal error LNK1120: 1 unresolved externals
```

When you use `/NODEFAULTLIB` to build without the CRT, you may also have to use `/ENTRY`
([/NODEFAULTLIB docs](https://learn.microsoft.com/en-us/cpp/build/reference/nodefaultlib-ignore-libraries?view=msvc-170)).
So the recipe is:

- Define a label, e.g. `WinMainASM`, and make it visible: `PUBLIC WinMainASM`.
- Link with `/entry:WinMainASM /subsystem:windows /machine:x64`.
- The OS calls the raw entry directly. There is no CRT, so there is no `argc`/`argv`/`WinMain`
  hand-off and no CRT initialization. Do your own setup and end with `ExitProcess` (never
  `ret`, which would return into the loader's thread-startup stub with no CRT cleanup).
- `/nodefaultlib` is **not strictly required**: linking without it still pulled in no CRT and
  produced the same `KERNEL32.dll`/`USER32.dll`-only import table (verified). Keep it anyway —
  it makes "no CRT" an enforced invariant rather than an accident.
- None of the object sections carried a `.drectve` requesting a CRT (`dumpbin /directives`
  showed only `.debug$S`/`.debug$T`, `.pdata`, `.xdata`, `.text$mn`, `.data`).

Note: `/ENTRY` docs say the entry function "must be defined to use the `__stdcall` calling
convention". On x64 there is only one calling convention, so this is a no-op for MASM64; it does
not change the picture.

---

## x64 calling-convention pitfalls for hand-written asm

Source: [x64 calling convention](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170),
[x64 stack usage](https://learn.microsoft.com/en-us/cpp/build/stack-usage?view=msvc-170),
[x64 ABI conventions](https://learn.microsoft.com/en-us/cpp/build/x64-software-conventions?view=msvc-170).

### 1. Argument registers and stack arguments

- First four integer/pointer args: `RCX`, `RDX`, `R8`, `R9` (left to right).
- 5th and later args go on the stack **starting at `[rsp+20h]`**, one 8-byte slot each,
  increasing (`[rsp+28h]` = 6th, `[rsp+30h]` = 7th, ...). The first 32 bytes above `RSP`
  (`[rsp+00h]`–`[rsp+1Fh]`) are the shadow/home area, *not* stack arguments.
- Return value: integer/pointer in `RAX`; floats/vectors in `XMM0`.
- `CreateWindowExW` has **12 parameters** — the only place in the skeleton where you must lay
  out stack args by hand. It worked first try with args 5–12 written to
  `[rsp+20h]..[rsp+58h]` before the call.

### 2. Shadow space

The caller must always reserve space for four register parameters (32 bytes) before a call,
even if the callee takes fewer, because the callee may home its register args there. The docs:
"The caller must always allocate sufficient space to store four register parameters, even if
the callee doesn't take that many parameters." That region is owned by the callee across the
call — do not stash your own state there across a call.

### 3. 16-byte stack alignment at the call site

- "The stack pointer must remain 16-byte aligned in any region of code that isn't part of an
  epilog or prolog" ([x64 calling convention](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170)).
- On entry to a function `RSP ≡ 8 (mod 16)` because the `call` pushed an 8-byte return address.
- Therefore, before you `call` anything, `RSP ≡ 0 (mod 16)`. The idiom for a frame with
  1–4-arg calls is **`sub rsp, 28h`** (8 bytes to realign + 32 bytes shadow). For a call with
  `n` stack arguments, allocate `28h + 8n` bytes and keep the total a multiple of 16. In the
  skeleton the entry allocates `sub rsp, 88h` up front (0x20 shadow + 0x60 for eight
  `CreateWindowExW` stack args = 0x88, which is 16-byte aligned).
- Leaf functions (no calls, no nonvolatile saves, no RSP change) may leave the stack unaligned;
  never do this in a frame function.

### 4. Non-volatile (callee-saved) registers

Must be preserved: `RBX`, `RBP`, `RDI`, `RSI`, `RSP`, `R12`–`R15`, and `XMM6`–`XMM15`.
`RAX`, `RCX`, `RDX`, `R8`–`R11`, `XMM0`–`XMM5` are volatile. If you use a nonvolatile register,
push it in the prolog and pair it with `.pushreg` so the unwind info knows where you saved it;
restore it in the epilog. The skeleton avoids nonvolatiles entirely, so `rsp` is the only
callee-saved register it touches (via `sub`/`add`).

Also expected by the ABI: the direction flag is clear on entry and must be clear when calling
into the CRT or system.

### 5. MASM-specific encoding traps

- `mov qword ptr [mem], OFFSET label` is **not encodable** on x64 (`mov m64, imm64` does not
  exist). Use `lea rax, label` then `mov [mem], rax`. The skeleton does this for `lpfnWndProc`
  and `lpszClassName`.
- `EXTERN` names must match exactly. Put `option casemap:none` at the top so `GetMessageW`
  doesn't become `getmessagew` and fail to resolve.
- In unreferenced-to-by-address data (like the `WNDCLASSEXW`), MASM's `SIZEOF` operator works
  for `cbSize`: `mov wc.cbSize, SIZEOF WNDCLASSEXW`.

---

## Import libraries required

| Library | Provides | Needed by skeleton? |
| --- | --- | --- |
| `kernel32.lib` | `GetModuleHandleW`, `ExitProcess` | yes |
| `user32.lib` | `LoadCursorW`, `RegisterClassExW`, `CreateWindowExW`, `ShowWindow`, `UpdateWindow`, `GetMessageW`, `TranslateMessage`, `DispatchMessageW`, `DefWindowProcW`, `PostQuitMessage` | yes |
| `gdi32.lib` | GDI drawing (`BeginPaint`, `FillRect`, bitmaps, ...) | not yet; add as soon as we draw |

Under `C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64\` (x64). Pass them on
the link line; no `includelib` directive is required. The SDK also ships a `ucrt\x64` directory,
but nothing in the skeleton references it (only needed if a CRT import sneaks in, which it
must not).

**Verified:** `dumpbin /dependents skeleton.exe` listed exactly `KERNEL32.dll` and `USER32.dll`.
`dumpbin /imports` resolved `ExitProcess` from KERNEL32 and `CreateWindowExW`, `GetMessageW`,
`DefWindowProcW`, `PostQuitMessage` from USER32. Hard-coding the system libraries is not needed
at this stage.

Where the libraries come from: MSDN lists `User32.lib` as the library for
[`RegisterClassExW`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerclassexw)
and its kin.

---

## Calling `WNDCLASSEXW` / `CreateWindowExW` / `GetMessageW` directly

Yes — all three call straight into the Win32 import stubs with no interop layer.

Declarations:

```asm
option casemap:none
EXTERN RegisterClassExW:PROC
EXTERN CreateWindowExW:PROC
EXTERN GetMessageW:PROC
; ...
```

Structure layouts must be declared in assembly. The x64 `WNDCLASSEXW` is 80 bytes
(`cbSize` is a `DWORD`, then a `DWORD` `style`, then `QWORD` pointers; two `DWORD` tail
fields are 8-byte aligned). The `MSG` struct is 48 bytes in the modern SDK (it includes
`lPrivate` when `WINVER >= 0x0601`). Exact layouts used are in the source below.

Practical Win32 details that cost time if missed:

- **Use the `W` (Unicode) entry points** — `RegisterClassExW`, `CreateWindowExW`,
  `GetMessageW`, `DefWindowProcW`. Create the class with `RegisterClassExW` so the window is a
  Unicode window, matching `CreateWindowExW`'s wide-string class/title.
- **`cbSize` is mandatory**: `wc.cbSize = sizeof(WNDCLASSEXW)` (80). `RegisterClassExW` fails
  otherwise.
- **`hCursor` is an `HCURSOR`, not a resource ID.** `IDC_ARROW` is the ordinal `32512`; on x64
  you must resolve it: `LoadCursorW(NULL, MAKEINTRESOURCEW(32512))`. Passing `32512` directly
  is a type error.
- **`hbrBackground` may be a system-color pseudo-brush**: the docs allow
  `(HBRUSH)(COLOR_WINDOW + 1)`, i.e. the ordinal `6`. Handy to get a white, erased background
  without creating a brush.
- `lpfnWndProc` must be the actual function address; `DefWindowProcW` handles `WM_CLOSE`,
  which posts `WM_DESTROY`, which our proc turns into `PostQuitMessage(0)`.
- `GetMessageW` returns `BOOL`: `0` = `WM_QUIT`, `-1` = error; both end the loop
  (`test eax, eax; jle done`). It returns `1` to keep going.

**Verified end-to-end:** the running process registered class `AsmSkel` and created a
top-level window titled `AsmSkeleton` (confirmed by `EnumWindows` + `GetClassNameW` /
`GetWindowTextW` in another process). Posting `WM_CLOSE` to it drove
`DefWindowProcW → WM_DESTROY → PostQuitMessage → GetMessageW == 0 → ExitProcess(0)`; the
process exited with code 0.

---

## Unwind info

**Fact:** every function that allocates stack space, calls another function, saves nonvolatile
registers, or uses exception handling must have a prolog described in the unwind data, and the
data is stored as `.pdata` referencing `.xdata`
([x64 prolog and epilog](https://learn.microsoft.com/en-us/cpp/build/prolog-and-epilog?view=msvc-170),
[x64 exception handling](https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64?view=msvc-170)).

**Fact:** MASM's `PROC FRAME` plus the pseudo-ops generate that data. `PROC FRAME` "causes MASM
to generate a function table entry in `.pdata` and unwind information in `.xdata`"; `.PUSHREG`
generates `UWOP_PUSH_NONVOL`; `.ALLOCSTACK` generates `UWOP_ALLOC_SMALL`/`UWOP_ALLOC_LARGE`.
The directives must lie between the `PROC FRAME` declaration and `.ENDPROLOG`. The **directive
follows the instruction it describes in Unwind v1** (the default; v3, behind
`ml64 /unwindv3`, flips that order).

**Verified — and the important nuance:** MASM emitted `.pdata` and `.xdata` **even when
assembling without `/Zi`**. `/Zi` is only for CodeView debug symbols; it does not control
unwind generation. Assemble with `/Zi` and link with `/DEBUG` to *also* get a `.pdb` with
symbols. `dumpbin /unwindinfo skeleton.exe` showed both functions with correct records:

```
Function Table (2)
  Begin    End      Info     Function Name
  00001020 00001041 000032C0 WndProc
    Size of prologue: 0x04   Count of codes: 1
    Unwind codes: 04: ALLOC_SMALL, size=0x28
  00001041 0000119B 000032C8 WinMainASM
    Size of prologue: 0x07   Count of codes: 2
    Unwind codes: 07: ALLOC_LARGE, size=0x88
```

So the recipe for a debuggable crashing window is:

1. Every non-leaf function is `PROC FRAME` with a real prolog, and ends with a matching epilog.
2. Pair each `push <nonvol>` / `sub rsp, N` with `.pushreg` / `.allocstack` (or use
   `.savereg`/`.savexmm128` for `mov`-style saves), then `.endprolog`.
3. Assemble `/Zi`, link `/DEBUG:FULL` for symbols/PDB.
4. Leaf functions need none of this and can omit `FRAME`.

**Hand-written `.pdata`:** possible but unnecessary. The structures are `RUNTIME_FUNCTION`
(`DWORD`-aligned `{BeginAddress, EndAddress, UnwindData}`, image-relative RVA) and
`UNWIND_INFO` (version/flags/prolog size/code count/frame register, then `UNWIND_CODE` slots).
You would only do this if you were emitting raw bytes without MASM's frame machinery. With
`PROC FRAME` it's free.

---

## The known-good skeleton

Full source: [`docs/research/scratch/skeleton.asm`](scratch/skeleton.asm). Reproduced here so
the doc is self-contained.

```asm
; skeleton.asm - minimal MASM64 Win32 GUI skeleton, no CRT.
option casemap:none

EXTERN GetModuleHandleW:PROC
EXTERN LoadCursorW:PROC
EXTERN RegisterClassExW:PROC
EXTERN CreateWindowExW:PROC
EXTERN ShowWindow:PROC
EXTERN UpdateWindow:PROC
EXTERN GetMessageW:PROC
EXTERN TranslateMessage:PROC
EXTERN DispatchMessageW:PROC
EXTERN DefWindowProcW:PROC
EXTERN PostQuitMessage:PROC
EXTERN ExitProcess:PROC

PUBLIC WinMainASM            ; linker needs this for /entry:

WS_OVERLAPPEDWINDOW EQU 000CF0000h
CW_USEDEFAULT       EQU 80000000h
SW_SHOWDEFAULT      EQU 10
CS_HREDRAW          EQU 0002h
CS_VREDRAW          EQU 0001h
IDC_ARROW           EQU 7F00h
WM_DESTROY          EQU 0002h
COLOR_WINDOW_1      EQU 6            ; (COLOR_WINDOW + 1), a valid pseudo-HBRUSH

WNDCLASSEXW STRUCT 8
    cbSize          DWORD   ?
    style           DWORD   ?
    lpfnWndProc     QWORD   ?
    cbClsExtra      DWORD   ?
    cbWndExtra      DWORD   ?
    hInstance       QWORD   ?
    hIcon           QWORD   ?
    hCursor         QWORD   ?
    hbrBackground   QWORD   ?
    lpszMenuName    QWORD   ?
    lpszClassName   QWORD   ?
    hIconSm         QWORD   ?
WNDCLASSEXW ENDS             ; sizeof == 80

POINT STRUCT 4
    x DWORD ?
    y DWORD ?
POINT ENDS

MSG STRUCT 8
    hwnd     QWORD ?
    message  DWORD ?
    _pad0    DWORD ?
    wParam   QWORD ?
    lParam   QWORD ?
    time     DWORD ?
    pt       POINT <>
    lPrivate DWORD ?
MSG ENDS                     ; sizeof == 48

.data
class_name  DW 'A','s','m','S','k','e','l',0
window_name DW 'A','s','m','S','k','e','l','e','t','o','n',0
wc          WNDCLASSEXW <>
msg         MSG <>
hinst       QWORD ?
hwnd        QWORD ?

.code

WndProc PROC FRAME
    sub  rsp, 28h            ; 8 align + 32 shadow
    .allocstack 28h
    .endprolog
    cmp  edx, WM_DESTROY
    je   wm_destroy
    call DefWindowProcW       ; rcx/rdx/r8/r9 already hold the args
    add  rsp, 28h
    ret
wm_destroy:
    xor  ecx, ecx
    call PostQuitMessage
    xor  eax, eax
    add  rsp, 28h
    ret
WndProc ENDP

WinMainASM PROC FRAME
    sub  rsp, 88h            ; 0x20 shadow + 0x60 for 8 stack args
    .allocstack 88h
    .endprolog

    xor  ecx, ecx
    call GetModuleHandleW
    mov  hinst, rax
    mov  wc.hInstance, rax

    mov  wc.cbSize, SIZEOF WNDCLASSEXW
    mov  wc.style, CS_HREDRAW OR CS_VREDRAW
    lea  rax, WndProc
    mov  wc.lpfnWndProc, rax
    mov  wc.cbClsExtra, 0
    mov  wc.cbWndExtra, 0
    mov  wc.hbrBackground, COLOR_WINDOW_1

    xor  ecx, ecx
    mov  edx, IDC_ARROW
    call LoadCursorW
    mov  wc.hCursor, rax

    lea  rdx, class_name
    mov  wc.lpszClassName, rdx

    lea  rcx, wc
    call RegisterClassExW
    test eax, eax
    jz   done

    mov  qword ptr [rsp+20h], CW_USEDEFAULT       ; x
    mov  qword ptr [rsp+28h], CW_USEDEFAULT       ; y
    mov  qword ptr [rsp+30h], CW_USEDEFAULT       ; nWidth
    mov  qword ptr [rsp+38h], CW_USEDEFAULT       ; nHeight
    mov  qword ptr [rsp+40h], 0                   ; hWndParent
    mov  qword ptr [rsp+48h], 0                   ; hMenu
    mov  rax, hinst
    mov  qword ptr [rsp+50h], rax                 ; hInstance
    mov  qword ptr [rsp+58h], 0                   ; lpParam
    xor  ecx, ecx                                 ; exStyle
    lea  rdx, class_name
    lea  r8, window_name
    mov  r9d, WS_OVERLAPPEDWINDOW
    call CreateWindowExW
    mov  hwnd, rax
    test rax, rax
    jz   done

    mov  rcx, hwnd
    mov  edx, SW_SHOWDEFAULT
    call ShowWindow
    mov  rcx, hwnd
    call UpdateWindow

msg_loop:
    lea  rcx, msg
    xor  edx, edx
    xor  r8d, r8d
    xor  r9d, r9d
    call GetMessageW
    test eax, eax
    jle  done                  ; 0 == WM_QUIT, -1 == error
    lea  rcx, msg
    call TranslateMessage
    lea  rcx, msg
    call DispatchMessageW
    jmp  msg_loop

done:
    xor  ecx, ecx
    call ExitProcess
WinMainASM ENDP

END
```

---

## Verification evidence (all run on this machine)

| Check | Command | Result |
| --- | --- | --- |
| Assembled | `ml64 /nologo /c /Zi /Fo skeleton.obj skeleton.asm` | exit 0 |
| Linked (no CRT) | `link /machine:x64 /subsystem:windows /entry:WinMainASM /nodefaultlib /debug ...` | `built skeleton.exe` |
| Default-entry failure | link same object without `/entry` | `LNK2001: unresolved external symbol WinMainCRTStartup` |
| Unwind info | `dumpbin /unwindinfo skeleton.exe` | 2 `RUNTIME_FUNCTION` entries, `ALLOC_SMALL 0x28`, `ALLOC_LARGE 0x88` |
| Unwind without `/Zi` | `ml64 /c` then `dumpbin /headers noZi.obj` | `.pdata` and `.xdata` present |
| Dependencies | `dumpbin /dependents skeleton.exe` | only `KERNEL32.dll`, `USER32.dll` |
| No CRT directive | `dumpbin /directives skeleton.obj` | no `.drectve`; no CRT |
| Runs | `Start-Process skeleton.exe` | alive after 2 s |
| Window exists | `EnumWindows` + `GetClassNameW` + `GetWindowTextW` | class `AsmSkel`, title `AsmSkeleton` |
| Clean message path | post `WM_CLOSE` | `DefWindowProcW` → `PostQuitMessage` → `ExitProcess(0)`, exit code 0 |
| PDB | link `/debug` | `skeleton.pdb` produced (127 KB) with `/Zi` |
| vcvars route | `cmd /c "call vcvars64.bat && ml64 ... && link ..."` | `VCVARS_BUILD_OK` |

---

## Top three gotchas

1. **No CRT means no default entry.** `/subsystem:windows` wants `WinMainCRTStartup`; your
   label doesn't match, so you get `LNK2001` until you `PUBLIC` your entry and pass
   `/entry:<label>`. Add `/nodefaultlib` to keep the no-CRT invariant enforced.
2. **The caller owns shadow space and alignment on x64.** Slack of "it just works" from
   compiled code disappears: reserve 32 bytes per call, and make `RSP` 16-byte aligned before
   every `call` (`sub rsp, 28h` in a simple frame). Stack arguments (5th onward) start at
   `[rsp+20h]`. Nonvolatile registers (`RBX`, `RBP`, `RDI`, `RSI`, `R12`–`R15`, `XMM6`–`XMM15`)
   must be saved if used.
3. **Unwind info is what makes a crash debuggable — and MASM gives it away for free.** Use
   `PROC FRAME` + `.pushreg`/`.allocstack`/`.savereg` + `.endprolog`; `.pdata`/`.xdata` are
   emitted regardless of `/Zi`. `/Zi` + link `/DEBUG` only add the symbols/PDB. Assemble your
   object without `/Zi` and you still get unwind; debug it without unwind and a crash is a
   mystery.

Bonus traps worth internalizing: `mov [mem], OFFSET label` doesn't encode on x64 (use `lea`);
`IDC_ARROW` must go through `LoadCursorW(MAKEINTRESOURCEW(32512))`; and `RegisterClassExW`
needs `cbSize = 80`.

---

## Citations

- x64 calling convention — https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170
- x64 stack usage — https://learn.microsoft.com/en-us/cpp/build/stack-usage?view=msvc-170
- x64 ABI conventions (register volatility) — https://learn.microsoft.com/en-us/cpp/build/x64-software-conventions?view=msvc-170
- x64 prolog and epilog — https://learn.microsoft.com/en-us/cpp/build/prolog-and-epilog?view=msvc-170
- x64 exception handling / `.pdata` / `RUNTIME_FUNCTION` / MASM frame pseudo-ops — https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64?view=msvc-170
- `.ALLOCSTACK` — https://learn.microsoft.com/en-us/cpp/assembler/masm/dot-allocstack?view=msvc-170
- `.PUSHREG` — https://learn.microsoft.com/en-us/cpp/assembler/masm/dot-pushreg?view=msvc-170
- `/ENTRY` — https://learn.microsoft.com/en-us/cpp/build/reference/entry-entry-point-symbol?view=msvc-170
- `/SUBSYSTEM` — https://learn.microsoft.com/en-us/cpp/build/reference/subsystem-specify-subsystem?view=msvc-170
- `/NODEFAULTLIB` — https://learn.microsoft.com/en-us/cpp/build/reference/nodefaultlib-ignore-libraries?view=msvc-170
- `RegisterClassExW` (User32.lib, WNDCLASSEX) — https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerclassexw
