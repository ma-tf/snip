; select.asm
; The Selection state machine and the Snipping session lifecycle.
;
; A session runs from a New click to the Selection being completed or
; cancelled. This module owns that lifecycle: it raises the Overlay, tracks the
; drag, and puts the Shell back afterwards. It is the only module that knows a
; session is in flight.
;
; Ticket 02 is rectangular only. The free-form, window, and full-screen
; gestures add per-mode mouse-down paths here when tickets 07, 08, and 09 land;
; the shape is already right for that (each mode gets its own branch rather
; than falling through to the drag handler - see the prototype's bug 2).
;
; The live state is module-private: a session is a singleton, like the Shell.
; When the Selection completes, select_finish drives the handoff: the Selection
; is cropped into a Snip (dib.asm) and the Editor opens (editor.asm).
;
; See docs/select.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC select_begin
PUBLIC select_cancel
PUBLIC select_finish
PUBLIC sel_wndproc

; Forward declarations so INVOKE reaches callees defined later in the file.
sel_ldown    PROTO STDCALL :DWORD
sel_mmove    PROTO STDCALL :DWORD
sel_lup      PROTO STDCALL
sel_restore  PROTO STDCALL
sel_repaint  PROTO STDCALL

; ---------------------------------------------------------------------------
; Session state. Zero-initialised, so .data? (.bss): no file bytes.
;
; sel_app is the App pointer, stashed when the session starts so the mouse
; handlers (which arrive with no context argument) can reach it. sel_live is
; nonzero only while a session is in flight, which is what makes begin and
; cancel idempotent.
; ---------------------------------------------------------------------------
.data?
sel_app    DWORD ?          ; App *, for the duration of the session
sel_live   DWORD ?          ; 1 while a session is in flight, else 0
sel_down   DWORD ?          ; 1 while the left button is held
sel_mode   DWORD ?          ; the mode the session was started with
sel_origin Pt <>            ; where the drag was pressed, in screen pixels
sel_cur    Pt <>            ; where the pointer is now, in screen pixels
sel_rect   Rect <>          ; the Selection so far

.code

; ---------------------------------------------------------------------------
; select_begin(App *app) -> BOOL in eax (nonzero on success).
; New was clicked. Hide the Shell, then raise the Overlay. If the Overlay will
; not come up the Shell is restored, so a failed session costs the user
; nothing. Already-live is a no-op, not an error.
; ---------------------------------------------------------------------------
select_begin PROC USES ebx esi edi app:DWORD
    mov  esi, app
    cmp  sel_live, 0
    jne  sb_ok

    ; ticket 02 is rectangular only: the drop-down does not select the gesture
    ; yet. Tickets 07, 08, and 09 dispatch on App.mode here.
    mov  sel_mode, MODE_RECT

    ; clear the stale Selection so a previous session cannot leak through
    mov  sel_down, 0
    mov  sel_rect.left, 0
    mov  sel_rect.top, 0
    mov  sel_rect.right, 0
    mov  sel_rect.bottom, 0

    mov  sel_app, esi

    ; The Shell goes away for the duration: it must never sit under the dim or
    ; inside the snip (spec, user story 5). The Editor goes too - the topmost
    ; Overlay covers it, so the user never sees it, but it is not excluded from
    ; capture and a Selection over it would otherwise capture its pixels.
    mov  ebx, [esi].App.hwndShell
    INVOKE ShowWindow, ebx, SW_HIDE

    mov  edi, [esi].App.hwndEditor
    test edi, edi
    jz   sb_raise
    INVOKE ShowWindow, edi, SW_HIDE

sb_raise:
    INVOKE overlay_show, esi, sel_mode
    test eax, eax
    jz   sb_fail

    mov  sel_live, 1
sb_ok:
    mov  eax, 1
    ret

sb_fail:
    ; A session that cannot raise the Overlay costs the user nothing: both
    ; windows come back.
    INVOKE ShowWindow, ebx, SW_SHOW
    test edi, edi
    jz   sb_fail_done
    INVOKE ShowWindow, edi, SW_SHOW
sb_fail_done:
    xor  eax, eax
    ret
select_begin ENDP

; ---------------------------------------------------------------------------
; sel_ldown(lParam) - the left button went down on the Overlay (screen coords
; in lParam). Anchors the drag and captures the mouse so it keeps tracking when
; the pointer leaves the Overlay.
;
; lParam is parsed into memory BEFORE SetCapture: on x86 INVOKE pushes it, so
; the x64 volatile-register trap does not exist here, but reading it first is
; the habit that keeps the two targets' handlers identical.
; ---------------------------------------------------------------------------
sel_ldown PROC USES ebx lParam:DWORD
    ; LOWORD(lParam) = x, HIWORD(lParam) = y
    mov  eax, lParam
    movsx ecx, ax                 ; x
    mov  sel_origin.x, ecx
    mov  sel_cur.x, ecx
    shr  eax, 16
    movsx edx, ax                 ; y
    mov  sel_origin.y, edx
    mov  sel_cur.y, edx

    cmp  sel_mode, MODE_RECT
    jne  sl_done
    INVOKE geo_normalise, ADDR sel_rect, ADDR sel_origin, ADDR sel_cur
    mov  sel_down, 1

sl_done:
    mov  eax, sel_app
    mov  ebx, [eax].App.hwndOverlay
    INVOKE SetCapture, ebx
    ret
sel_ldown ENDP

; ---------------------------------------------------------------------------
; sel_mmove(lParam) - pointer moved over the Overlay. While the button is held
; in rect mode, extend the Selection and repaint.
; ---------------------------------------------------------------------------
sel_mmove PROC USES ebx lParam:DWORD
    ; x
    mov  eax, lParam
    movsx ecx, ax
    mov  sel_cur.x, ecx
    ; y
    shr  eax, 16
    movsx edx, ax
    mov  sel_cur.y, edx

    cmp  sel_down, 0
    je   sm_done

    INVOKE geo_normalise, ADDR sel_rect, ADDR sel_origin, ADDR sel_cur
    INVOKE sel_repaint

sm_done:
    ret
sel_mmove ENDP

; ---------------------------------------------------------------------------
; sel_repaint - ask the Overlay to redraw the dim, the hole, and the readout.
; The Overlay presents a finished layered DIB; it never reads sel_* itself, so
; the dependency runs one way: select -> overlay.
; ---------------------------------------------------------------------------
sel_repaint PROC
    mov  eax, sel_app
    test eax, eax
    jz   sr_done
    INVOKE overlay_repaint, eax, ADDR sel_rect, sel_down
sr_done:
    ret
sel_repaint ENDP

; ---------------------------------------------------------------------------
; sel_lup - the button came up. A drag that outlined at least one pixel is a
; Selection; anything else (a stray click) is ignored and the Overlay stays up.
; ---------------------------------------------------------------------------
sel_lup PROC
    cmp  sel_down, 0
    je   su_done
    mov  sel_down, 0
    INVOKE ReleaseCapture

    ; a click with no drag is not a Selection
    INVOKE geo_width, ADDR sel_rect
    cmp  eax, 0
    jle  su_done
    INVOKE geo_height, ADDR sel_rect
    cmp  eax, 0
    jle  su_done

    INVOKE select_finish

su_done:
    ret
sel_lup ENDP

; ---------------------------------------------------------------------------
; select_finish - the Selection is complete. Crop it into a Snip and hand it to
; the Editor, then end the session.
;
; Order matters. The capture must happen while the Shell and Editor are still
; hidden (they were hidden at begin), or a re-shown window could land in the
; Snip. dib_crop is atomic, so a failed capture leaves any previous Snip - and
; the Editor showing it - intact; the visible error surface is ticket 11.
; ---------------------------------------------------------------------------
select_finish PROC USES ebx esi
    mov  esi, sel_app
    test esi, esi
    jz   sf_off

    INVOKE dib_crop, ADDR sel_rect
    mov  ebx, eax

    INVOKE sel_restore
    mov  sel_live, 0

    test ebx, ebx
    jz   sf_done
    INVOKE editor_open, esi

sf_done:
    ret

sf_off:
    mov  sel_live, 0
    ret
select_finish ENDP

; ---------------------------------------------------------------------------
; select_cancel - Escape or a right-click. Drop the Selection, end the session,
; put the Shell back. The Selection is NOT recorded, so nothing downstream can
; pick up a cancelled session.
; ---------------------------------------------------------------------------
select_cancel PROC
    mov  sel_down, 0
    INVOKE ReleaseCapture
    INVOKE sel_restore
    mov  sel_live, 0
    ret
select_cancel ENDP

; ---------------------------------------------------------------------------
; sel_restore - hide the Overlay and show the Shell again.
; ---------------------------------------------------------------------------
sel_restore PROC USES esi
    mov  esi, sel_app
    test esi, esi
    jz   sres_done

    INVOKE overlay_hide, esi

    mov  eax, [esi].App.hwndShell
    test eax, eax
    jz   sres_editor
    INVOKE ShowWindow, eax, SW_SHOW
    INVOKE SetFocus, eax

sres_editor:
    ; The Editor hid with the Shell; it returns alongside it. On the first Snip
    ; it does not exist yet and editor_open creates it moments later.
    mov  eax, [esi].App.hwndEditor
    test eax, eax
    jz   sres_done
    INVOKE ShowWindow, eax, SW_SHOW

sres_done:
    ret
sel_restore ENDP

; ---------------------------------------------------------------------------
; sel_wndproc(hwnd, msg, wParam, lParam) - the Overlay's messages.
; Lives here, not in overlay.asm: the Overlay is a surface, this module is the
; behaviour that runs on it.
; ---------------------------------------------------------------------------
sel_wndproc PROC hwnd:DWORD, msg:DWORD, wParam:DWORD, lParam:DWORD
    mov  eax, msg
    cmp  eax, WM_MOUSEMOVE
    je   sw_mmove
    cmp  eax, WM_LBUTTONDOWN
    je   sw_ldown
    cmp  eax, WM_LBUTTONUP
    je   sw_lup
    cmp  eax, WM_RBUTTONUP
    je   sw_cancel
    cmp  eax, WM_KEYDOWN
    je   sw_key

sw_default:
    INVOKE DefWindowProcW, hwnd, msg, wParam, lParam
    ret

sw_mmove:
    INVOKE sel_mmove, lParam
    xor  eax, eax
    ret

sw_ldown:
    INVOKE sel_ldown, lParam
    xor  eax, eax
    ret

sw_lup:
    INVOKE sel_lup
    xor  eax, eax
    ret

sw_cancel:
    INVOKE select_cancel
    xor  eax, eax
    ret

sw_key:
    cmp  wParam, VK_ESCAPE
    jne  sw_default
    INVOKE select_cancel
    xor  eax, eax
    ret
sel_wndproc ENDP

END
