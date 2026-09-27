; overlay.asm
; The Overlay window: the dimmed surface a Selection is marked on.
;
; One top-level window spanning the virtual screen, presented with
; UpdateLayeredWindow from a premultiplied 32bpp DIB it owns. That is the whole
; point of this module: per-window alpha (SetLayeredWindowAttributes) makes an
; opaque readout impossible - the plate composites grey and its text washes
; out - which is what the ticket 07 prototype measured. UpdateLayeredWindow
; takes per-pixel alpha, so the dim is written at 128 and the chrome at 255.
;
; This module is a *surface*. It does not own the Selection and does not
; interpret the mouse: select.asm does, and calls overlay_repaint with the
; Selection to draw. The dependency runs one way, select -> overlay.
;
; The Overlay excludes itself from capture, so the dim and chrome never appear
; in a snip. It spans the virtual screen, including monitors at negative
; origins; nothing here assumes 96 DPI or that (0,0) is the desktop's corner.
;
; See docs/overlay.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC overlay_show
PUBLIC overlay_hide
PUBLIC overlay_repaint
PUBLIC overlay_repaint_free
PUBLIC overlay_set_dpi

; Forward declarations so INVOKE reaches them.
ovl_register    PROTO STDCALL :DWORD          ; BOOL ovl_register(App *app)
ovl_present     PROTO STDCALL :DWORD, :DWORD, :DWORD  ; void ovl_present(App *app, Rect *sel, DWORD down)
ovl_present_free PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD  ; void ovl_present_free(App *app, Pt *pts, DWORD n, Rect *bbox)
ovl_commit      PROTO STDCALL :DWORD          ; void ovl_commit(DWORD hwnd) - UpdateLayeredWindow the finished frame
ovl_ensure_dib  PROTO STDCALL :DWORD          ; BOOL ovl_ensure_dib(App *app)
ovl_free_dib    PROTO STDCALL                 ; void ovl_free_dib(void)
ovl_fill_dim    PROTO STDCALL                 ; void ovl_fill_dim(void)
ovl_clear_rect  PROTO STDCALL :DWORD          ; void ovl_clear_rect(Rect *sel)
ovl_outline     PROTO STDCALL :DWORD          ; void ovl_outline(Rect *sel)
ovl_readout     PROTO STDCALL :DWORD          ; void ovl_readout(Rect *sel)
ovl_trace       PROTO STDCALL :DWORD, :DWORD  ; void ovl_trace(Pt *pts, DWORD n)
ovl_blit_trace  PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD  ; void ovl_blit_trace(src, col, row, w, h)
ovl_wbits       PROTO STDCALL :DWORD          ; DWORD ovl_wbits(DWORD) - int to float bits
ovl_hline       PROTO STDCALL :DWORD, :DWORD, :DWORD  ; void ovl_hline(row, col, span)
ovl_putpx       PROTO STDCALL :DWORD, :DWORD  ; void ovl_putpx(row, col)
ovl_fill_box    PROTO STDCALL :DWORD, :DWORD, :DWORD  ; void ovl_fill_box(bits, w, h)
ovl_blit_opaque PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD  ; void ovl_blit_opaque(src, col, row, w, h)

; ---------------------------------------------------------------------------
; Chrome constants. The dim is a premultiplied black at 50%; the plate is
; premultiplied white text on premultiplied black, fully opaque.
; ---------------------------------------------------------------------------
DIM_ALPHA     EQU 128          ; 0..255, the dim's opacity
DIM_COLOR     EQU 00000000h    ; premultiplied black: 00 00 00 80 -> store 00800000h
PLATE_ALPHA   EQU 255

; The outline is one physical pixel of near-white, opaque.
LINE_COLOR    EQU 00FFFFFFh    ; premultiplied white is itself at alpha 255

; ---------------------------------------------------------------------------
; Statics. The Overlay is a singleton, so its class and its DIB live here.
; Strings and geometry are read-only (.const); handles and buffers are
; zero-initialised (.data?).
; ---------------------------------------------------------------------------
.const
ovl_class     DW 'S','n','i','p','O','v','e','r','l','a','y',0
ovl_title     DW 'S','n','i','p','p','i','n','g',' ','T','o','o','l',0

; "W x H", the live readout. %u is the natural fit for a non-negative size.
fmt_wh        DW '%','u',' ','x',' ','%','u',0

; The readout plate's face; CreateFontW is asked for it at the effective DPI.
face_ui       DW 'S','e','g','o','e',' ','U','I',0

.data?
ovl_app       DWORD ?          ; App *, for the session's duration
ovl_wc        WNDCLASSEXW <>
ovl_bmi       BITMAPINFOHEADER <>
scr_bmi       BITMAPINFOHEADER <>      ; the readout plate's scratch DIB
ovl_dib       DWORD ?          ; HBITMAP: the 32bpp premultiplied presentation DIB
ovl_bits      DWORD ?          ; its pixels, written directly
ovl_dc        DWORD ?          ; the memory DC the DIB is selected into
ovl_scr       DWORD ?          ; the screen DC, held for the DIB's lifetime
ovl_oldbm     DWORD ?          ; what was selected in ovl_dc before the DIB
plate_rc      RECT <>          ; the plate's text rectangle, for DrawTextW
ovl_dpi       DWORD ?          ; the Overlay's effective DPI; chrome is scaled to it
ovl_vx        SDWORD ?         ; virtual-screen origin and size, read once per show
ovl_vy        SDWORD ?
ovl_vw        SDWORD ?
ovl_vh        SDWORD ?
ovl_pts       DWORD 8192*2 DUP(?)  ; bbox-local Trace for the preview stroke

.code

; ---------------------------------------------------------------------------
; overlay_show(App *app, DWORD mode) -> BOOL in eax.
; Read the virtual screen, make the window if needed, size and show it, and
; present the first (dim-only) frame. The mode is accepted for the future
; gestures (tickets 07-09); ticket 02 draws the same chrome for every mode.
; ---------------------------------------------------------------------------
overlay_show PROC USES ebx esi edx app:DWORD, mode:DWORD
    mov  esi, app

    ; --- virtual screen. Metrics may be negative (a monitor left of primary).
    INVOKE GetSystemMetrics, SM_XVIRTUALSCREEN
    mov  ovl_vx, eax
    INVOKE GetSystemMetrics, SM_YVIRTUALSCREEN
    mov  ovl_vy, eax
    INVOKE GetSystemMetrics, SM_CXVIRTUALSCREEN
    mov  ovl_vw, eax
    INVOKE GetSystemMetrics, SM_CYVIRTUALSCREEN
    mov  ovl_vh, eax

    ; --- the window, once. Later sessions reuse it: no window churn.
    mov  eax, [esi].App.hwndOverlay
    test eax, eax
    jnz  os_have

    INVOKE ovl_register, esi
    test eax, eax
    jz   os_fail

    ; WS_EX_LAYERED for UpdateLayeredWindow (mandatory), TOPMOST so it covers
    ; everything, TOOLWINDOW so it stays out of the taskbar and Alt-Tab. WS_POPUP
    ; gives a borderless surface a click can land on.
    mov  edx, [esi].App.hInstance
    INVOKE CreateWindowExW, WS_EX_LAYERED OR WS_EX_TOPMOST OR WS_EX_TOOLWINDOW, OFFSET ovl_class, OFFSET ovl_title, WS_POPUP, ovl_vx, ovl_vy, ovl_vw, ovl_vh, 0, 0, edx, esi
    test eax, eax
    jz   os_fail
    mov  [esi].App.hwndOverlay, eax

    ; Self-exclusion from capture: the dim must never be in the snip. Set once;
    ; it is a property of the window, not of a frame.
    INVOKE SetWindowDisplayAffinity, eax, WDA_EXCLUDEFROMCAPTURE

os_have:
    ; The window may need repositioning: monitors come and go between sessions.
    mov  ebx, [esi].App.hwndOverlay

    ; The effective DPI scales the chrome. Read it fresh every show (never cached
    ; from startup), so a monitor or scale change is picked up. 0 means the OS is
    ; too old for GetDpiForWindow; keep the last value or fall back to 96.
    INVOKE GetDpiForWindow, ebx
    test eax, eax
    jz   os_dpi_ok
    mov  ovl_dpi, eax
os_dpi_ok:
    INVOKE MoveWindow, ebx, ovl_vx, ovl_vy, ovl_vw, ovl_vh, 1

    ; The presentation DIB is sized to the virtual screen, so a topology change
    ; means rebuilding it. ovl_present does that lazily on size mismatch.
    INVOKE ovl_present, esi, 0, 0

    INVOKE ShowWindow, ebx, SW_SHOW
    INVOKE SetForegroundWindow, ebx
    INVOKE SetFocus, ebx

    mov  eax, 1
    ret

os_fail:
    xor  eax, eax
    ret
overlay_show ENDP

; ---------------------------------------------------------------------------
; overlay_hide(App *app) - take the Overlay down. The window and its DIB stay
; for the next session; only visibility changes.
; ---------------------------------------------------------------------------
overlay_hide PROC app:DWORD
    mov  eax, app
    mov  eax, [eax].App.hwndOverlay
    test eax, eax
    jz   oh_done
    INVOKE ShowWindow, eax, SW_HIDE
oh_done:
    ret
overlay_hide ENDP

; ---------------------------------------------------------------------------
; overlay_set_dpi(DWORD dpi) - record a new effective DPI from WM_DPICHANGED.
; The chrome is scaled when it is next drawn (sel calls overlay_repaint), so
; this is just bookkeeping. 0 falls back to 96 so the scale maths is never 0.
; ---------------------------------------------------------------------------
overlay_set_dpi PROC dpi:DWORD
    mov  eax, dpi
    test eax, eax
    jnz  osd_ok
    mov  eax, 96
osd_ok:
    mov  ovl_dpi, eax
    ret
overlay_set_dpi ENDP

; ---------------------------------------------------------------------------
; overlay_repaint(App *app, Rect *sel, DWORD down) - redraw and present one
; frame. Called on every mouse move while dragging, and once on show.
; down==0 with a zero-size rect presents the bare dim.
; ---------------------------------------------------------------------------
overlay_repaint PROC app:DWORD, sel:DWORD, down:DWORD
    INVOKE ovl_present, app, sel, down
    ret
overlay_repaint ENDP

; ---------------------------------------------------------------------------
; overlay_repaint_free(App *app, Pt *pts, DWORD n, Rect *bbox) - redraw and
; present one free-form frame: the dim, the live Trace stroked antialiased, and
; the readout naming the bbox. There is no rectangular hole or outline; the
; Trace is the marker. Called on every accepted point during the drag.
; ---------------------------------------------------------------------------
overlay_repaint_free PROC app:DWORD, pts:DWORD, n:DWORD, bbox:DWORD
    INVOKE ovl_present_free, app, pts, n, bbox
    ret
overlay_repaint_free ENDP

; ---------------------------------------------------------------------------
; ovl_register(App *app) -> BOOL in eax. Register the Overlay class once.
; The cursor is the crosshair a selection is drawn with.
; ---------------------------------------------------------------------------
ovl_register PROC app:DWORD
    mov  eax, app
    mov  eax, [eax].App.hInstance

    mov  ovl_wc.cbSize, SIZEOF WNDCLASSEXW
    mov  ovl_wc.style, CS_HREDRAW OR CS_VREDRAW
    mov  ovl_wc.lpfnWndProc, OFFSET sel_wndproc
    mov  ovl_wc.cbClsExtra, 0
    mov  ovl_wc.cbWndExtra, 0
    mov  ovl_wc.hInstance, eax
    mov  ovl_wc.hbrBackground, 0      ; we paint every pixel ourselves

    INVOKE LoadCursorW, 0, IDC_CROSS
    mov  ovl_wc.hCursor, eax

    mov  ovl_wc.lpszClassName, OFFSET ovl_class

    INVOKE RegisterClassExW, OFFSET ovl_wc
    test eax, eax
    jz   or_fail
    mov  eax, 1
    ret
or_fail:
    xor  eax, eax
    ret
ovl_register ENDP

; ---------------------------------------------------------------------------
; ovl_present(App *app, Rect *sel, DWORD down) - draw one frame into the
; presentation DIB and hand it to UpdateLayeredWindow.
;
; The DIB is 32bpp BGRA but PREMULTIPLIED, because that is what DWM composites
; (AC_SRC_ALPHA). Every pixel we write is premultiplied by hand: for an opaque
; pixel alpha 255 leaves the colour alone, for the dim at alpha 128 black is
; black either way. That is why the dim and the chrome can be written straight
; into ovl_bits with no blending pass.
; ---------------------------------------------------------------------------
ovl_present PROC USES ebx esi edi app:DWORD, sel:DWORD, down:DWORD
    mov  esi, app
    mov  edi, [esi].App.hwndOverlay
    test edi, edi
    jz   op_done

    ; --- (re)build the DIB if it does not match the virtual screen ----------
    INVOKE ovl_ensure_dib, esi
    test eax, eax
    jz   op_done

    ; --- 1. the dim: every pixel premultiplied black at DIM_ALPHA ------------
    INVOKE ovl_fill_dim

    ; --- 2. the Selection is punched through the dim ------------------------
    mov  ebx, sel
    test ebx, ebx
    jz   op_chrome
    INVOKE geo_width, ebx
    cmp  eax, 0
    jle  op_chrome
    INVOKE geo_height, ebx
    cmp  eax, 0
    jle  op_chrome

    ; Punch the hole: clearing alpha to 0 makes the desktop show through
    ; undimmed. The DIB is premultiplied, so color and alpha both go to 0.
    INVOKE ovl_clear_rect, ebx

    ; Outline the hole in opaque white so the Selection reads on any desktop.
    INVOKE ovl_outline, ebx

    ; --- 3. the readout plate ---------------------------------------------
    INVOKE ovl_readout, ebx

op_chrome:
    ; --- 4. present the finished frame, once ------------------------------
    INVOKE ovl_commit, edi
op_done:
    ret
ovl_present ENDP

; ---------------------------------------------------------------------------
; ovl_present_free(App *app, Pt *pts, DWORD n, Rect *bbox) - a free-form frame:
; the dim, the live Trace stroked antialiased, then the readout. Same present as
; ovl_present; only the middle differs.
; ---------------------------------------------------------------------------
ovl_present_free PROC USES ebx esi edi app:DWORD, pts:DWORD, n:DWORD, bbox:DWORD
    mov  esi, app
    mov  edi, [esi].App.hwndOverlay
    test edi, edi
    jz   pf_done

    INVOKE ovl_ensure_dib, esi
    test eax, eax
    jz   pf_done

    INVOKE ovl_fill_dim

    mov  eax, n
    cmp  eax, 2
    jl   pf_readout
    INVOKE ovl_trace, pts, n
pf_readout:
    mov  ebx, bbox
    test ebx, ebx
    jz   pf_commit
    INVOKE geo_width, ebx
    cmp  eax, 0
    jle  pf_commit
    INVOKE geo_height, ebx
    cmp  eax, 0
    jle  pf_commit
    INVOKE ovl_readout, ebx
pf_commit:
    INVOKE ovl_commit, edi
pf_done:
    ret
ovl_present_free ENDP

; ---------------------------------------------------------------------------
; ovl_commit(DWORD hwnd) - hand the finished DIB to UpdateLayeredWindow, once.
; DWM never sees a half-drawn frame; present-once is what stops the flicker. dst
; is in screen coordinates, so a negative virtual origin is honoured.
; ---------------------------------------------------------------------------
ovl_commit PROC USES edi hwnd:DWORD
    LOCAL src:POINT
    LOCAL sz:SIZEW
    LOCAL dst:POINT
    LOCAL blend:BLENDFUNCTION
    LOCAL hdcWin:DWORD

    mov  edi, hwnd
    mov  src.x, 0
    mov  src.y, 0
    mov  eax, ovl_vw
    mov  sz._cx, eax
    mov  eax, ovl_vh
    mov  sz._cy, eax
    mov  eax, ovl_vx
    mov  dst.x, eax
    mov  eax, ovl_vy
    mov  dst.y, eax

    mov  blend.BlendOp, AC_SRC_OVER
    mov  blend.BlendFlags, 0
    mov  blend.SourceConstantAlpha, 255   ; per-pixel alpha is in the DIB
    mov  blend.AlphaFormat, AC_SRC_ALPHA

    INVOKE GetDC, 0
    mov  hdcWin, eax
    INVOKE UpdateLayeredWindow, edi, hdcWin, ADDR dst, ADDR sz, ovl_dc, ADDR src, 0, ADDR blend, ULW_ALPHA
    INVOKE ReleaseDC, 0, hdcWin
    ret
ovl_commit ENDP

; ---------------------------------------------------------------------------
; ovl_ensure_dib(App *app) -> BOOL in eax. Create the screen-DC, the memory DC,
; and the DIB sized to the virtual screen, rebuilding if the size changed (a
; monitor was added or removed between sessions).
; ---------------------------------------------------------------------------
ovl_ensure_dib PROC app:DWORD
    ; already the right size? then nothing to do.
    mov  eax, ovl_dib
    test eax, eax
    jz   oed_build
    mov  eax, ovl_bmi.biWidth
    cmp  eax, ovl_vw
    jne  oed_drop
    mov  eax, ovl_bmi.biHeight
    cmp  eax, ovl_vh
    je   oed_ok

oed_drop:
    INVOKE ovl_free_dib

oed_build:
    ; screen DC, held for the DIB's lifetime
    INVOKE GetDC, 0
    mov  ovl_scr, eax
    INVOKE CreateCompatibleDC, eax
    mov  ovl_dc, eax

    ; a 32bpp top-down DIB section: we write its pixels directly, so we need
    ; the bits pointer, not a compatible bitmap
    mov  ovl_bmi.biSize, SIZEOF BITMAPINFOHEADER
    mov  eax, ovl_vw
    mov  ovl_bmi.biWidth, eax
    mov  eax, ovl_vh
    neg  eax                          ; top-down: row 0 is the top row
    mov  ovl_bmi.biHeight, eax
    mov  ovl_bmi.biPlanes, 1
    mov  ovl_bmi.biBitCount, 32
    mov  ovl_bmi.biCompression, BI_RGB
    mov  ovl_bmi.biSizeImage, 0
    mov  ovl_bmi.biXPelsPerMeter, 0
    mov  ovl_bmi.biYPelsPerMeter, 0
    mov  ovl_bmi.biClrUsed, 0
    mov  ovl_bmi.biClrImportant, 0

    INVOKE CreateDIBSection, ovl_scr, OFFSET ovl_bmi, DIB_RGB_COLORS, ADDR ovl_bits, 0, 0
    mov  ovl_dib, eax
    test eax, eax
    jz   oed_fail

    INVOKE SelectObject, ovl_dc, ovl_dib
    mov  ovl_oldbm, eax

oed_ok:
    mov  eax, 1
    ret
oed_fail:
    xor  eax, eax
    ret
ovl_ensure_dib ENDP

; ---------------------------------------------------------------------------
; ovl_free_dib - release the DIB and its DCs. Safe to call when nothing exists.
; ---------------------------------------------------------------------------
ovl_free_dib PROC
    cmp  ovl_dc, 0
    jz   ofd_scr
    cmp  ovl_oldbm, 0
    jz   ofd_bmp
    INVOKE SelectObject, ovl_dc, ovl_oldbm
    mov  ovl_oldbm, 0
ofd_bmp:
    cmp  ovl_dib, 0
    jz   ofd_dc
    INVOKE DeleteObject, ovl_dib
    mov  ovl_dib, 0
ofd_dc:
    INVOKE DeleteDC, ovl_dc
    mov  ovl_dc, 0
ofd_scr:
    cmp  ovl_scr, 0
    jz   ofd_done
    INVOKE ReleaseDC, 0, ovl_scr
    mov  ovl_scr, 0
ofd_done:
    ret
ovl_free_dib ENDP

; ---------------------------------------------------------------------------
; ovl_fill_dim - write every pixel of the DIB as premultiplied black at
; DIM_ALPHA. Premultiplied, black is 0 either way, so the only byte that
; matters is alpha; the colour bytes stay 0.
; ---------------------------------------------------------------------------
ovl_fill_dim PROC USES edi ecx eax
    mov  edi, ovl_bits
    test edi, edi
    jz   ofd_done

    mov  eax, ovl_vw
    imul eax, ovl_vh                  ; total pixels
    test eax, eax
    jle  ofd_done
    mov  ecx, eax

    ; BGRA, little-endian: byte 3 is alpha. Premultiplied black = 00 00 00 80.
    mov  edx, (DIM_ALPHA SHL 24)      ; 0x80000000
ofd_loop:
    mov  [edi], edx
    add  edi, 4
    dec  ecx
    jnz  ofd_loop
ofd_done:
    ret
ovl_fill_dim ENDP

; ---------------------------------------------------------------------------
; ovl_clear_rect(Rect *sel) - punch the Selection out of the dim: zero the
; pixels so DWM composites the undimmed desktop through. The Rect is in
; virtual-screen pixels, and the DIB's origin is the virtual-screen origin, so
; no translation is needed. Rows and columns are clamped to the DIB.
; ---------------------------------------------------------------------------
ovl_clear_rect PROC USES ebx esi edi edx ecx sel:DWORD
    LOCAL rowTop:DWORD
    LOCAL rowBot:DWORD
    LOCAL colL:DWORD
    LOCAL colR:DWORD
    LOCAL span:DWORD

    mov  ebx, sel
    mov  esi, ovl_bits
    test esi, esi
    jz   ocr_done

    ; --- clamp the rectangle to the DIB -------------------------------------
    mov  eax, [ebx].Rect.top
    cmp  eax, 0
    jge  ocr_top_ok
    xor  eax, eax
ocr_top_ok:
    mov  rowTop, eax

    mov  eax, [ebx].Rect.bottom
    cmp  eax, ovl_vh
    jle  ocr_bot_ok
    mov  eax, ovl_vh
ocr_bot_ok:
    mov  rowBot, eax

    mov  eax, [ebx].Rect.left
    cmp  eax, 0
    jge  ocr_l_ok
    xor  eax, eax
ocr_l_ok:
    mov  colL, eax

    mov  eax, [ebx].Rect.right
    cmp  eax, ovl_vw
    jle  ocr_r_ok
    mov  eax, ovl_vw
ocr_r_ok:
    mov  colR, eax

    ; nothing to do if the box is empty after clamping
    mov  eax, rowBot
    sub  eax, rowTop
    jle  ocr_done
    mov  eax, colR
    sub  eax, colL
    jle  ocr_done
    mov  span, eax

    ; --- zero each row's span ----------------------------------------------
    mov  edx, rowTop
ocr_row:
    ; edi = bits + (row * width + colL) * 4
    mov  eax, edx
    imul eax, ovl_vw
    add  eax, colL
    lea  edi, [esi + eax*4]

    mov  ecx, span
    xor  eax, eax
    rep  stosd                       ; write 0 (premultiplied transparent)

    inc  edx
    cmp  edx, rowBot
    jl   ocr_row

ocr_done:
    ret
ovl_clear_rect ENDP

; ---------------------------------------------------------------------------
; ovl_outline(Rect *sel) - draw the Selection's border, one pixel, opaque
; white. Drawn as four one-pixel runs directly into the DIB, so there is no pen
; or DC involved and the outline is exactly on the Selection's edge.
; ---------------------------------------------------------------------------
ovl_outline PROC USES ebx esi edi edx ecx sel:DWORD
    LOCAL colL:DWORD
    LOCAL colR:DWORD
    LOCAL rowT:DWORD
    LOCAL rowB:DWORD
    LOCAL span:DWORD

    mov  ebx, sel
    mov  esi, ovl_bits
    test esi, esi
    jz   oo_done

    mov  eax, [ebx].Rect.left
    mov  colL, eax
    mov  eax, [ebx].Rect.right
    mov  colR, eax
    mov  eax, [ebx].Rect.top
    mov  rowT, eax
    mov  eax, [ebx].Rect.bottom
    mov  rowB, eax

    mov  eax, colR
    sub  eax, colL
    inc  eax                          ; inclusive: the box spans left..right
    mov  span, eax

    ; --- top and bottom rows -------------------------------------------------
    mov  edx, rowT
    INVOKE ovl_hline, edx, colL, span
    mov  edx, rowB
    INVOKE ovl_hline, edx, colL, span

    ; --- left and right columns (between the two rows, exclusive) ------------
    mov  edx, rowT
    inc  edx
    mov  ecx, rowB
oo_col:
    cmp  edx, ecx
    jge  oo_done
    INVOKE ovl_putpx, edx, colL
    INVOKE ovl_putpx, edx, colR
    inc  edx
    jmp  oo_col

oo_done:
    ret
ovl_outline ENDP

; ---------------------------------------------------------------------------
; ovl_trace(Pt *pts, DWORD n) - stroke the live free-form Trace onto the Overlay
; DIB, antialiased, as a dark halo under a light core so it reads on any
; wallpaper.
;
; Drawn into a small transparent scratch bitmap through GDI+ (straight ARGB via
; GdipCreateBitmapFromScan0), then composited into the premultiplied Overlay DIB
; with source-over. Drawing GDI+ straight onto the DIB through a DC is not used:
; GDI+ leaves a DIB surface's alpha unusable, and this DIB *is* alpha. The
; scratch is only as big as the Trace, not the whole virtual screen.
; ---------------------------------------------------------------------------
ovl_trace PROC USES ebx esi edi pts:DWORD, n:DWORD
    LOCAL minx:DWORD
    LOCAL miny:DWORD
    LOCAL maxx:DWORD
    LOCAL maxy:DWORD
    LOCAL x0:DWORD
    LOCAL y0:DWORD
    LOCAL sw:DWORD
    LOCAL sh:DWORD
    LOCAL halo:DWORD
    LOCAL core:DWORD
    LOCAL pad:DWORD
    LOCAL hdib:DWORD
    LOCAL bits:DWORD
    LOCAL bmp:DWORD
    LOCAL gfx:DWORD
    LOCAL pen:DWORD
    LOCAL wf:DWORD
    LOCAL i:DWORD

    mov  hdib, 0
    mov  bmp, 0
    mov  gfx, 0
    mov  pen, 0

    ; --- bbox of the raw points --------------------------------------------
    mov  esi, pts
    mov  eax, [esi]
    mov  minx, eax
    mov  maxx, eax
    mov  eax, [esi+4]
    mov  miny, eax
    mov  maxy, eax
    mov  i, 1
ot_box:
    mov  eax, i
    cmp  eax, n
    jge  ot_box_done
    shl  eax, 3
    mov  eax, [esi+eax]
    cmp  eax, minx
    jge  ot_b1
    mov  minx, eax
ot_b1:
    cmp  eax, maxx
    jle  ot_b2
    mov  maxx, eax
ot_b2:
    mov  eax, i
    shl  eax, 3
    mov  eax, [esi+eax+4]
    cmp  eax, miny
    jge  ot_b3
    mov  miny, eax
ot_b3:
    cmp  eax, maxy
    jle  ot_b4
    mov  maxy, eax
ot_b4:
    inc  i
    jmp  ot_box
ot_box_done:

    ; --- pen widths, DPI-scaled (at least 1) -------------------------------
    mov  eax, ovl_dpi
    test eax, eax
    jnz  ot_dpi
    mov  eax, 96
ot_dpi:
    INVOKE MulDiv, 3, eax, 96
    cmp  eax, 1
    jge  ot_halo
    mov  eax, 1
ot_halo:
    mov  halo, eax
    mov  eax, halo
    shr  eax, 1
    inc  eax
    mov  pad, eax

    ; --- scratch bounds, clamped to the DIB --------------------------------
    mov  eax, minx
    sub  eax, pad
    cmp  eax, 0
    jge  ot_x0
    xor  eax, eax
ot_x0:
    mov  x0, eax
    mov  eax, miny
    sub  eax, pad
    cmp  eax, 0
    jge  ot_y0
    xor  eax, eax
ot_y0:
    mov  y0, eax

    mov  eax, maxx
    add  eax, 1
    add  eax, pad
    cmp  eax, ovl_vw
    jle  ot_x1
    mov  eax, ovl_vw
ot_x1:
    sub  eax, x0
    mov  sw, eax
    mov  eax, maxy
    add  eax, 1
    add  eax, pad
    cmp  eax, ovl_vh
    jle  ot_y1
    mov  eax, ovl_vh
ot_y1:
    sub  eax, y0
    mov  sh, eax

    cmp  sw, 1
    jl   ot_done
    cmp  sh, 1
    jl   ot_done

    ; --- localize the points into ovl_pts ----------------------------------
    mov  esi, pts
    lea  edi, ovl_pts
    xor  ecx, ecx
ot_loc:
    cmp  ecx, n
    jge  ot_loc_done
    mov  eax, [esi]
    sub  eax, x0
    mov  [edi], eax
    mov  eax, [esi+4]
    sub  eax, y0
    mov  [edi+4], eax
    add  esi, 8
    add  edi, 8
    inc  ecx
    jmp  ot_loc
ot_loc_done:

    ; --- a zeroed scratch bitmap -------------------------------------------
    mov  scr_bmi.biSize, SIZEOF BITMAPINFOHEADER
    mov  eax, sw
    mov  scr_bmi.biWidth, eax
    mov  eax, sh
    neg  eax
    mov  scr_bmi.biHeight, eax
    mov  scr_bmi.biPlanes, 1
    mov  scr_bmi.biBitCount, 32
    mov  scr_bmi.biCompression, BI_RGB
    mov  scr_bmi.biSizeImage, 0
    mov  scr_bmi.biXPelsPerMeter, 0
    mov  scr_bmi.biYPelsPerMeter, 0
    mov  scr_bmi.biClrUsed, 0
    mov  scr_bmi.biClrImportant, 0

    INVOKE CreateDIBSection, ovl_scr, OFFSET scr_bmi, DIB_RGB_COLORS, ADDR bits, 0, 0
    mov  hdib, eax
    test eax, eax
    jz   ot_done
    mov  edi, bits
    mov  ecx, sw
    imul ecx, sh
    xor  eax, eax
    rep  stosd

    ; --- GDI+ the two strokes ----------------------------------------------
    mov  eax, sw
    shl  eax, 2
    mov  wf, eax
    INVOKE GdipCreateBitmapFromScan0, sw, sh, wf, PixelFormat32bppARGB, bits, ADDR bmp
    test eax, eax
    jnz  ot_clean
    INVOKE GdipGetImageGraphicsContext, bmp, ADDR gfx
    test eax, eax
    jnz  ot_clean
    INVOKE GdipSetSmoothingMode, gfx, SmoothingModeAntiAlias

    ; halo: opaque dark, halo px wide
    INVOKE ovl_wbits, halo
    mov  wf, eax
    INVOKE GdipCreatePen1, 0FF000000h, wf, UnitPixel, ADDR pen
    test eax, eax
    jnz  ot_clean
    INVOKE GdipSetPenStartCap, pen, LineCapRound
    INVOKE GdipSetPenEndCap, pen, LineCapRound
    INVOKE GdipSetPenLineJoin, pen, LineJoinRound
    INVOKE GdipDrawLinesI, gfx, pen, OFFSET ovl_pts, n
    INVOKE GdipDeletePen, pen
    mov  pen, 0

    ; core: opaque light, 1px
    INVOKE ovl_wbits, 1
    mov  wf, eax
    INVOKE GdipCreatePen1, 0FFFFFFFFh, wf, UnitPixel, ADDR pen
    test eax, eax
    jnz  ot_clean
    INVOKE GdipSetPenStartCap, pen, LineCapRound
    INVOKE GdipSetPenEndCap, pen, LineCapRound
    INVOKE GdipSetPenLineJoin, pen, LineJoinRound
    INVOKE GdipDrawLinesI, gfx, pen, OFFSET ovl_pts, n
    INVOKE GdipDeletePen, pen
    mov  pen, 0

    INVOKE GdipFlush, gfx, FlushIntentionSync

    ; --- composite the scratch into the overlay DIB ------------------------
    INVOKE ovl_blit_trace, bits, x0, y0, sw, sh

ot_clean:
    cmp  pen, 0
    jz   ot_np
    INVOKE GdipDeletePen, pen
ot_np:
    cmp  gfx, 0
    jz   ot_ng
    INVOKE GdipDeleteGraphics, gfx
ot_ng:
    cmp  bmp, 0
    jz   ot_nb
    INVOKE GdipDisposeImage, bmp
ot_nb:
    cmp  hdib, 0
    jz   ot_done
    INVOKE DeleteObject, hdib

ot_done:
    ret
ovl_trace ENDP

; ---------------------------------------------------------------------------
; ovl_wbits(DWORD) -> the 32 bits of (float)arg in eax. GDI+ takes REAL pen
; widths; this is where the integer becomes one.
; ---------------------------------------------------------------------------
ovl_wbits PROC w:DWORD
    fild dword ptr w
    sub  esp, 4
    fstp dword ptr [esp]
    pop  eax
    ret
ovl_wbits ENDP

; ---------------------------------------------------------------------------
; ovl_blit_trace(src, col, row, w, h) - composite a straight-ARGB scratch DIB
; into the premultiplied overlay DIB with source-over. An opaque pixel is a
; straight move; only the antialiased edge needs the blend. Clipped to the DIB.
; ---------------------------------------------------------------------------
ovl_blit_trace PROC USES ebx esi edi edx ecx src:DWORD, col:DWORD, row:DWORD, w:DWORD, h:DWORD
    LOCAL t_sy:DWORD
    LOCAL t_sx:DWORD
    LOCAL t_dx:DWORD
    LOCAL t_dy:DWORD
    LOCAL t_s:DWORD
    LOCAL t_a:DWORD
    LOCAL t_inv:DWORD
    LOCAL t_out:DWORD

    mov  t_sy, 0
trc_row:
    mov  eax, t_sy
    cmp  eax, h
    jge  trc_done
    mov  eax, row
    add  eax, t_sy
    mov  t_dy, eax
    cmp  eax, 0
    jl   trc_next_row
    cmp  eax, ovl_vh
    jge  trc_done

    mov  t_sx, 0
trc_col:
    mov  eax, t_sx
    cmp  eax, w
    jge  trc_next_row
    mov  eax, col
    add  eax, t_sx
    mov  t_dx, eax
    cmp  eax, 0
    jl   trc_next_col
    cmp  eax, ovl_vw
    jge  trc_next_row

    ; s = src[(sy*w + sx)*4]
    mov  eax, t_sy
    imul eax, w
    add  eax, t_sx
    mov  esi, src
    mov  edx, [esi+eax*4]
    mov  t_s, edx
    mov  eax, edx
    shr  eax, 24
    and  eax, 0FFh
    mov  t_a, eax
    test eax, eax
    jz   trc_next_col
    cmp  eax, 255
    jne  trc_blend

    ; destination pointer
    mov  eax, t_dy
    imul eax, ovl_vw
    add  eax, t_dx
    mov  edi, ovl_bits
    lea  edi, [edi+eax*4]

    ; opaque source: a straight move, already premultiplied
    mov  eax, t_s
    mov  [edi], eax
    jmp  trc_next_col

trc_blend:
    mov  ecx, 255
    sub  ecx, eax
    mov  t_inv, ecx

    ; destination pointer
    mov  eax, t_dy
    imul eax, ovl_vw
    add  eax, t_dx
    mov  edi, ovl_bits
    lea  edi, [edi+eax*4]

    ; --- out red = src.r*a/255 + dst.r*inv/255 ---
    mov  eax, t_s
    and  eax, 000FF0000h
    shr  eax, 16
    imul eax, t_a
    xor  edx, edx
    mov  ecx, 255
    div  ecx
    mov  ebx, eax
    mov  eax, [edi]
    and  eax, 000FF0000h
    shr  eax, 16
    imul eax, t_inv
    xor  edx, edx
    mov  ecx, 255
    div  ecx
    add  ebx, eax
    cmp  ebx, 255
    jle  trc_r
    mov  ebx, 255
trc_r:
    shl  ebx, 16
    mov  t_out, ebx

    ; --- out green ---
    mov  eax, t_s
    and  eax, 00000FF00h
    shr  eax, 8
    imul eax, t_a
    xor  edx, edx
    mov  ecx, 255
    div  ecx
    mov  ebx, eax
    mov  eax, [edi]
    and  eax, 00000FF00h
    shr  eax, 8
    imul eax, t_inv
    xor  edx, edx
    mov  ecx, 255
    div  ecx
    add  ebx, eax
    cmp  ebx, 255
    jle  trc_g
    mov  ebx, 255
trc_g:
    shl  ebx, 8
    or   t_out, ebx

    ; --- out blue ---
    mov  eax, t_s
    and  eax, 0000000FFh
    imul eax, t_a
    xor  edx, edx
    mov  ecx, 255
    div  ecx
    mov  ebx, eax
    mov  eax, [edi]
    and  eax, 0000000FFh
    imul eax, t_inv
    xor  edx, edx
    mov  ecx, 255
    div  ecx
    add  ebx, eax
    cmp  ebx, 255
    jle  trc_b
    mov  ebx, 255
trc_b:
    or   t_out, ebx

    ; --- out alpha = a + dst.a*inv/255 ---
    mov  eax, [edi]
    shr  eax, 24
    and  eax, 0FFh
    imul eax, t_inv
    xor  edx, edx
    mov  ecx, 255
    div  ecx
    add  eax, t_a
    cmp  eax, 255
    jle  trc_a
    mov  eax, 255
trc_a:
    shl  eax, 24
    or   t_out, eax

    mov  eax, t_out
    mov  [edi], eax

trc_next_col:
    inc  t_sx
    jmp  trc_col
trc_next_row:
    inc  t_sy
    jmp  trc_row
trc_done:
    ret
ovl_blit_trace ENDP

; ---------------------------------------------------------------------------
; ovl_hline(row, col, span) - write span opaque pixels on one row. Clipped to
; the DIB; a no-op off-screen or empty.
; ---------------------------------------------------------------------------
ovl_hline PROC USES edi edx ecx row:DWORD, col:DWORD, span:DWORD

    mov  edx, row
    cmp  edx, 0
    jl   oh_done
    cmp  edx, ovl_vh
    jge  oh_done
    mov  ecx, col
    cmp  ecx, 0
    jl   oh_done
    cmp  ecx, ovl_vw
    jge  oh_done

    ; clip the span to the right edge
    mov  eax, ecx
    add  eax, span
    cmp  eax, ovl_vw
    jle  oh_len_ok
    mov  eax, ovl_vw
    sub  eax, ecx
    mov  span, eax
    cmp  span, 0
    jle  oh_done
oh_len_ok:
    mov  eax, edx
    imul eax, ovl_vw
    add  eax, ecx
    mov  edi, ovl_bits
    lea  edi, [edi + eax*4]

    mov  ecx, span
    mov  eax, LINE_COLOR
    or   eax, (PLATE_ALPHA SHL 24)    ; opaque white
    rep  stosd

oh_done:
    ret
ovl_hline ENDP

; ---------------------------------------------------------------------------
; ovl_putpx(row, col) - write one opaque white pixel. Clipped to the DIB.
; ---------------------------------------------------------------------------
ovl_putpx PROC USES edi eax edx row:DWORD, col:DWORD
    mov  eax, row
    cmp  eax, 0
    jl   opp_done
    cmp  eax, ovl_vh
    jge  opp_done
    mov  edx, col
    cmp  edx, 0
    jl   opp_done
    cmp  edx, ovl_vw
    jge  opp_done

    imul eax, ovl_vw
    add  eax, edx
    mov  edi, ovl_bits
    lea  edi, [edi + eax*4]
    mov  eax, LINE_COLOR
    or   eax, (PLATE_ALPHA SHL 24)
    mov  [edi], eax
opp_done:
    ret
ovl_putpx ENDP

; ---------------------------------------------------------------------------
; ovl_readout(Rect *sel) - draw the "W x H" plate at the Selection's top-left
; corner, fully opaque.
;
; This is the chrome the ticket 07 prototype could not draw. The plate is a
; solid opaque black box with white text on it. Both are written into a small
; 32bpp scratch DIB by ordinary GDI (which gives real font rasterisation), then
; copied into the overlay DIB as premultiplied pixels. At alpha 255 the copy is
; a straight move, so the plate and its text stay opaque against any desktop.
; ---------------------------------------------------------------------------
ovl_readout PROC USES ebx esi edi ecx edx sel:DWORD
    LOCAL buf[40]:WORD
    LOCAL hdcScr:DWORD
    LOCAL hdcMem:DWORD
    LOCAL hdib:DWORD
    LOCAL bits:DWORD
    LOCAL oldbm:DWORD
    LOCAL plateL:DWORD
    LOCAL plateT:DWORD
    LOCAL plateW:DWORD
    LOCAL plateH:DWORD
    LOCAL txtW:DWORD
    LOCAL txtH:DWORD
    LOCAL dpi:DWORD
    LOCAL hfont:DWORD
    LOCAL oldfont:DWORD

    mov  ebx, sel
    mov  hfont, 0

    ; wsprintfW(buf, "%u x %u", w, h). The two values are read into locals
    ; first: the C-varargs call sets up its own arguments, so passing live
    ; registers into it is the surest way to swap them.
    INVOKE geo_width, ebx
    mov  txtW, eax
    INVOKE geo_height, ebx
    mov  txtH, eax
    INVOKE wsprintfW, ADDR buf, OFFSET fmt_wh, txtW, txtH

    ; --- chrome scale: 96 DPI is 1.0x, and every chrome dimension follows ------
    mov  eax, ovl_dpi
    test eax, eax
    jnz  or_dpi_ok
    mov  eax, 96
or_dpi_ok:
    mov  dpi, eax

    ; --- plate geometry: 2px in from the Selection's corner, scaled ---------
    INVOKE MulDiv, 2, dpi, 96
    mov  ecx, eax
    mov  eax, [ebx].Rect.left
    add  eax, ecx
    mov  plateL, eax
    INVOKE MulDiv, 2, dpi, 96
    mov  ecx, eax
    mov  eax, [ebx].Rect.top
    add  eax, ecx
    mov  plateT, eax
    INVOKE MulDiv, 84, dpi, 96
    mov  plateW, eax
    INVOKE MulDiv, 22, dpi, 96
    mov  plateH, eax

    ; --- render the plate into a scratch DIB -------------------------------
    INVOKE GetDC, 0
    mov  hdcScr, eax
    INVOKE CreateCompatibleDC, hdcScr
    mov  hdcMem, eax

    mov  scr_bmi.biSize, SIZEOF BITMAPINFOHEADER
    mov  eax, plateW
    mov  scr_bmi.biWidth, eax
    mov  eax, plateH
    neg  eax                              ; top-down
    mov  scr_bmi.biHeight, eax
    mov  scr_bmi.biPlanes, 1
    mov  scr_bmi.biBitCount, 32
    mov  scr_bmi.biCompression, BI_RGB
    mov  scr_bmi.biSizeImage, 0
    mov  scr_bmi.biXPelsPerMeter, 0
    mov  scr_bmi.biYPelsPerMeter, 0
    mov  scr_bmi.biClrUsed, 0
    mov  scr_bmi.biClrImportant, 0

    INVOKE CreateDIBSection, hdcScr, OFFSET scr_bmi, DIB_RGB_COLORS, ADDR bits, 0, 0
    mov  hdib, eax
    INVOKE SelectObject, hdcMem, hdib
    mov  oldbm, eax

    ; opaque black background, then a font built for the effective DPI
    INVOKE ovl_fill_box, bits, plateW, plateH

    ; 9pt at 96 DPI, scaled; CreateFontW height is in pixels and negative means
    ; "character height", not cell height.
    INVOKE MulDiv, 9, dpi, 72
    neg  eax
    INVOKE CreateFontW, eax, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, 0, OFFSET face_ui
    mov  hfont, eax
    test eax, eax
    jz   or_no_font
    INVOKE SelectObject, hdcMem, eax
    mov  oldfont, eax
or_no_font:
    INVOKE SetBkMode, hdcMem, TRANSPARENT_BK
    INVOKE SetTextColor, hdcMem, 0FFFFFFh

    ; the text rectangle: the whole plate, inset by a scaled 4px/3px
    INVOKE MulDiv, 4, dpi, 96
    mov  plate_rc.left, eax
    INVOKE MulDiv, 3, dpi, 96
    mov  plate_rc.top, eax
    mov  eax, plateW
    sub  eax, plate_rc.left
    mov  plate_rc.right, eax
    mov  eax, plateH
    mov  plate_rc.bottom, eax

    INVOKE DrawTextW, hdcMem, ADDR buf, -1, ADDR plate_rc, 0
    ; Flush batched GDI before reading the DIB's memory directly.
    INVOKE GdiFlush

    ; --- copy the plate into the overlay DIB --------------------------------
    INVOKE ovl_blit_opaque, bits, plateL, plateT, plateW, plateH

    ; --- tidy up ------------------------------------------------------------
    cmp  hfont, 0
    jz   or_keep_font
    INVOKE SelectObject, hdcMem, oldfont
    INVOKE DeleteObject, hfont
or_keep_font:
    INVOKE SelectObject, hdcMem, oldbm
    INVOKE DeleteObject, hdib
    INVOKE DeleteDC, hdcMem
    INVOKE ReleaseDC, 0, hdcScr

    ret
ovl_readout ENDP

; ---------------------------------------------------------------------------
; ovl_fill_box(bits, w, h) - fill a 32bpp scratch DIB with opaque black.
; ---------------------------------------------------------------------------
ovl_fill_box PROC USES edi ecx eax bits:DWORD, w:DWORD, h:DWORD
    mov  edi, bits
    mov  eax, w
    imul eax, h
    test eax, eax
    jle  ofb_done
    mov  ecx, eax
    mov  eax, 0FF000000h                  ; premultiplied opaque black
ofb_loop:
    mov  [edi], eax
    add  edi, 4
    dec  ecx
    jnz  ofb_loop
ofb_done:
    ret
ovl_fill_box ENDP

; ---------------------------------------------------------------------------
; ovl_blit_opaque(src, col, row, w, h) - copy a 32bpp scratch DIB into the
; overlay DIB at (col,row) as fully opaque pixels.
;
; GDI does not manage an alpha channel: text drawn into a 32bpp DIB leaves the
; glyph pixels' alpha at whatever was there (usually 0), so a straight copy
; would make the text vanish against the black fill. The plate is opaque chrome
; by design, so every copied pixel gets alpha 255. Clipped to the overlay DIB.
; ---------------------------------------------------------------------------
ovl_blit_opaque PROC USES ebx esi edi edx ecx src:DWORD, col:DWORD, row:DWORD, w:DWORD, h:DWORD
    LOCAL b_sy:DWORD
    LOCAL b_sx:DWORD
    LOCAL b_dy:DWORD
    LOCAL b_dx:DWORD
    LOCAL b_px:DWORD

    mov  b_sy, 0
opb_row:
    mov  eax, b_sy
    cmp  eax, h
    jge  opb_done

    mov  eax, row
    add  eax, b_sy
    mov  b_dy, eax
    cmp  eax, 0
    jl   opb_next_row
    mov  ecx, ovl_vh
    cmp  eax, ecx
    jge  opb_done

    mov  b_sx, 0
opb_col:
    mov  eax, b_sx
    cmp  eax, w
    jge  opb_next_row

    mov  eax, col
    add  eax, b_sx
    mov  b_dx, eax
    cmp  eax, 0
    jl   opb_next_col
    mov  ecx, ovl_vw
    cmp  eax, ecx
    jge  opb_next_row

    ; px = src[(b_sy * w + b_sx) * 4], with alpha forced opaque
    mov  eax, b_sy
    imul eax, w
    add  eax, b_sx
    mov  esi, src
    mov  edx, [esi + eax*4]
    and  edx, 000FFFFFFh              ; drop whatever alpha GDI left
    or   edx, 0FF000000h              ; ...and make the plate opaque
    mov  b_px, edx

    ; overlay[(b_dy * vw + b_dx) * 4] = b_px
    mov  eax, b_dy
    imul eax, ovl_vw
    add  eax, b_dx
    mov  edi, ovl_bits
    mov  edx, b_px
    mov  [edi + eax*4], edx

opb_next_col:
    inc  b_sx
    jmp  opb_col

opb_next_row:
    inc  b_sy
    jmp  opb_row

opb_done:
    ret
ovl_blit_opaque ENDP

END
