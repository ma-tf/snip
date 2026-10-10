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

    ; The system light/dark theme and the Fluent window chrome. Runs before any
    ; window exists: the palette must be ready before the window classes are
    ; registered. A failure leaves the plain light look.
    INVOKE theme_init

    ; Register ComboBoxEx32 with comctl32, so shell.asm can create it. The
    ; Shell is the only common control the app uses; a failure is not fatal,
    ; the Shell just comes up without icons.
    INVOKE InitCommonControlsEx, OFFSET icce

    ; COM + the WIC factory, for Copy and Save As (ticket 05). One apartment and
    ; one factory for the life of the process. Ticket 11: this is the one
    ; unrecoverable startup failure - report it and exit cleanly, before any
    ; window exists.
    INVOKE encode_init
    test eax, eax
    jz   startup_fail

    ; GDI+, for the Editor's antialiased Pen and Highlighter (ticket 06). A
    ; failure just leaves the annotation buttons inert, like WIC above.
    INVOKE ink_init

    ; hinst = GetModuleHandleW(NULL)
    INVOKE GetModuleHandleW, 0
    mov  app.hInstance, eax

    ; shell_create(&app)
    INVOKE shell_create, OFFSET app
    mov  app.hwndShell, eax
    test eax, eax
    jz   shell_fail

    ; Accelerator tables for the keyboard map (ticket 12). A failure is not
    ; fatal - the shortcuts simply do not fire - so the return is ignored, like
    ; InitCommonControlsEx above. keys_free destroys them on the way out.
    INVOKE keys_init

    ; Message pump
msg_loop:
    INVOKE GetMessageW, OFFSET msg, 0, 0, 0
    test eax, eax
    jle  done                  ; 0 == WM_QUIT, -1 == error

    ; The keyboard map gets first refusal: an accelerator or IsDialogMessageW
    ; consumes the message (keys_translate returns 1), so it never reaches
    ; TranslateMessage/DispatchMessageW. See docs/keyboard.md.
    INVOKE keys_translate, OFFSET app, OFFSET msg
    test eax, eax
    jnz  msg_loop

    INVOKE TranslateMessage, OFFSET msg
    INVOKE DispatchMessageW, OFFSET msg
    jmp  msg_loop

; encode_init failed: no window was ever created, so the box has no owner and
; there is nothing left to do but leave. A nonzero exit code records the cause.
startup_fail:
    INVOKE err_show, 0, ERR_STARTUP
    INVOKE ExitProcess, 1

; shell_create failed: an unrecoverable startup failure like the one above.
shell_fail:
    INVOKE err_show, 0, ERR_SHELL
    INVOKE ExitProcess, 1

done:
    INVOKE keys_free
    INVOKE ExitProcess, 0
WinMainASM ENDP

END
