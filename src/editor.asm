; editor.asm
; The Editor window: where the Snip lands and (tickets 05/06) is annotated.
;
; Ticket 03 is the window and the paint path, nothing else: one window created
; once and reused for every Snip - no window churn - sized to the Snip and
; showing it. The toolbar, Copy/Save As, and the annotation tools land in 05 and
; 06; zoom in ticket 17.
;
; The window is normal, not topmost, and no menu bar (spec). While a Snipping
; session is live it is hidden by select.asm, exactly like the Shell: the
; topmost Overlay covers it anyway, but it is not excluded from capture, so a
; Selection over it would otherwise capture its pixels.
;
; It paints from the Snip's own memory DC with a single BitBlt. The Snip is
; straight BGRA; for a rectangular Snip every pixel is opaque, so a colour blit
; is exact. (Free-form cuts, ticket 07, will need alpha-aware painting here.)
;
; See docs/capture.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC editor_open

; Forward declarations so INVOKE and OFFSET reach the rest of the file.
editor_create   PROTO STDCALL :DWORD                       ; HWND editor_create(App *app)
editor_fit      PROTO STDCALL :DWORD, :DWORD               ; void editor_fit(App *app, DWORD hwnd)
editor_do_paint PROTO STDCALL :DWORD                       ; void editor_do_paint(DWORD hwnd)
editor_wndproc  PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD

ED_STYLE EQU WS_CAPTION OR WS_SYSMENU OR WS_MINIMIZEBOX

; ---------------------------------------------------------------------------
; Statics. The Editor is a singleton, so its class lives here.
; ---------------------------------------------------------------------------
.const
ed_class DW 'S','n','i','p','E','d','i','t','o','r',0
ed_title DW 'S','n','i','p','p','i','n','g',' ','T','o','o','l',0

.data?
ed_wc WNDCLASSEXW <>

.code

; ---------------------------------------------------------------------------
; editor_open(App *app) -> BOOL in eax. Create the Editor if it does not exist,
; size it to the live Snip, and bring it to the front. Reuse is the norm: after
; the first Snip this only resizes and repaints the same window.
; ---------------------------------------------------------------------------
editor_open PROC USES ebx esi app:DWORD
    mov  esi, app
    mov  ebx, [esi].App.hwndEditor
    test ebx, ebx
    jnz  eo_have

    INVOKE editor_create, esi
    test eax, eax
    jz   eo_fail
    mov  ebx, eax
    mov  [esi].App.hwndEditor, ebx

eo_have:
    INVOKE editor_fit, esi, ebx
    INVOKE InvalidateRect, ebx, 0, 1
    INVOKE ShowWindow, ebx, SW_SHOW
    INVOKE SetForegroundWindow, ebx
    INVOKE SetFocus, ebx
    mov  eax, 1
    ret

eo_fail:
    xor  eax, eax
    ret
editor_open ENDP

; ---------------------------------------------------------------------------
; editor_create(App *app) -> HWND in eax, or 0. Register the class once and
; create the window. The window is not shown here; editor_open sizes it first.
; ---------------------------------------------------------------------------
editor_create PROC USES ebx app:DWORD
    mov  ebx, app

    mov  ed_wc.cbSize, SIZEOF WNDCLASSEXW
    mov  ed_wc.style, CS_HREDRAW OR CS_VREDRAW
    mov  ed_wc.lpfnWndProc, OFFSET editor_wndproc
    mov  ed_wc.cbClsExtra, 0
    mov  ed_wc.cbWndExtra, 0
    mov  eax, [ebx].App.hInstance
    mov  ed_wc.hInstance, eax
    mov  ed_wc.hbrBackground, COLOR_WINDOW_1

    INVOKE LoadCursorW, 0, IDC_ARROW
    mov  ed_wc.hCursor, eax

    mov  ed_wc.lpszClassName, OFFSET ed_class

    INVOKE RegisterClassExW, OFFSET ed_wc
    test eax, eax
    jz   ec_fail

    mov  edx, [ebx].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET ed_class, OFFSET ed_title, ED_STYLE, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, 0, 0, edx, ebx
    ret

ec_fail:
    xor  eax, eax
    ret
editor_create ENDP

; ---------------------------------------------------------------------------
; editor_fit(App *app, DWORD hwnd) - size the Editor's client area to the Snip
; and place it on the Snip's monitor. A Snip larger than the work area is
; capped and clipped: there is no zoom yet (ticket 17), and no pan (spec), so
; shrinking would be a lie about what Copy will publish.
; ---------------------------------------------------------------------------
editor_fit PROC USES esi app:DWORD, hwnd:DWORD
    LOCAL rc:RECT
    LOCAL mi:MONITORINFO
    LOCAL winW:DWORD
    LOCAL winH:DWORD
    LOCAL outW:DWORD
    LOCAL outH:DWORD
    LOCAL posX:DWORD
    LOCAL posY:DWORD
    LOCAL haveMI:DWORD

    mov  haveMI, 0

    INVOKE dib_snip
    mov  esi, eax
    mov  eax, [esi].Snip.w
    mov  winW, eax
    mov  eax, [esi].Snip.h
    mov  winH, eax
    cmp  winW, 1
    jl   ef_done
    cmp  winH, 1
    jl   ef_done

    ; The Snip's screen rectangle picks the monitor to fit inside.
    mov  eax, [esi].Snip.x
    mov  rc.left, eax
    mov  eax, [esi].Snip.y
    mov  rc.top, eax
    mov  eax, [esi].Snip.x
    add  eax, winW
    mov  rc.right, eax
    mov  eax, [esi].Snip.y
    add  eax, winH
    mov  rc.bottom, eax

    mov  mi.cbSize, SIZEOF MONITORINFO
    INVOKE MonitorFromRect, ADDR rc, MONITOR_DEFAULTTONEAREST
    mov  posX, eax                   ; keep the HMONITOR out of a live register
    INVOKE GetMonitorInfoW, posX, ADDR mi
    test eax, eax
    jz   ef_unclamped
    mov  haveMI, 1

    ; Cap the client to the work area.
    mov  eax, mi.rcWork.right
    sub  eax, mi.rcWork.left
    cmp  winW, eax
    jle  ef_cap_h
    mov  winW, eax
ef_cap_h:
    mov  eax, mi.rcWork.bottom
    sub  eax, mi.rcWork.top
    cmp  winH, eax
    jle  ef_unclamped
    mov  winH, eax

ef_unclamped:
    ; Outer size for that client area.
    mov  rc.left, 0
    mov  rc.top, 0
    mov  eax, winW
    mov  rc.right, eax
    mov  eax, winH
    mov  rc.bottom, eax
    INVOKE AdjustWindowRect, ADDR rc, ED_STYLE, 0
    mov  eax, rc.right
    sub  eax, rc.left
    mov  outW, eax
    mov  eax, rc.bottom
    sub  eax, rc.top
    mov  outH, eax

    ; Place at the Snip's origin, clamped into the work area.
    mov  eax, [esi].Snip.x
    mov  posX, eax
    mov  eax, [esi].Snip.y
    mov  posY, eax
    cmp  haveMI, 0
    jz   ef_place

    mov  eax, posX
    cmp  eax, mi.rcWork.left
    jge  ef_x_lo
    mov  eax, mi.rcWork.left
ef_x_lo:
    mov  edx, mi.rcWork.right
    sub  edx, outW
    cmp  eax, edx
    jle  ef_x_hi
    mov  eax, edx
ef_x_hi:
    mov  posX, eax

    mov  eax, posY
    cmp  eax, mi.rcWork.top
    jge  ef_y_lo
    mov  eax, mi.rcWork.top
ef_y_lo:
    mov  edx, mi.rcWork.bottom
    sub  edx, outH
    cmp  eax, edx
    jle  ef_y_hi
    mov  eax, edx
ef_y_hi:
    mov  posY, eax

ef_place:
    INVOKE MoveWindow, hwnd, posX, posY, outW, outH, 1

ef_done:
    ret
editor_fit ENDP

; ---------------------------------------------------------------------------
; editor_do_paint(DWORD hwnd) - copy the Working bitmap onto the window.
; BitBlt clips to the window, so a Snip capped by editor_fit shows its top-left
; corner and nothing else.
; ---------------------------------------------------------------------------
editor_do_paint PROC USES ebx esi hwnd:DWORD
    LOCAL ps:PAINTSTRUCT
    LOCAL srcW:DWORD
    LOCAL srcH:DWORD
    LOCAL src:DWORD

    INVOKE BeginPaint, hwnd, ADDR ps
    mov  esi, eax

    INVOKE dib_snip
    mov  ebx, eax
    mov  eax, [ebx].Snip.hdc
    mov  src, eax
    mov  eax, [ebx].Snip.w
    mov  srcW, eax
    mov  eax, [ebx].Snip.h
    mov  srcH, eax

    cmp  src, 0
    jz   ep_done
    cmp  srcW, 1
    jl   ep_done
    cmp  srcH, 1
    jl   ep_done

    INVOKE BitBlt, esi, 0, 0, srcW, srcH, src, 0, 0, SRCCOPY

ep_done:
    INVOKE EndPaint, hwnd, ADDR ps
    ret
editor_do_paint ENDP

; ---------------------------------------------------------------------------
; editor_wndproc(hwnd, msg, wParam, lParam). Closing hides rather than destroys:
; the window is reused for the next Snip, so there is one Editor for the life of
; the process. Quitting is the Shell's job.
; ---------------------------------------------------------------------------
editor_wndproc PROC hwnd:DWORD, msg:DWORD, wParam:DWORD, lParam:DWORD
    mov  eax, msg
    cmp  eax, WM_CREATE
    je   ew_create
    cmp  eax, WM_PAINT
    je   ew_paint
    cmp  eax, WM_ERASEBKGND
    je   ew_erase
    cmp  eax, WM_CLOSE
    je   ew_close

    INVOKE DefWindowProcW, hwnd, msg, wParam, lParam
    ret

ew_create:
    ; app = ((CREATESTRUCTW *)lParam)->lpCreateParams, the struct's first field
    mov  eax, lParam
    mov  eax, [eax]
    INVOKE SetWindowLongW, hwnd, GWLP_USERDATA, eax
    xor  eax, eax
    ret

ew_paint:
    INVOKE editor_do_paint, hwnd
    xor  eax, eax
    ret

ew_erase:
    mov  eax, 1                  ; we paint every pixel ourselves
    ret

ew_close:
    INVOKE ShowWindow, hwnd, SW_HIDE
    xor  eax, eax
    ret
editor_wndproc ENDP

END
