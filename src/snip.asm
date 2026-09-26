; snip.asm
; Snipping Tool replica in x64 MASM - entry point and one-time process init.
; No C runtime, no CRT startup.
;
; Build: build.cmd   (assembles every src\*.asm, links them into build\snip.exe)
; Run:   build\snip.exe
;
; This module owns the process: DPI awareness, the App context, the Shell, and
; the message pump. Capture, the overlay, the editor, and the encoder land in
; their own area modules on top of it.

option casemap:none

include snip.inc
include win32.inc

; The linker needs this label for /entry:.
PUBLIC WinMainASM

; ---------------------------------------------------------------------------
; Read-only data. .const (.rdata) costs file bytes only for what it holds.
; ---------------------------------------------------------------------------
.const
; The ComboBoxEx class registration request, used once at process init.
icce INITCOMMONCONTROLSEX <SIZEOF INITCOMMONCONTROLSEX, ICC_USEREX_CLASSES>

; ---------------------------------------------------------------------------
; Mutable data. Zero-initialised, so .data? (.bss): no file bytes, the loader
; zero-fills it. See docs/architecture.md.
; ---------------------------------------------------------------------------
.data?
app  App <>
msg  MSG <>

; ---------------------------------------------------------------------------
.code

; ---------------------------------------------------------------------------
; WinMainASM - raw process entry. The OS calls it with RSP == 8 (mod 16); there
; is no CRT, so we own shadow space, alignment, and the exit ourselves.
; ---------------------------------------------------------------------------
WinMainASM PROC FRAME
    sub  rsp, 88h            ; 0x20 shadow + 0x60 for CreateWindowExW's stack args
    .allocstack 88h
    .endprolog

    ; Per-monitor DPI awareness v2, before any window is created. Every later
    ; ticket inherits this. A failure (already set by a manifest, say) is not
    ; fatal here.
    mov  rcx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    call SetProcessDpiAwarenessContext

    ; Register ComboBoxEx32 with comctl32, so shell.asm can create it. The
    ; Shell is the only common control the app uses; a failure is not fatal,
    ; the Shell just comes up without icons.
    lea  rcx, icce
    call InitCommonControlsEx

    ; hinst = GetModuleHandleW(NULL)
    xor  ecx, ecx
    call GetModuleHandleW
    mov  app.hInstance, rax

    ; shell_create(&app)
    lea  rcx, app
    call shell_create
    mov  app.hwndShell, rax
    test rax, rax
    jz   done

    ; Message pump
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
