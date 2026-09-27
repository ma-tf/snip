; snip.asm
; Snipping Tool replica in x86 MASM - entry point and one-time process init.
; No C runtime, no CRT startup. Runs under WOW64 on 64-bit Windows.
;
; Build: build.cmd   (assembles every src\*.asm, links them into build\snip.exe)
; Run:   build\snip.exe
;
; This module owns the process: DPI awareness, the App context, the Shell, and
; the message pump. Capture, the overlay, the editor, and the encoder land in
; their own area modules on top of it.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

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
; WinMainASM - raw process entry. stdcall, no CRT, so we own the process exit:
; it never returns and ends in ExitProcess. The linker entry symbol is the
; decorated _WinMainASM@0; build.cmd and Crinkler both name it WinMainASM.
; ---------------------------------------------------------------------------
WinMainASM PROC
    ; Per-monitor DPI awareness v2, before any window is created. Every later
    ; ticket inherits this. A failure (already set elsewhere, say) is not fatal.
    INVOKE SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2

    ; Register ComboBoxEx32 with comctl32, so shell.asm can create it. The
    ; Shell is the only common control the app uses; a failure is not fatal,
    ; the Shell just comes up without icons.
    INVOKE InitCommonControlsEx, OFFSET icce

    ; COM + the WIC factory, for Copy and Save As (ticket 05). One apartment and
    ; one factory for the life of the process. Ticket 11 turns a failure here
    ; into a message and a clean exit; for now Copy/Save simply fail.
    INVOKE encode_init

    ; hinst = GetModuleHandleW(NULL)
    INVOKE GetModuleHandleW, 0
    mov  app.hInstance, eax

    ; shell_create(&app)
    INVOKE shell_create, OFFSET app
    mov  app.hwndShell, eax
    test eax, eax
    jz   done

    ; Message pump
msg_loop:
    INVOKE GetMessageW, OFFSET msg, 0, 0, 0
    test eax, eax
    jle  done                  ; 0 == WM_QUIT, -1 == error
    INVOKE TranslateMessage, OFFSET msg
    INVOKE DispatchMessageW, OFFSET msg
    jmp  msg_loop

done:
    INVOKE ExitProcess, 0
WinMainASM ENDP

END
