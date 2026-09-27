; editor.asm
; The Editor window: where the Snip lands and is annotated.
;
; Ticket 03 is the window and the paint path; ticket 05 adds the toolbar and
; wires New, Save, and Copy; ticket 06 makes Pen, Highlighter, Eraser, and Undo
; live. The annotation engine itself - the command log, the GDI+ strokes, the
; Eraser, and Undo - lives in ink.asm; this file owns the window, the toolbar,
; the mouse, and the mapping from client pixels to Snip pixels. Zoom is
; ticket 17.
;
; The window is normal, not topmost, and no menu bar (spec). While a Snipping
; session is live it is hidden by select.asm, exactly like the Shell: the
; topmost Overlay covers it anyway, but it is not excluded from capture, so a
; Selection over it would otherwise capture its pixels.
;
; It paints from the Snip's own memory DC with a single BitBlt, offset below the
; toolbar. The Snip is straight BGRA; for a rectangular Snip every pixel is
; opaque, so a colour blit is exact. (Free-form cuts, ticket 07, will need
; alpha-aware painting here.)
;
; Copy and Save As hand the live Snip to encode.asm; nothing is re-captured. The
; annotations are already in the Working bitmap by then, so Copy and Save carry
; them for free. A failure is silently ignored here - ticket 11 owns the error
; surface.
;
; See docs/capture.md, docs/encode.md, and docs/ink.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC editor_open

; Forward declarations so INVOKE and OFFSET reach the rest of the file.
editor_create   PROTO STDCALL :DWORD                       ; HWND editor_create(App *app)
editor_on_create PROTO STDCALL :DWORD, :DWORD              ; void editor_on_create(DWORD hwnd, App *app)
editor_fit      PROTO STDCALL :DWORD, :DWORD               ; void editor_fit(App *app, DWORD hwnd)
editor_do_paint PROTO STDCALL :DWORD                       ; void editor_do_paint(DWORD hwnd)
editor_save     PROTO STDCALL :DWORD                       ; void editor_save(App *app)
editor_copy     PROTO STDCALL :DWORD                       ; void editor_copy(App *app)
editor_set_tool PROTO STDCALL :DWORD, :DWORD               ; void editor_set_tool(DWORD hwnd, DWORD tool)
editor_wndproc  PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD

ED_STYLE EQU WS_CAPTION OR WS_SYSMENU OR WS_MINIMIZEBOX

; The toolbar strip and the minimum client width that fits all seven buttons.
ED_TOOLBAR_H    EQU 32
ED_TOOLBAR_MINW EQU 456

; The mouse drag in flight: none, an ink stroke, or an Eraser pass.
ED_DRAG_NONE    EQU 0
ED_DRAG_STROKE  EQU 1
ED_DRAG_ERASE   EQU 2

; ---------------------------------------------------------------------------
; Statics. The Editor is a singleton, so its class lives here.
; ---------------------------------------------------------------------------
.const
ed_class DW 'S','n','i','p','E','d','i','t','o','r',0
ed_title DW 'S','n','i','p','p','i','n','g',' ','T','o','o','l',0
ed_cls_button DW 'B','u','t','t','o','n',0

btn_new        DW 'N','e','w',0
btn_save       DW 'S','a','v','e',0
btn_copy       DW 'C','o','p','y',0
btn_pen        DW 'P','e','n',0
btn_hilite     DW 'H','i','g','h','l','i','g','h','t','e','r',0
btn_eraser     DW 'E','r','a','s','e','r',0
btn_undo       DW 'U','n','d','o',0

; Save As: a PNG filter, a default file name, and a default extension. The
; filter is a sequence of null-terminated pairs, ended by an empty string.
dlg_filter     DW 'P','N','G',' ','(','*','.','p','n','g',')',0
               DW '*','.','p','n','g',0
               DW 'A','l','l',' ','f','i','l','e','s',' ','(','*','.','*',')',0
               DW '*','.','*',0
               DW 0
dlg_defname    DW 'C','a','p','t','u','r','e','.','p','n','g',0
dlg_defext     DW 'p','n','g',0

.data?
ed_wc WNDCLASSEXW <>
ed_ofn OPENFILENAMEW <>
ed_file WORD MAX_PATH DUP(?)     ; the Save As file-name buffer

; Ticket 06 annotation state. The ink log itself lives in ink.asm; these are the
; window-side facts it needs: the active tool, the drag in flight, and the
; button handles whose pressed state shows the selection.
ed_tool        DWORD ?
ed_drag        DWORD ?
ed_dpi         DWORD ?
ed_hwndPen     DWORD ?
ed_hwndHilite  DWORD ?
ed_hwndEraser  DWORD ?

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
    ; A new Snip lands here: its annotations start empty.
    INVOKE ink_reset
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
; editor_on_create(DWORD hwnd, App *app) -> eax 0.
; Builds the toolbar: New, Save, Copy (live) and Pen, Highlighter, Eraser, Undo
; (inert until ticket 06). Stock BUTTON controls, same as the Shell's New.
; ---------------------------------------------------------------------------
editor_on_create PROC USES ebx esi edi hwnd:DWORD, app:DWORD
    LOCAL hCtl:DWORD
    LOCAL font:DWORD

    mov  ebx, hwnd
    mov  esi, app

    INVOKE GetStockObject, DEFAULT_GUI_FONT
    mov  font, eax
    mov  edi, [esi].App.hInstance

    ; New
    INVOKE CreateWindowExW, 0, OFFSET ed_cls_button, OFFSET btn_new, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON, 4, 4, 52, 24, ebx, IDC_ED_NEW, edi, 0
    INVOKE SendMessageW, eax, WM_SETFONT, font, 1
    ; Save
    INVOKE CreateWindowExW, 0, OFFSET ed_cls_button, OFFSET btn_save, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON, 60, 4, 56, 24, ebx, IDC_ED_SAVE, edi, 0
    INVOKE SendMessageW, eax, WM_SETFONT, font, 1
    ; Copy
    INVOKE CreateWindowExW, 0, OFFSET ed_cls_button, OFFSET btn_copy, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON, 120, 4, 56, 24, ebx, IDC_ED_COPY, edi, 0
    INVOKE SendMessageW, eax, WM_SETFONT, font, 1
    ; Pen
    INVOKE CreateWindowExW, 0, OFFSET ed_cls_button, OFFSET btn_pen, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON, 184, 4, 48, 24, ebx, IDC_ED_PEN, edi, 0
    mov  ed_hwndPen, eax
    INVOKE SendMessageW, eax, WM_SETFONT, font, 1
    ; Highlighter
    INVOKE CreateWindowExW, 0, OFFSET ed_cls_button, OFFSET btn_hilite, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON, 236, 4, 92, 24, ebx, IDC_ED_HILITE, edi, 0
    mov  ed_hwndHilite, eax
    INVOKE SendMessageW, eax, WM_SETFONT, font, 1
    ; Eraser
    INVOKE CreateWindowExW, 0, OFFSET ed_cls_button, OFFSET btn_eraser, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON, 332, 4, 60, 24, ebx, IDC_ED_ERASER, edi, 0
    mov  ed_hwndEraser, eax
    INVOKE SendMessageW, eax, WM_SETFONT, font, 1
    ; Undo
    INVOKE CreateWindowExW, 0, OFFSET ed_cls_button, OFFSET btn_undo, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON, 396, 4, 52, 24, ebx, IDC_ED_UNDO, edi, 0
    INVOKE SendMessageW, eax, WM_SETFONT, font, 1

    ; Pen is the tool in hand until another is chosen.
    mov  ed_drag, ED_DRAG_NONE
    INVOKE editor_set_tool, ebx, INK_PEN

    xor  eax, eax
    ret
editor_on_create ENDP

; ---------------------------------------------------------------------------
; editor_set_tool(DWORD hwnd, DWORD tool) - make a tool active and show it. The
; stock buttons are push buttons, so BM_SETSTATE gives the chosen one its
; pressed look and clears the rest.
; ---------------------------------------------------------------------------
editor_set_tool PROC USES ebx hwnd:DWORD, tool:DWORD
    mov  eax, tool
    mov  ed_tool, eax

    xor  ebx, ebx
    cmp  tool, INK_PEN
    sete bl
    INVOKE SendMessageW, ed_hwndPen, BM_SETSTATE, ebx, 0
    xor  ebx, ebx
    cmp  tool, INK_HILITE
    sete bl
    INVOKE SendMessageW, ed_hwndHilite, BM_SETSTATE, ebx, 0
    xor  ebx, ebx
    cmp  tool, INK_ERASER
    sete bl
    INVOKE SendMessageW, ed_hwndEraser, BM_SETSTATE, ebx, 0
    ret
editor_set_tool ENDP

; ---------------------------------------------------------------------------
; editor_copy(App *app) - put the live Snip on the clipboard through encode.asm.
; A failure is silent; ticket 11 adds the message.
; ---------------------------------------------------------------------------
editor_copy PROC app:DWORD
    INVOKE dib_snip
    cmp  [eax].Snip.w, 1
    jl   ecp_done
    INVOKE encode_clipboard, eax
ecp_done:
    ret
editor_copy ENDP

; ---------------------------------------------------------------------------
; editor_save(App *app) - Save As through the common dialog, then encode.
; ---------------------------------------------------------------------------
editor_save PROC USES ebx esi edi app:DWORD
    ; zero the OPENFILENAMEW, then seed the file-name buffer
    lea  edi, ed_ofn
    xor  eax, eax
    mov  ecx, (SIZEOF OPENFILENAMEW) / 4
    rep  stosd
    lea  edi, ed_file
    mov  esi, OFFSET dlg_defname
    mov  ecx, 6                      ; "Capture.png\0" == 12 WCHARs == 6 DWORDs
    rep  movsd

    mov  ed_ofn.lStructSize, SIZEOF OPENFILENAMEW
    mov  eax, app
    mov  eax, [eax].App.hwndEditor
    mov  ed_ofn.hwndOwner, eax
    mov  ed_ofn.lpstrFilter, OFFSET dlg_filter
    mov  ed_ofn.nFilterIndex, 1
    mov  ed_ofn.lpstrFile, OFFSET ed_file
    mov  ed_ofn.nMaxFile, MAX_PATH
    mov  ed_ofn.lpstrDefExt, OFFSET dlg_defext
    mov  ed_ofn.Flags, OFN_OVERWRITEPROMPT OR OFN_PATHMUSTEXIST OR OFN_EXPLORER

    INVOKE GetSaveFileNameW, OFFSET ed_ofn
    test eax, eax
    jz   esv_done

    INVOKE dib_snip
    INVOKE encode_file, eax, OFFSET ed_file

esv_done:
    ret
editor_save ENDP

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

    ; The client is the toolbar plus the image. Widen it if the Snip is too
    ; narrow to fit the toolbar; the image stays left-aligned under it.
    cmp  winW, ED_TOOLBAR_MINW
    jge  ef_minw
    mov  winW, ED_TOOLBAR_MINW
ef_minw:
    mov  eax, winH
    add  eax, ED_TOOLBAR_H
    mov  winH, eax

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
; editor_do_paint(DWORD hwnd) - copy the Working bitmap onto the window, then
; overdraw the in-progress stroke. BitBlt clips to the window, so a Snip capped
; by editor_fit shows its top-left corner and nothing else.
; ---------------------------------------------------------------------------
editor_do_paint PROC USES ebx esi hwnd:DWORD
    LOCAL ps:PAINTSTRUCT
    LOCAL rc:RECT
    LOCAL srcW:DWORD
    LOCAL srcH:DWORD
    LOCAL src:DWORD

    INVOKE BeginPaint, hwnd, ADDR ps
    mov  esi, eax

    ; The toolbar strip behind the buttons. WM_ERASEBKGND is suppressed, so
    ; this is what paints the gaps between the controls.
    INVOKE GetClientRect, hwnd, ADDR rc
    mov  rc.bottom, ED_TOOLBAR_H
    INVOKE FillRect, esi, ADDR rc, COLOR_BTNFACE_1

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

    INVOKE BitBlt, esi, 0, ED_TOOLBAR_H, srcW, srcH, src, 0, 0, SRCCOPY
    ; The in-progress stroke goes straight onto the paint DC, not Working, so a
    ; translucent Highlighter is not double-blended across its own drag frames.
    INVOKE ink_preview, esi, ED_TOOLBAR_H

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
    LOCAL px:SDWORD
    LOCAL py:SDWORD

    mov  eax, msg
    cmp  eax, WM_CREATE
    je   ew_create
    cmp  eax, WM_PAINT
    je   ew_paint
    cmp  eax, WM_ERASEBKGND
    je   ew_erase
    cmp  eax, WM_COMMAND
    je   ew_command
    cmp  eax, WM_LBUTTONDOWN
    je   ew_down
    cmp  eax, WM_MOUSEMOVE
    je   ew_move
    cmp  eax, WM_LBUTTONUP
    je   ew_up
    cmp  eax, WM_CAPTURECHANGED
    je   ew_capturechanged
    cmp  eax, WM_CLOSE
    je   ew_close

    INVOKE DefWindowProcW, hwnd, msg, wParam, lParam
    ret

ew_create:
    ; app = ((CREATESTRUCTW *)lParam)->lpCreateParams, the struct's first field
    mov  eax, lParam
    mov  eax, [eax]
    INVOKE SetWindowLongW, hwnd, GWLP_USERDATA, eax
    ; SetWindowLongW returns the *previous* value, so re-read lpCreateParams
    ; before handing app to editor_on_create (shell.asm does the same).
    mov  eax, lParam
    mov  eax, [eax]
    INVOKE editor_on_create, hwnd, eax
    xor  eax, eax
    ret

ew_command:
    ; wParam: LOWORD = control id, HIWORD = notification. Toolbar buttons are
    ; BN_CLICKED; anything else falls through.
    mov  eax, wParam
    shr  eax, 16
    and  eax, 0FFFFh
    cmp  eax, BN_CLICKED
    jne  ew_default

    mov  eax, wParam
    and  eax, 0FFFFh

    cmp  eax, IDC_ED_NEW
    je   ew_new
    cmp  eax, IDC_ED_COPY
    je   ew_copy
    cmp  eax, IDC_ED_SAVE
    je   ew_save
    cmp  eax, IDC_ED_PEN
    je   ew_pen
    cmp  eax, IDC_ED_HILITE
    je   ew_hilite
    cmp  eax, IDC_ED_ERASER
    je   ew_eraser
    cmp  eax, IDC_ED_UNDO
    je   ew_undo

ew_default:
    INVOKE DefWindowProcW, hwnd, msg, wParam, lParam
    ret

ew_new:
    INVOKE GetWindowLongW, hwnd, GWLP_USERDATA
    INVOKE select_begin, eax
    xor  eax, eax
    ret

ew_copy:
    INVOKE GetWindowLongW, hwnd, GWLP_USERDATA
    INVOKE editor_copy, eax
    xor  eax, eax
    ret

ew_save:
    INVOKE GetWindowLongW, hwnd, GWLP_USERDATA
    INVOKE editor_save, eax
    xor  eax, eax
    ret

ew_pen:
    INVOKE editor_set_tool, hwnd, INK_PEN
    xor  eax, eax
    ret

ew_hilite:
    INVOKE editor_set_tool, hwnd, INK_HILITE
    xor  eax, eax
    ret

ew_eraser:
    INVOKE editor_set_tool, hwnd, INK_ERASER
    xor  eax, eax
    ret

ew_undo:
    INVOKE ink_undo
    INVOKE InvalidateRect, hwnd, 0, 0
    xor  eax, eax
    ret

; --- ticket 06: the annotation mouse ---------------------------------------
; Client pixels below the toolbar are Snip pixels, so the only mapping is to
; drop ED_TOOLBAR_H from y. A stroke is drawn live as a preview over the paint
; (ink_preview); the Eraser updates Working as it goes.

ew_down:
    mov  eax, lParam
    movsx ecx, ax
    mov  px, ecx
    shr  eax, 16
    movsx edx, ax
    cmp  edx, ED_TOOLBAR_H
    jl   ew_zero
    sub  edx, ED_TOOLBAR_H
    mov  py, edx

    INVOKE GetDpiForWindow, hwnd
    mov  ed_dpi, eax

    mov  eax, ed_tool
    cmp  eax, INK_ERASER
    je   ew_down_erase

    INVOKE ink_start, eax, px, py, ed_dpi
    test eax, eax
    jz   ew_zero
    mov  ed_drag, ED_DRAG_STROKE
    INVOKE SetCapture, hwnd
    xor  eax, eax
    ret

ew_down_erase:
    mov  ed_drag, ED_DRAG_ERASE
    INVOKE SetCapture, hwnd
    INVOKE ink_erase_begin
    INVOKE ink_erase, px, py, ed_dpi
    INVOKE InvalidateRect, hwnd, 0, 0
    xor  eax, eax
    ret

ew_move:
    cmp  ed_drag, ED_DRAG_NONE
    je   ew_default
    mov  eax, lParam
    movsx ecx, ax
    mov  px, ecx
    shr  eax, 16
    movsx edx, ax
    cmp  edx, ED_TOOLBAR_H
    jl   ew_zero
    sub  edx, ED_TOOLBAR_H
    mov  py, edx

    cmp  ed_drag, ED_DRAG_STROKE
    je   ew_move_stroke
    INVOKE ink_erase, px, py, ed_dpi
    test eax, eax
    jz   ew_zero
    INVOKE InvalidateRect, hwnd, 0, 0
    xor  eax, eax
    ret

ew_move_stroke:
    INVOKE ink_extend, px, py
    INVOKE InvalidateRect, hwnd, 0, 0
    xor  eax, eax
    ret

ew_up:
    cmp  ed_drag, ED_DRAG_STROKE
    je   ew_up_stroke
    cmp  ed_drag, ED_DRAG_ERASE
    je   ew_up_erase
    jmp  ew_default

ew_up_stroke:
    INVOKE ink_end
    mov  ed_drag, ED_DRAG_NONE
    INVOKE ReleaseCapture
    INVOKE InvalidateRect, hwnd, 0, 0
    xor  eax, eax
    ret

ew_up_erase:
    INVOKE ink_erase_end
    mov  ed_drag, ED_DRAG_NONE
    INVOKE ReleaseCapture
    INVOKE InvalidateRect, hwnd, 0, 0
    xor  eax, eax
    ret

; Capture can be lost mid-drag (a system gesture, another window). Commit or
; close what is in flight rather than leaving a dangling stroke.
ew_capturechanged:
    cmp  ed_drag, ED_DRAG_STROKE
    jne  ew_cc_erase
    INVOKE ink_end
    jmp  ew_cc_done
ew_cc_erase:
    cmp  ed_drag, ED_DRAG_ERASE
    jne  ew_cc_done
    INVOKE ink_erase_end
ew_cc_done:
    mov  ed_drag, ED_DRAG_NONE
    xor  eax, eax
    ret

ew_zero:
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
