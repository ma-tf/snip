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
; The window is normal, not topmost, and no menu bar (spec). It is resizable,
; and a Snip larger than its image area is fitted (scaled down, never upscaled)
; rather than clipped - ticket 17. While a Snipping session is live it is hidden
; by select.asm, exactly like the Shell: the topmost Overlay covers it anyway,
; but it is not excluded from capture, so a Selection over it would otherwise
; capture its pixels.
;
; It paints from the Snip's pixels through GDI+, whose image path honours the
; alpha channel, so a free-form cut shows its shape and the transparent region
; reveals the backdrop below the toolbar. A rectangular Snip is opaque, so the
; draw is identical to a blit. (Ticket 03 used a plain BitBlt; free-form, ticket
; 07, needs the alpha here.)
;
; Copy and Save As hand the live Snip to encode.asm; nothing is re-captured. The
; annotations are already in the Working bitmap by then, so Copy and Save carry
; them for free. A failure aborts the operation and reports through err.asm; the
; Editor stays open so the user can retry.
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
editor_view     PROTO STDCALL :DWORD                       ; BOOL editor_view(DWORD hwnd) - compute the fit into ed_*
editor_map      PROTO STDCALL :DWORD, :DWORD, :DWORD       ; BOOL editor_map(hwnd, SDWORD *px, SDWORD *py) - client -> Snip
editor_buffer   PROTO STDCALL :DWORD, :DWORD, :DWORD       ; HDC editor_buffer(HDC ref, DWORD bufW, DWORD bufH) - the paint backbuffer
editor_do_paint PROTO STDCALL :DWORD                       ; void editor_do_paint(DWORD hwnd)
editor_save     PROTO STDCALL :DWORD                       ; void editor_save(App *app)
editor_copy     PROTO STDCALL :DWORD                       ; void editor_copy(App *app)
editor_set_tool PROTO STDCALL :DWORD, :DWORD               ; void editor_set_tool(DWORD hwnd, DWORD tool)
editor_wndproc  PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD

ED_STYLE EQU WS_CAPTION OR WS_SYSMENU OR WS_MINIMIZEBOX OR WS_MAXIMIZEBOX OR WS_THICKFRAME OR WS_CLIPCHILDREN

; The toolbar strip and the minimum client width that fits all seven buttons.
ED_TOOLBAR_H    EQU 32
ED_TOOLBAR_MINW EQU 456

; The smallest image area a user may drag the window down to, so there is always
; somewhere to annotate.
ED_MINIMG_H     EQU 64

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

; Ticket 17 view state. The window is resizable; an oversized Snip is fitted
; into the image area, and the same fit maps the mouse back to Snip pixels.
; ed_userSized latches once the user drags the window, after which a new Snip no
; longer resizes or moves it. WM_SIZE tells a real resize from a spurious one by
; comparing against ed_fitCW/CH, the client size editor_fit last applied, so its
; own MoveWindow and ShowWindow re-showing the window are not mistaken for a user
; drag; ed_fitted ignores create-time sizing.
ed_userSized   DWORD ?
ed_fitted      DWORD ?
ed_fitCW       DWORD ?      ; the client size editor_fit last applied
ed_fitCH       DWORD ?
ed_vx          SDWORD ?     ; the fitted image's client origin ...
ed_vy          SDWORD ?
ed_vw          DWORD ?      ; ... and size, in client pixels
ed_vh          DWORD ?
ed_sw          DWORD ?      ; the Snip's own size, for the fit ratio
ed_sh          DWORD ?
ed_hwndPen     DWORD ?
ed_hwndHilite  DWORD ?
ed_hwndEraser  DWORD ?

; The paint backbuffer: a client-sized compatible bitmap and DC, rebuilt only
; when the client size changes. The whole frame is drawn here and presented with
; one BitBlt, so a stroke drag never shows a half-painted window.
ed_bufdc       DWORD ?      ; the backbuffer memory DC
ed_bufbm       DWORD ?      ; its bitmap
ed_bufold      DWORD ?      ; what was selected in ed_bufdc before ed_bufbm
ed_bufw        DWORD ?      ; the client size the buffer was built for
ed_bufh        DWORD ?

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
; A failure reports at the point of failure: a clipboard another window holds
; gets its own message, anything else a generic copy failure. Nothing exits.
; ---------------------------------------------------------------------------
editor_copy PROC app:DWORD
    INVOKE dib_snip
    cmp  [eax].Snip.w, 1
    jl   ecp_done
    INVOKE encode_clipboard, eax
    mov  ecx, ERR_COPY
    test eax, eax
    jns  ecp_done
    cmp  eax, CLIPBRD_E_CANT_OPEN
    jne  ecp_show
    mov  ecx, ERR_CLIPBOARD_BUSY
ecp_show:
    mov  eax, app
    mov  eax, [eax].App.hwndEditor
    INVOKE err_show, eax, ecx
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
    jnz  esv_encode

    ; 0 is either a cancel or a dialog error; CommDlgExtendedError tells them
    ; apart. A cancel is silent; a real dialog failure is reported like any save.
    INVOKE CommDlgExtendedError
    test eax, eax
    jz   esv_done
    jmp  esv_fail

esv_encode:
    INVOKE dib_snip
    INVOKE encode_file, eax, OFFSET ed_file
    test eax, eax
    jns  esv_done

esv_fail:
    mov  eax, app
    mov  eax, [eax].App.hwndEditor
    INVOKE err_show, eax, ERR_SAVE

esv_done:
    ret
editor_save ENDP

; ---------------------------------------------------------------------------
; editor_fit(App *app, DWORD hwnd) - size the Editor's client area to the Snip
; and place it on the Snip's monitor - but only until the user resizes the
; window. After that the user owns the size and position, and a new Snip only
; changes the image: editor_view fits the new Snip into whatever the window is.
;
; A Snip larger than the work area still opens capped to the work area; the fit
; then scales it down so the whole image is visible (no pan; the scale is a
; view, not a change to the Snip Copy/Save publish).
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

    ; Once the user has resized the window, they own its size and position; a new
    ; Snip changes only the image, which editor_view fits on demand.
    cmp  ed_userSized, 0
    jne  ef_done

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
    ; Record the client size before moving, so the WM_SIZE it sends is not read
    ; as a user resize; and mark the window as fitted, so create-time sizing is
    ; ignored from here on.
    mov  eax, winW
    mov  ed_fitCW, eax
    mov  eax, winH
    mov  ed_fitCH, eax
    mov  ed_fitted, 1
    INVOKE MoveWindow, hwnd, posX, posY, outW, outH, 1

ef_done:
    ret
editor_fit ENDP

; ---------------------------------------------------------------------------
; editor_view(DWORD hwnd) -> BOOL in eax. Compute how the Snip is placed in the
; image area (client less the toolbar) and cache it in ed_vx/vy/vw/vh plus the
; Snip's own ed_sw/sh. The scale is the smaller of the two axis ratios, capped at
; 100% so a Snip that fits is never upscaled, and the image is centred. Paint,
; input, and the ink preview all read this, so they cannot disagree.
;
; Recomputing on demand is deliberate: the view depends on both the client size
; and the live Snip, and both change without a single event to hook (a new Snip
; arrives through editor_fit, a resize through WM_SIZE).
; ---------------------------------------------------------------------------
editor_view PROC USES ebx esi hwnd:DWORD
    LOCAL rc:RECT
    LOCAL cw:DWORD
    LOCAL imgH:DWORD
    LOCAL vw:DWORD
    LOCAL vh:DWORD

    INVOKE GetClientRect, hwnd, ADDR rc
    mov  eax, rc.right
    sub  eax, rc.left
    mov  cw, eax
    mov  eax, rc.bottom
    sub  eax, rc.top
    sub  eax, ED_TOOLBAR_H
    mov  imgH, eax

    INVOKE dib_snip
    mov  esi, eax
    mov  eax, [esi].Snip.w
    cmp  eax, 1
    jl   ev_no
    mov  ed_sw, eax
    mov  eax, [esi].Snip.h
    cmp  eax, 1
    jl   ev_no
    mov  ed_sh, eax

    cmp  cw, 1
    jl   ev_no
    cmp  imgH, 1
    jl   ev_no

    ; Fits? then 100%, never upscaled.
    mov  eax, ed_sw
    cmp  cw, eax
    jl   ev_scale
    mov  eax, ed_sh
    cmp  imgH, eax
    jl   ev_scale
    mov  eax, ed_sw
    mov  vw, eax
    mov  eax, ed_sh
    mov  vh, eax
    jmp  ev_place

ev_scale:
    ; The limiting axis: width fits better than height when cw/sh <= imgH/sw.
    mov  eax, cw
    imul eax, ed_sh
    mov  edx, imgH
    imul edx, ed_sw
    cmp  eax, edx
    jg   ev_height
    ; width-limited: the full width, the height follows
    mov  eax, cw
    mov  vw, eax
    INVOKE MulDiv, ed_sh, cw, ed_sw
    mov  vh, eax
    jmp  ev_clamp
ev_height:
    ; height-limited: the full height, the width follows
    mov  eax, imgH
    mov  vh, eax
    INVOKE MulDiv, ed_sw, imgH, ed_sh
    mov  vw, eax

ev_clamp:
    cmp  vw, 1
    jge  ev_clamp2
    mov  vw, 1
ev_clamp2:
    cmp  vh, 1
    jge  ev_place
    mov  vh, 1

ev_place:
    ; centre the image in the image area
    mov  eax, cw
    sub  eax, vw
    shr  eax, 1
    mov  ed_vx, eax
    mov  eax, imgH
    sub  eax, vh
    shr  eax, 1
    add  eax, ED_TOOLBAR_H
    mov  ed_vy, eax
    mov  eax, vw
    mov  ed_vw, eax
    mov  eax, vh
    mov  ed_vh, eax
    mov  eax, 1
    ret

ev_no:
    mov  ed_vw, 0
    mov  ed_vh, 0
    xor  eax, eax
    ret
editor_view ENDP

; ---------------------------------------------------------------------------
; editor_map(DWORD hwnd, SDWORD *px, SDWORD *py) -> BOOL in eax.
; Map a client point to Snip pixels through the current fit, in place. The result
; is clamped to the Snip, and the return says whether the point was actually
; inside the image - so a press in the letterbox is rejected while a drag that
; leaves the image still extends to its edge.
; ---------------------------------------------------------------------------
editor_map PROC USES ebx esi edi hwnd:DWORD, ppx:DWORD, ppy:DWORD
    LOCAL inside:DWORD

    mov  inside, 1
    INVOKE editor_view, hwnd
    test eax, eax
    jz   em_no

    mov  ebx, ppx
    mov  esi, ppy

    ; x
    mov  eax, [ebx]
    sub  eax, ed_vx
    jns  em_xhi
    xor  eax, eax
    mov  inside, 0
    jmp  em_xok
em_xhi:
    cmp  eax, ed_vw
    jl   em_xok
    mov  eax, ed_vw
    dec  eax
    mov  inside, 0
em_xok:
    INVOKE MulDiv, eax, ed_sw, ed_vw
    mov  [ebx], eax

    ; y
    mov  eax, [esi]
    sub  eax, ed_vy
    jns  em_yhi
    xor  eax, eax
    mov  inside, 0
    jmp  em_yok
em_yhi:
    cmp  eax, ed_vh
    jl   em_yok
    mov  eax, ed_vh
    dec  eax
    mov  inside, 0
em_yok:
    INVOKE MulDiv, eax, ed_sh, ed_vh
    mov  [esi], eax

    mov  eax, inside
    ret
em_no:
    xor  eax, eax
    ret
editor_map ENDP

; ---------------------------------------------------------------------------
; editor_buffer(HDC ref, DWORD bufW, DWORD bufH) -> HDC in eax, or 0.
; The paint backbuffer: a compatible DC holding a client-sized bitmap, cached
; across paints and rebuilt only when the client size changes. Drawing the whole
; frame here and BitBlt-ing it once is what stops the flicker a stroke drag
; would otherwise show; the same present-once discipline the Overlay uses.
; ---------------------------------------------------------------------------
editor_buffer PROC USES ebx esi edi ref:DWORD, bufW:DWORD, bufH:DWORD
    cmp  bufW, 1
    jl   eb_no
    cmp  bufH, 1
    jl   eb_no

    ; Already the right size? then reuse it.
    mov  eax, ed_bufdc
    test eax, eax
    jz   eb_build
    mov  eax, ed_bufw
    cmp  eax, bufW
    jne  eb_drop
    mov  eax, ed_bufh
    cmp  eax, bufH
    je   eb_have

eb_drop:
    ; Select the original bitmap back before deleting the backbuffer's, then
    ; destroy both and rebuild.
    INVOKE SelectObject, ed_bufdc, ed_bufold
    INVOKE DeleteObject, ed_bufbm
    INVOKE DeleteDC, ed_bufdc
    mov  ed_bufdc, 0
    mov  ed_bufbm, 0

eb_build:
    INVOKE CreateCompatibleDC, ref
    mov  ed_bufdc, eax
    test eax, eax
    jz   eb_no

    INVOKE CreateCompatibleBitmap, ref, bufW, bufH
    mov  ed_bufbm, eax
    test eax, eax
    jz   eb_no

    INVOKE SelectObject, ed_bufdc, ed_bufbm
    mov  ed_bufold, eax
    mov  eax, bufW
    mov  ed_bufw, eax
    mov  eax, bufH
    mov  ed_bufh, eax

eb_have:
    mov  eax, ed_bufdc
    ret
eb_no:
    xor  eax, eax
    ret
editor_buffer ENDP

; ---------------------------------------------------------------------------
; editor_do_paint(DWORD hwnd) - draw the Snip fitted into the image area, then
; overdraw the in-progress stroke at the same scale. A Snip that fits draws 1:1;
; a larger one is scaled down so the whole image is visible, with no pan.
; ---------------------------------------------------------------------------
editor_do_paint PROC USES ebx esi edi hwnd:DWORD
    LOCAL ps:PAINTSTRUCT
    LOCAL rc:RECT
    LOCAL srcW:DWORD
    LOCAL srcH:DWORD
    LOCAL bits:DWORD
    LOCAL bmp:DWORD
    LOCAL gfx:DWORD
    LOCAL stride:DWORD
    LOCAL memdc:DWORD
    LOCAL clientW:DWORD
    LOCAL clientH:DWORD

    INVOKE BeginPaint, hwnd, ADDR ps
    mov  esi, eax                    ; the paint DC

    ; Draw the whole frame into a client-sized backbuffer and present it with one
    ; BitBlt. Painting the toolbar, the backdrop, the image, and the live stroke
    ; straight to the window shows intermediate frames - the flicker. If no
    ; buffer can be built, fall back to painting the window DC directly.
    INVOKE GetClientRect, hwnd, ADDR rc
    mov  eax, rc.right
    sub  eax, rc.left
    mov  clientW, eax
    mov  eax, rc.bottom
    sub  eax, rc.top
    mov  clientH, eax

    INVOKE editor_buffer, esi, clientW, clientH
    test eax, eax
    jnz  ep_have
    mov  eax, esi
ep_have:
    mov  memdc, eax

    ; The toolbar strip behind the buttons. WM_ERASEBKGND is suppressed, so
    ; this is what paints the gaps between the controls.
    INVOKE GetClientRect, hwnd, ADDR rc
    mov  rc.bottom, ED_TOOLBAR_H
    INVOKE FillRect, memdc, ADDR rc, COLOR_BTNFACE_1

    ; Everything below the toolbar is the Snip's backdrop. A free-form Snip is
    ; not opaque, so the transparent region must reveal a defined colour rather
    ; than stale pixels.
    INVOKE GetClientRect, hwnd, ADDR rc
    mov  rc.top, ED_TOOLBAR_H
    INVOKE FillRect, memdc, ADDR rc, COLOR_WINDOW_1

    INVOKE dib_snip
    mov  ebx, eax
    mov  eax, [ebx].Snip.bits
    mov  bits, eax
    mov  eax, [ebx].Snip.w
    mov  srcW, eax
    mov  eax, [ebx].Snip.h
    mov  srcH, eax

    cmp  bits, 0
    jz   ep_present
    cmp  srcW, 1
    jl   ep_present
    cmp  srcH, 1
    jl   ep_present

    ; The fit is the single source of truth for where the image sits and how big
    ; it is drawn. If there is no view there is nothing to draw.
    INVOKE editor_view, hwnd
    test eax, eax
    jz   ep_present

    ; Draw the Snip through GDI+, whose image path honours the alpha channel.
    ; BitBlt would paint a free-form cut as a full rectangle. A fitted Snip is
    ; drawn into the view rect, so it scales instead of clipping.
    mov  bmp, 0
    mov  gfx, 0
    mov  eax, srcW
    shl  eax, 2
    mov  stride, eax
    INVOKE GdipCreateBitmapFromScan0, srcW, srcH, stride, PixelFormat32bppARGB, bits, ADDR bmp
    test eax, eax
    jnz  ep_preview
    INVOKE GdipCreateFromHDC, memdc, ADDR gfx
    test eax, eax
    jnz  ep_dispose

    ; 1:1 needs no filter; a downscale wants a real one.
    mov  eax, ed_vw
    cmp  eax, srcW
    je   ep_draw
    INVOKE GdipSetInterpolationMode, gfx, InterpolationModeHighQualityBicubic
ep_draw:
    INVOKE GdipDrawImageRectI, gfx, bmp, ed_vx, ed_vy, ed_vw, ed_vh

ep_dispose:
    cmp  gfx, 0
    jz   ep_bmp
    INVOKE GdipDeleteGraphics, gfx
ep_bmp:
    cmp  bmp, 0
    jz   ep_preview
    INVOKE GdipDisposeImage, bmp

ep_preview:
    ; The in-progress stroke goes straight onto the buffer, not Working, so a
    ; translucent Highlighter is not double-blended across its own drag frames.
    ; It is scaled to the same view as the image.
    INVOKE ink_preview, memdc, ed_vx, ed_vy, ed_vw, ed_vh, srcW, srcH

ep_present:
    ; Present the finished frame in one blit - unless there was no buffer, in
    ; which case memdc is the window DC and it is already on screen.
    cmp  memdc, esi
    je   ep_done
    INVOKE BitBlt, esi, 0, 0, clientW, clientH, memdc, 0, 0, SRCCOPY

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
    LOCAL rc:RECT

    mov  eax, msg
    cmp  eax, WM_CREATE
    je   ew_create
    cmp  eax, WM_SIZE
    je   ew_size
    cmp  eax, WM_GETMINMAXINFO
    je   ew_minmax
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

; The window was resized. A real user resize latches ed_userSized, so later Snips
; leave the size alone; a WM_SIZE that merely echoes the size editor_fit applied
; (its own MoveWindow, or ShowWindow re-showing the window) is ignored, as is
; create-time sizing. Either way, repaint.
ew_size:
    cmp  wParam, SIZE_MINIMIZED
    je   ew_size_paint
    cmp  ed_fitted, 0
    je   ew_size_paint
    mov  eax, lParam
    movzx ecx, ax                  ; new client width
    cmp  ecx, ed_fitCW
    jne  ew_size_latch
    shr  eax, 16
    movzx ecx, ax                  ; new client height
    cmp  ecx, ed_fitCH
    je   ew_size_paint
ew_size_latch:
    mov  ed_userSized, 1
ew_size_paint:
    INVOKE InvalidateRect, hwnd, 0, 0
    xor  eax, eax
    ret

; Ask DefWindowProc for the normal limits first, then raise the minimum so the
; window cannot be dragged below the toolbar and a strip of image area.
ew_minmax:
    INVOKE DefWindowProcW, hwnd, WM_GETMINMAXINFO, 0, lParam
    mov  rc.left, 0
    mov  rc.top, 0
    mov  rc.right, ED_TOOLBAR_MINW
    mov  eax, ED_TOOLBAR_H
    add  eax, ED_MINIMG_H
    mov  rc.bottom, eax
    INVOKE AdjustWindowRect, ADDR rc, ED_STYLE, 0
    mov  eax, lParam
    mov  ecx, rc.right
    sub  ecx, rc.left
    mov  [eax].MINMAXINFO.ptMinTrackSize.x, ecx
    mov  ecx, rc.bottom
    sub  ecx, rc.top
    mov  [eax].MINMAXINFO.ptMinTrackSize.y, ecx
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
    mov  py, edx

    ; client -> Snip through the current fit; a press in the letterbox is ignored.
    INVOKE editor_map, hwnd, ADDR px, ADDR py
    test eax, eax
    jz   ew_zero

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
    mov  py, edx

    ; Clamp through the fit; the return is ignored so a drag off the image still
    ; extends to its edge.
    INVOKE editor_map, hwnd, ADDR px, ADDR py

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
