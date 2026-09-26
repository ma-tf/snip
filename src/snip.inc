; snip.inc - our module interface: context structs, shared constants, and the
; public labels the area modules call each other through.
;
; This is the seam between our own modules. It is platform-free on purpose (MASM
; primitives only) so a module's contract can be read without Win32 in your
; head. Win32 imports, SDK constants, and SDK structs live in win32.inc.
;
; Two includes on purpose: each file has one reason to change. This one changes
; when we change an interface between our modules; win32.inc changes when we
; bind a new API. See docs/architecture.md.

IFNDEF SNIP_INC
SNIP_INC EQU 1

; ---------------------------------------------------------------------------
; Shell control identifiers
; ---------------------------------------------------------------------------
IDC_NEW             EQU 1001
IDC_MODE            EQU 1002
IDC_DELAY           EQU 1003

; ---------------------------------------------------------------------------
; App - process-wide context. One instance lives in snip.asm's data and is
; handed to each window by pointer; a WndProc recovers it from GWLP_USERDATA.
; ---------------------------------------------------------------------------
App STRUCT 8
    hInstance   QWORD ?     ; process HINSTANCE, for window creation
    hwndShell   QWORD ?     ; the Shell window
    mode        DWORD ?     ; the mode drop-down's current index
    delay       DWORD ?     ; the delay drop-down's current index
App ENDS

; ---------------------------------------------------------------------------
; Public labels
; ---------------------------------------------------------------------------
shell_create PROTO          ; HWND shell_create(App *app) - see shell.asm

ENDIF
