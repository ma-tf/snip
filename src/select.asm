; select.asm
; The Selection state machine and the Snipping session lifecycle.
;
; A session runs from a New click to the Selection being completed or
; cancelled. This module owns that lifecycle: it raises the Overlay, tracks the
; drag, and puts the Shell back afterwards. It is the only module that knows a
; session is in flight.
;
; Ticket 02 is rectangular only. Ticket 07 added the free-form gesture and the
; mode dispatch; ticket 08 adds the window gesture below, and ticket 09 will add
; full-screen. Each mode gets its own branch rather than falling through to the
; drag handler (see the prototype's bug 2).
;
; The live state is module-private: a session is a singleton, like the Shell.
; When the Selection completes, select_finish drives the handoff: the Selection
; is translated from the Overlay's client space to screen pixels, cropped into a
; Snip (dib.asm), and shown (editor.asm).
;
; Two desktop changes matter here. WM_DISPLAYCHANGE during a session aborts it -
; a Snip cropped against a stale virtual screen would be clipped or wrong.
; WM_DPICHANGED re-lays-out the Overlay's chrome (overlay.asm owns the scaling).
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
sel_hover    PROTO STDCALL
sel_selectable PROTO STDCALL :DWORD
sel_class_eq PROTO STDCALL :DWORD, :DWORD
sel_restore  PROTO STDCALL
sel_repaint  PROTO STDCALL

; ---------------------------------------------------------------------------
; The window-mode hover filter's class names. The desktop, the wallpaper host,
; and the taskbars are not selectable windows.
; ---------------------------------------------------------------------------
.const
cls_progman  DW 'P','r','o','g','m','a','n',0
cls_workerw  DW 'W','o','r','k','e','r','W',0
cls_tray     DW 'S','h','e','l','l','_','T','r','a','y','W','n','d',0
cls_tray2    DW 'S','h','e','l','l','_','S','e','c','o','n','d','a','r','y','T','r','a','y','W','n','d',0

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
sel_dpi    DWORD ?          ; the Overlay's effective DPI; scales the free-form sample threshold
sel_vx     SDWORD ?         ; the virtual-screen origin, read at session start
sel_vy     SDWORD ?
sel_hwnd   DWORD ?          ; window mode: the top-level window under the cursor
sel_has    DWORD ?          ; window mode: 1 when sel_hwnd is capturable
sel_origin Pt <>            ; where the drag was pressed, in Overlay client pixels
sel_cur    Pt <>            ; where the pointer is now, in Overlay client pixels
sel_rect   Rect <>          ; the Selection so far, in Overlay client pixels

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

    ; The mode comes from the Shell's drop-down, clamped so a bad index cannot
    ; select a branch that does not exist yet.
    mov  eax, [esi].App.mode
    cmp  eax, MODE_FREE
    jbe  sb_mode_ok
    xor  eax, eax
sb_mode_ok:
    mov  sel_mode, eax

    ; clear the stale Selection so a previous session cannot leak through
    mov  sel_down, 0
    mov  sel_has, 0
    mov  sel_hwnd, 0
    mov  sel_rect.left, 0
    mov  sel_rect.top, 0
    mov  sel_rect.right, 0
    mov  sel_rect.bottom, 0

    ; The Overlay's client space *is* the virtual screen, so the pointer's client
    ; coordinates are virtual-relative. The origin is read fresh here, at session
    ; start - never cached from process startup - and applied once at the handoff.
    INVOKE GetSystemMetrics, SM_XVIRTUALSCREEN
    mov  sel_vx, eax
    INVOKE GetSystemMetrics, SM_YVIRTUALSCREEN
    mov  sel_vy, eax

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

    ; The Overlay's effective DPI scales the free-form sample threshold. Read it
    ; fresh every session, like the Overlay does, so a scale change is picked up.
    mov  eax, [esi].App.hwndOverlay
    INVOKE GetDpiForWindow, eax
    test eax, eax
    jnz  sb_dpi_ok
    mov  eax, 96
sb_dpi_ok:
    mov  sel_dpi, eax
    cmp  sel_mode, MODE_FREE
    jne  sb_live
    INVOKE mask_reset, sel_dpi

sb_live:
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
; sel_ldown(lParam) - the left button went down on the Overlay (client coords in
; lParam; the Overlay's client origin is the virtual-screen origin). Anchors the
; drag and captures the mouse so it keeps tracking when the pointer leaves the
; Overlay.
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

    cmp  sel_mode, MODE_WINDOW
    je   sl_window
    cmp  sel_mode, MODE_RECT
    je   sl_rect
    cmp  sel_mode, MODE_FREE
    je   sl_free
    jmp  sl_done                  ; full-screen: ticket 09

sl_window:
    ; A click captures the window the hover is highlighting. Resolve once more at
    ; the click point, in case the pointer arrived without a move. There is no
    ; drag and the session ends inside select_finish, so no SetCapture.
    INVOKE sel_hover
    cmp  sel_has, 0
    je   sl_window_done
    INVOKE select_finish
sl_window_done:
    ret

sl_rect:
    INVOKE geo_normalise, ADDR sel_rect, ADDR sel_origin, ADDR sel_cur
    mov  sel_down, 1
    jmp  sl_done

sl_free:
    ; Press starts a fresh Trace; mask_add accepts the first point unconditionally.
    INVOKE mask_reset, sel_dpi
    INVOKE mask_add, sel_cur.x, sel_cur.y
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

    ; Window mode highlights as the pointer moves, with no button held.
    cmp  sel_mode, MODE_WINDOW
    jne  sm_drag
    INVOKE sel_hover
    ret

sm_drag:
    cmp  sel_down, 0
    je   sm_done

    cmp  sel_mode, MODE_FREE
    je   sm_free

    INVOKE geo_normalise, ADDR sel_rect, ADDR sel_origin, ADDR sel_cur
    INVOKE sel_repaint
    jmp  sm_done

sm_free:
    INVOKE mask_add, sel_cur.x, sel_cur.y
    test eax, eax
    jz   sm_done
    INVOKE mask_bbox, ADDR sel_rect
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
    LOCAL p:DWORD
    LOCAL cnt:DWORD

    mov  eax, sel_app
    test eax, eax
    jz   sr_done

    cmp  sel_mode, MODE_WINDOW
    je   sr_window
    cmp  sel_mode, MODE_FREE
    je   sr_free

    INVOKE overlay_repaint, eax, ADDR sel_rect, sel_down
    jmp  sr_done

sr_window:
    ; Highlight the hovered window, or present the bare dim when none is
    ; selectable (sel_rect is stale then, so it must not be passed).
    cmp  sel_has, 0
    je   sr_window_dim
    INVOKE overlay_repaint, eax, ADDR sel_rect, 0
    jmp  sr_done
sr_window_dim:
    INVOKE overlay_repaint, eax, 0, 0
    jmp  sr_done

sr_free:
    INVOKE mask_points
    mov  p, eax
    INVOKE mask_count
    mov  cnt, eax
    mov  eax, sel_app
    INVOKE overlay_repaint_free, eax, p, cnt, ADDR sel_rect

sr_done:
    ret
sel_repaint ENDP

; ---------------------------------------------------------------------------
; sel_hover - window mode: resolve the top-level window under the pointer,
; highlight it, and remember it for the click. Called on every move; it repaints
; only when the resolved window changes, so dragging the pointer over one window
; does not re-present the layered frame every message.
;
; The Overlay is topmost and covers the whole desktop, so WindowFromPoint would
; return the Overlay itself. Flipping it WS_EX_TRANSPARENT around the call makes
; the hit-test skip it - the ticket 07 prototype's finding.
; ---------------------------------------------------------------------------
sel_hover PROC USES ebx esi edi
    LOCAL sx:SDWORD
    LOCAL sy:SDWORD
    LOCAL style:DWORD
    LOCAL hwnd:DWORD

    mov  esi, sel_app
    test esi, esi
    jz   sh_done

    ; pointer, virtual-relative -> screen pixels
    mov  eax, sel_cur.x
    add  eax, sel_vx
    mov  sx, eax
    mov  eax, sel_cur.y
    add  eax, sel_vy
    mov  sy, eax

    mov  ebx, [esi].App.hwndOverlay

    ; hit-test with the Overlay out of the way, then restore it
    INVOKE GetWindowLongW, ebx, GWL_EXSTYLE
    mov  style, eax
    mov  ecx, eax
    or   ecx, WS_EX_TRANSPARENT
    INVOKE SetWindowLongW, ebx, GWL_EXSTYLE, ecx
    INVOKE WindowFromPoint, sx, sy
    mov  hwnd, eax
    INVOKE SetWindowLongW, ebx, GWL_EXSTYLE, style

    ; the top-level window, if it is one we may snip
    mov  eax, hwnd
    test eax, eax
    jz   sh_none
    INVOKE GetAncestor, eax, GA_ROOT
    mov  hwnd, eax
    test eax, eax
    jz   sh_none
    INVOKE sel_selectable, hwnd
    test eax, eax
    jz   sh_none

    ; the same window as last time: nothing to repaint
    mov  eax, hwnd
    cmp  eax, sel_hwnd
    je   sh_done

    ; take its frame, then remember it and convert frame -> client pixels
    INVOKE window_frame, hwnd, ADDR sel_rect
    test eax, eax
    jz   sh_none
    mov  eax, hwnd
    mov  sel_hwnd, eax
    mov  eax, sel_vx
    sub  sel_rect.left, eax
    sub  sel_rect.right, eax
    mov  eax, sel_vy
    sub  sel_rect.top, eax
    sub  sel_rect.bottom, eax

    mov  sel_has, 1
    INVOKE sel_repaint
    ret

sh_none:
    ; no selectable window: drop the highlight if one was up
    cmp  sel_has, 0
    je   sh_done
    mov  sel_has, 0
    mov  sel_hwnd, 0
    INVOKE sel_repaint

sh_done:
    ret
sel_hover ENDP

; ---------------------------------------------------------------------------
; sel_selectable(HWND) -> BOOL in eax. Whether a top-level window may be snipped.
; Rejects our own Overlay, the desktop and the shell window, minimised windows,
; and the wallpaper host and taskbar classes.
; ---------------------------------------------------------------------------
sel_selectable PROC USES ebx esi edi hwnd:DWORD
    LOCAL buf[64]:WORD

    mov  esi, sel_app
    test esi, esi
    jz   ss_no

    mov  eax, [esi].App.hwndOverlay
    cmp  hwnd, eax
    je   ss_no

    INVOKE GetDesktopWindow
    cmp  hwnd, eax
    je   ss_no
    INVOKE GetShellWindow
    cmp  hwnd, eax
    je   ss_no

    INVOKE IsIconic, hwnd
    test eax, eax
    jnz  ss_no

    INVOKE GetClassNameW, hwnd, ADDR buf, 64
    INVOKE sel_class_eq, ADDR buf, OFFSET cls_progman
    test eax, eax
    jnz  ss_no
    INVOKE sel_class_eq, ADDR buf, OFFSET cls_workerw
    test eax, eax
    jnz  ss_no
    INVOKE sel_class_eq, ADDR buf, OFFSET cls_tray
    test eax, eax
    jnz  ss_no
    INVOKE sel_class_eq, ADDR buf, OFFSET cls_tray2
    test eax, eax
    jnz  ss_no

    mov  eax, 1
    ret
ss_no:
    xor  eax, eax
    ret
sel_selectable ENDP

; ---------------------------------------------------------------------------
; sel_class_eq(WORD *cand, WORD *lit) -> BOOL in eax. Exact wide-string compare.
; ---------------------------------------------------------------------------
sel_class_eq PROC USES esi edi cand:DWORD, lit:DWORD
    mov  esi, cand
    mov  edi, lit

sce_loop:
    mov  ax, [esi]
    cmp  ax, [edi]
    jne  sce_no
    test ax, ax
    jz   sce_yes
    add  esi, 2
    add  edi, 2
    jmp  sce_loop

sce_yes:
    mov  eax, 1
    ret
sce_no:
    xor  eax, eax
    ret
sel_class_eq ENDP

; ---------------------------------------------------------------------------
; sel_lup - the button came up. A drag that outlined at least one pixel is a
; Selection; anything else (a stray click) is ignored and the Overlay stays up.
; ---------------------------------------------------------------------------
sel_lup PROC
    cmp  sel_down, 0
    je   su_done
    mov  sel_down, 0
    INVOKE ReleaseCapture

    cmp  sel_mode, MODE_FREE
    je   su_free

    ; a click with no drag is not a Selection
    INVOKE geo_width, ADDR sel_rect
    cmp  eax, 0
    jle  su_done
    INVOKE geo_height, ADDR sel_rect
    cmp  eax, 0
    jle  su_done

    INVOKE select_finish
    jmp  su_done

su_free:
    ; Simplify, then refuse a degenerate Trace: the Overlay simply stays up
    ; rather than producing a zero-size Snip.
    INVOKE mask_simplify
    INVOKE mask_bbox, ADDR sel_rect
    INVOKE mask_degenerate
    test eax, eax
    jnz  su_done
    INVOKE select_finish

su_done:
    ret
sel_lup ENDP

; ---------------------------------------------------------------------------
; select_finish - the Selection is complete. Translate it to screen pixels, crop
; it into a Snip, hand it to the Editor, then end the session.
;
; The Overlay's client space is virtual-relative; the capture path and the
; Editor work in screen pixels, so the virtual origin is added here - once, at
; the boundary (research: "Convert once, at the boundary"). On a single monitor
; at (0,0) the two spaces coincide; on a monitor left of the primary they do not,
; and without this the Snip would be blitted from the wrong place.
;
; Order matters. The capture must happen while the Shell and Editor are still
; hidden (they were hidden at begin), or a re-shown window could land in the
; Snip. dib_crop is atomic, so a failed capture leaves any previous Snip - and
; the Editor showing it - intact; the visible error surface is ticket 11.
; ---------------------------------------------------------------------------
select_finish PROC USES ebx esi
    LOCAL p:DWORD

    cmp  sel_live, 0
    je   sf_off

    mov  esi, sel_app
    test esi, esi
    jz   sf_off

    cmp  sel_mode, MODE_FREE
    je   sf_free

    ; rect and window selections are both virtual-relative -> screen pixels,
    ; inclusive bounds and all
    mov  eax, sel_vx
    add  sel_rect.left, eax
    add  sel_rect.right, eax
    mov  eax, sel_vy
    add  sel_rect.top, eax
    add  sel_rect.bottom, eax

    cmp  sel_mode, MODE_WINDOW
    je   sf_window

    INVOKE dib_crop, ADDR sel_rect
    mov  ebx, eax
    jmp  sf_cropped

sf_window:
    ; The same rect, but filled by PrintWindow instead of the region blit.
    INVOKE dib_crop_window, ADDR sel_rect, sel_hwnd
    mov  ebx, eax
    jmp  sf_cropped

sf_free:
    ; The Trace and its bbox move to screen pixels together; dib_crop_free then
    ; makes the path bbox-local for the fill.
    INVOKE mask_translate, sel_vx, sel_vy
    INVOKE mask_bbox, ADDR sel_rect
    INVOKE mask_points
    mov  p, eax
    INVOKE mask_count
    INVOKE dib_crop_free, ADDR sel_rect, p, eax
    mov  ebx, eax

sf_cropped:
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
    cmp  eax, WM_DISPLAYCHANGE
    je   sw_display
    cmp  eax, WM_DPICHANGED
    je   sw_dpi

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

; A monitor was added, removed, or re-scaled mid-session. The Selection was made
; against the old virtual screen, so a crop now could be clipped or stale; abort
; the session instead. Geometry is not cached, so the next session's
; overlay_show re-reads it.
sw_display:
    cmp  sel_live, 0
    je   sw_display_done
    INVOKE select_cancel
sw_display_done:
    xor  eax, eax
    ret

; The Overlay's effective DPI changed. The window still spans the virtual screen
; - the suggested rectangle in lParam is ignored on purpose - but the readout
; chrome must be laid out for the new scale. overlay.asm owns that.
sw_dpi:
    mov  eax, wParam
    movzx eax, ax                 ; LOWORD(wParam) is the new DPI
    mov  sel_dpi, eax
    INVOKE overlay_set_dpi, sel_dpi
    cmp  sel_live, 0
    je   sw_dpi_done
    INVOKE sel_repaint
sw_dpi_done:
    xor  eax, eax
    ret
sel_wndproc ENDP

END
