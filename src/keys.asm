; keys.asm
; The keyboard map: the accelerator tables Windows translates for us, and the
; routing that decides which window a shortcut belongs to.
;
; Six of the shortcuts are real Win32 accelerators. The Shell has Alt+N (New),
; Alt+M (mode), and Alt+D (Delay); the Editor has Alt+N (New), Ctrl+C (Copy),
; Ctrl+S (Save As), and Ctrl+Z (Undo). The Overlay's Escape and right-click are
; not accelerators - select.asm reads them itself - and neither window binds
; Enter, so Tab to a control and Space activates it.
;
; TranslateAcceleratorW turns a matching key into a WM_COMMAND carrying the
; accelerator's cmd (an IDA_* id). That is why routing is by capability, not by
; focus: the Editor's table is tried first so Ctrl+C/S/Z and Alt+N fire while the
; Shell has focus, and the Shell's table second so Alt+M and Alt+D still reach it.
; A hidden window is skipped, so no shortcut fires while the Overlay is up.
; IsDialogMessageW then supplies Tab traversal and combo arrows, but only for the
; window the message actually targets - select.asm owns the Overlay's keys.
;
; This module owns no actions. A matched key becomes a WM_COMMAND that
; shell.asm or editor.asm handles. See docs/keyboard.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC keys_init
PUBLIC keys_free
PUBLIC keys_translate

; ---------------------------------------------------------------------------
; The tables. Read-only, so they live in .const (.rdata). Each ACCEL is
; `{ fVirt, pad, key, cmd }`; the pad is part of the struct so the layout is the
; API's 6 bytes rather than MASM's packed 5 (see win32.inc). The count is derived
; from the labels, so adding a row cannot leave the length behind.
; ---------------------------------------------------------------------------
.const
accel_shell LABEL ACCEL
    ACCEL <FVIRTKEY OR FALT, 0, 'N', IDA_NEW>
    ACCEL <FVIRTKEY OR FALT, 0, 'M', IDA_MODE>
    ACCEL <FVIRTKEY OR FALT, 0, 'D', IDA_DELAY>
accel_shell_n EQU ($ - accel_shell) / SIZEOF ACCEL

accel_editor LABEL ACCEL
    ACCEL <FVIRTKEY OR FALT,     0, 'N', IDA_NEW>
    ACCEL <FVIRTKEY OR FCONTROL, 0, 'C', IDA_COPY>
    ACCEL <FVIRTKEY OR FCONTROL, 0, 'S', IDA_SAVE>
    ACCEL <FVIRTKEY OR FCONTROL, 0, 'Z', IDA_UNDO>
accel_editor_n EQU ($ - accel_editor) / SIZEOF ACCEL

.data?
accel_shell_h  DWORD ?          ; HACCEL, built by keys_init, destroyed by keys_free
accel_editor_h DWORD ?

; ---------------------------------------------------------------------------
.code

; ---------------------------------------------------------------------------
; keys_init() -> BOOL in eax, nonzero if both tables were built.
; A failure is not fatal: TranslateAcceleratorW is handed a null table and simply
; finds no shortcut, exactly as the Shell comes up without icons if
; InitCommonControlsEx fails. The caller ignores the return.
; ---------------------------------------------------------------------------
keys_init PROC
    INVOKE CreateAcceleratorTableW, OFFSET accel_shell, accel_shell_n
    mov  accel_shell_h, eax
    INVOKE CreateAcceleratorTableW, OFFSET accel_editor, accel_editor_n
    mov  accel_editor_h, eax

    mov  eax, accel_shell_h
    and  eax, accel_editor_h
    test eax, eax
    jz   ki_done
    mov  eax, 1
    ret
ki_done:
    xor  eax, eax
    ret
keys_init ENDP

; ---------------------------------------------------------------------------
; keys_free() - destroy the tables before the process exits. Null-safe, because
; the entry reaches it even when no window (and so no table) was ever made.
; ---------------------------------------------------------------------------
keys_free PROC
    mov  eax, accel_shell_h
    test eax, eax
    jz   kf_editor
    INVOKE DestroyAcceleratorTable, eax
    mov  accel_shell_h, 0

kf_editor:
    mov  eax, accel_editor_h
    test eax, eax
    jz   kf_done
    INVOKE DestroyAcceleratorTable, eax
    mov  accel_editor_h, 0
kf_done:
    ret
keys_free ENDP

; ---------------------------------------------------------------------------
; keys_translate(App *app, MSG *msg) -> BOOL. 1 if the message was consumed (the
; pump must not TranslateMessage/DispatchMessageW it), 0 otherwise.
; ---------------------------------------------------------------------------
keys_translate PROC USES esi app:DWORD, msg:DWORD
    LOCAL hwnd:DWORD

    mov  esi, app

    ; --- accelerators, by capability --------------------------------------
    ; The Editor owns Copy/Save/Undo and shares New; trying it first is what
    ; makes those work while the Shell has focus. A hidden window is skipped:
    ; during a Snipping session both are hidden, so nothing fires.
    mov  eax, [esi].App.hwndEditor
    test eax, eax
    jz   kt_shell
    mov  hwnd, eax
    INVOKE IsWindowVisible, hwnd
    test eax, eax
    jz   kt_shell
    INVOKE TranslateAcceleratorW, hwnd, accel_editor_h, msg
    test eax, eax
    jnz  kt_yes

kt_shell:
    mov  eax, [esi].App.hwndShell
    test eax, eax
    jz   kt_dialog
    mov  hwnd, eax
    INVOKE IsWindowVisible, hwnd
    test eax, eax
    jz   kt_dialog
    INVOKE TranslateAcceleratorW, hwnd, accel_shell_h, msg
    test eax, eax
    jnz  kt_yes

    ; --- Tab traversal and combo arrows -----------------------------------
    ; IsDialogMessageW must be handed the window the message belongs to, so it
    ; is picked from the target's root, never by capability. The Overlay is not
    ; traversed here.
kt_dialog:
    mov  eax, msg
    mov  eax, [eax].MSG.hwnd
    INVOKE GetAncestor, eax, GA_ROOT
    mov  hwnd, eax
    test eax, eax
    jz   kt_no
    cmp  eax, [esi].App.hwndShell
    je   kt_dialog_call
    cmp  eax, [esi].App.hwndEditor
    jne  kt_no
kt_dialog_call:
    INVOKE IsDialogMessageW, hwnd, msg
    test eax, eax
    jnz  kt_yes

kt_no:
    xor  eax, eax
    ret
kt_yes:
    mov  eax, 1
    ret
keys_translate ENDP

END
