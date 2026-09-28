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
;
; x86: pointers are 32-bit, so pointer-sized struct fields are DWORD.

IFNDEF SNIP_INC
SNIP_INC EQU 1

; ---------------------------------------------------------------------------
; App - process-wide context. One instance lives in snip.asm's data and is
; handed to each window by pointer; a WndProc recovers it from GWLP_USERDATA.
; ---------------------------------------------------------------------------
App STRUCT 4
    hInstance   DWORD ?     ; process HINSTANCE, for window creation
    hwndShell   DWORD ?     ; the Shell window
    hwndEditor  DWORD ?     ; the Editor window, once a Snip exists
    hwndOverlay DWORD ?     ; the Overlay, while a Snipping session is live
    mode        DWORD ?     ; the mode drop-down's current index
    delay       DWORD ?     ; the delay drop-down's current index
App ENDS

; ---------------------------------------------------------------------------
; Rect - a Selection in virtual-screen physical pixels. left/top/right/bottom
; is the standing convention throughout; geometry.asm normalises and measures
; it. Mirrors the SDK RECT but is ours: geometry.asm must not need win32.inc.
;
; "Virtual-screen" here means the Overlay's client space: (0,0) is the
; virtual-screen origin, so a monitor left of / above the primary gives negative
; values. The Overlay draws the Selection in this space directly. Only the
; session->Snip boundary converts: select_finish adds the virtual origin before
; handing the Rect on, so capture and the Editor work in screen pixels.
; ---------------------------------------------------------------------------
Rect STRUCT
    left    SDWORD ?
    top     SDWORD ?
    right   SDWORD ?
    bottom  SDWORD ?
Rect ENDS

; Pt - a point in virtual-screen physical pixels, ours rather than the SDK's
; POINT, so geometry.asm can work in it without win32.inc.
Pt STRUCT
    x       SDWORD ?
    y       SDWORD ?
Pt ENDS

; ---------------------------------------------------------------------------
; Snip - the captured region, owned as one cropped bitmap.
;
; Working is the bitmap the Editor paints and (ticket 05) the encoder reads;
; Pristine is its untouched twin, kept for the Eraser and Undo (ticket 06).
; Both are straight (non-premultiplied) BGRA, 32bpp, top-down, and byte-identical
; until annotation begins - see ADR-0001. hdib/hdc hold Working selected into a
; memory DC so the Editor can BitBlt straight from it.
;
; There is one live Snip at a time. dib.asm owns the instance; editor.asm reads
; it through dib_snip. x/y are the Snip's screen origin (the Selection's
; top-left), kept so the Editor can place itself on the right monitor.
; ---------------------------------------------------------------------------
Snip STRUCT
    hdib        DWORD ?     ; HBITMAP: the Working bitmap
    bits        DWORD ?     ; its pixels, written directly
    hdc         DWORD ?     ; the memory DC Working is selected into
    oldbm       DWORD ?     ; what was selected in hdc before Working
    pristine    DWORD ?     ; HBITMAP: the Pristine twin
    pbits       DWORD ?     ; its pixels
    x           SDWORD ?    ; the Snip's screen origin
    y           SDWORD ?
    w           SDWORD ?    ; the Selection's inclusive span, in pixels
    h           SDWORD ?
Snip ENDS

; Control identifiers (the Shell's; more land as later tickets need them).
IDC_NEW             EQU 1001
IDC_MODE            EQU 1002
IDC_DELAY           EQU 1003
IDC_HINT            EQU 1004    ; the inert hint label below the controls

; The Editor toolbar (ticket 05; the annotation buttons go live in ticket 06).
IDC_ED_NEW          EQU 1101
IDC_ED_SAVE         EQU 1102
IDC_ED_COPY         EQU 1103
IDC_ED_PEN          EQU 1104
IDC_ED_HILITE       EQU 1105
IDC_ED_ERASER       EQU 1106
IDC_ED_UNDO         EQU 1107

; Accelerator command ids (ticket 12). A dedicated range: TranslateAcceleratorW
; delivers an accelerator as a WM_COMMAND whose notification word is 1, which
; would be ambiguous against a control's BN_CLICKED (0) or CBN_SELCHANGE (1).
; The WndProcs dispatch these ids before any control-notification logic, so the
; ambiguity never arises. Multi-window shortcuts share the one id: Alt+N is
; IDA_NEW on both windows. See docs/keyboard.md.
IDA_NEW             EQU 1201
IDA_MODE            EQU 1202
IDA_DELAY           EQU 1203
IDA_COPY            EQU 1204
IDA_SAVE            EQU 1205
IDA_UNDO            EQU 1206

; The mode drop-down's indices, in list order.
MODE_RECT           EQU 0
MODE_WINDOW         EQU 1
MODE_FULL           EQU 2
MODE_FREE           EQU 3

; ---------------------------------------------------------------------------
; Public labels
; ---------------------------------------------------------------------------
shell_create PROTO STDCALL :DWORD   ; HWND shell_create(App *app) - see shell.asm

; keys.asm - the keyboard map: the accelerator tables and their routing. It
; owns no actions; a matched key becomes a WM_COMMAND carrying an IDA_* id,
; which shell.asm or editor.asm handles. keys_init is called once from snip.asm;
; keys_translate is called by the pump for every message. See docs/keyboard.md.
keys_init      PROTO STDCALL                    ; BOOL keys_init(void) - build the tables
keys_free      PROTO STDCALL                    ; void keys_free(void) - destroy them on exit
keys_translate PROTO STDCALL :DWORD, :DWORD     ; BOOL keys_translate(App *app, MSG *msg) - 1 if consumed

; overlay.asm - the Overlay window. It owns its class, its layered DIB, and the
; dim and chrome. It does not own the Selection; select.asm does.
overlay_show    PROTO STDCALL :DWORD, :DWORD        ; BOOL overlay_show(App *app, DWORD mode)
overlay_hide    PROTO STDCALL :DWORD                ; void overlay_hide(App *app)
overlay_repaint PROTO STDCALL :DWORD, :DWORD, :DWORD  ; void overlay_repaint(App *app, Rect *sel, DWORD down)
overlay_repaint_free PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD  ; void overlay_repaint_free(App *app, Pt *pts, DWORD n, Rect *bbox)
overlay_set_dpi PROTO STDCALL :DWORD                ; void overlay_set_dpi(DWORD dpi) - re-lay-out chrome

; select.asm - the Selection state machine and its session lifecycle.
select_begin  PROTO STDCALL :DWORD  ; BOOL select_begin(App *app) - New was clicked
select_cancel PROTO STDCALL         ; end the session, restore the Shell
select_finish PROTO STDCALL         ; complete the session with the Selection
; The Overlay's WndProc. It lives in select.asm because the Overlay is a
; surface and the Selection is the behaviour that runs on it; overlay.asm
; registers it as the class's lpfnWndProc.
sel_wndproc   PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD

; geometry.asm - pure Selection maths. Win32-free; includes only snip.inc.
geo_normalise PROTO STDCALL :DWORD, :DWORD, :DWORD  ; void geo_normalise(Rect *r, Pt *a, Pt *b)
geo_width     PROTO STDCALL :DWORD                  ; SDWORD geo_width(Rect *r)
geo_height    PROTO STDCALL :DWORD                  ; SDWORD geo_height(Rect *r)

; mask.asm - pure free-form Trace geometry. Win32-free; includes only snip.inc.
; It owns the fixed point buffer and nothing else: the sampling acceptance
; test, Ramer-Douglas-Peucker simplification, the inclusive bbox, and the
; degenerate test. The impure GDI+ coverage fill lives in dib.asm.
mask_reset     PROTO STDCALL :DWORD                        ; void mask_reset(DWORD dpi) - clear the Trace, set the sample threshold
mask_add       PROTO STDCALL :SDWORD, :SDWORD              ; BOOL mask_add(x, y) - accept if the pointer moved far enough
mask_bbox      PROTO STDCALL :DWORD                        ; void mask_bbox(Rect *out) - inclusive bbox of the accepted points
mask_simplify  PROTO STDCALL                               ; void mask_simplify(void) - RDP eps=1, in place
mask_translate PROTO STDCALL :SDWORD, :SDWORD              ; void mask_translate(dx, dy) - move points and bbox to screen pixels
mask_count     PROTO STDCALL                               ; DWORD mask_count(void) - path points: simplified after release, raw during the drag
mask_points    PROTO STDCALL                               ; Pt *mask_points(void) - simplified points (Pt == GpPoint)
mask_degenerate PROTO STDCALL                              ; BOOL mask_degenerate(void) - too few points or a sub-2x2 bbox

; capture.asm - screen capture. Ticket 03 blits the Selection's region straight
; from the screen DC into a caller's bitmap; ticket 08 adds the PrintWindow path
; for window mode. It owns no state between calls, save a lazily resolved DWM
; entry point.
;
; The Rect arrives in SCREEN physical pixels - the caller has already added the
; virtual-screen origin - so capture never assumes the desktop starts at (0,0).
capture_region PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD  ; BOOL capture_region(Rect *sel, DWORD hdcDst, DWORD w, DWORD h)
; BOOL capture_window(HWND hwnd, Rect *sel, DWORD hdcDst, DWORD w, DWORD h, DWORD bits)
;   PrintWindow(PW_RENDERFULLCONTENT) off the UI thread, then the same without the
;   flag, then a screen blit of *sel (SCREEN pixels); `bits` is the Snip's pixels,
;   for the all-black test. Returns nonzero if any attempt produced a bitmap.
capture_window PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
; BOOL window_frame(HWND hwnd, Rect *out) - the top-level frame in SCREEN pixels,
;   DWMWA_EXTENDED_FRAME_BOUNDS with a GetWindowRect fallback. Used by select.asm
;   for the hover highlight and handed to capture_window for the blit fallback.
window_frame   PROTO STDCALL :DWORD, :DWORD

; dib.asm - the Snip: ownership, alpha synthesis, and the Pristine twin. The
; crop maths stays in geometry.asm; this module is the impure DIB plumbing.
dib_crop PROTO STDCALL :DWORD   ; BOOL dib_crop(Rect *sel) - SCREEN pixels; atomic: a failure keeps the old Snip
; BOOL dib_crop_window(Rect *sel, HWND hwnd) - the same, filled by PrintWindow
; instead of the region blit. SCREEN pixels; atomic like dib_crop.
dib_crop_window PROTO STDCALL :DWORD, :DWORD
dib_crop_free PROTO STDCALL :DWORD, :DWORD, :DWORD  ; BOOL dib_crop_free(Rect *bbox, Pt *path, DWORD n) - free-form cut; SCREEN pixels
dib_snip PROTO STDCALL          ; Snip *dib_snip(void)

; editor.asm - the Editor window. Created once, resized and reused per Snip.
editor_open PROTO STDCALL :DWORD  ; BOOL editor_open(App *app)

; encode.asm - WIC encoding to a file and the clipboard. Ticket 05. The COM
; apartment and the WIC factory are process-wide; encode_init is called once
; from snip.asm. encode_file/encode_clipboard return an HRESULT (0 == S_OK).
encode_init      PROTO STDCALL                    ; BOOL encode_init(void)
encode_file      PROTO STDCALL :DWORD, :DWORD     ; HRESULT encode_file(Snip *snip, LPCWSTR path)
encode_clipboard PROTO STDCALL :DWORD             ; HRESULT encode_clipboard(Snip *snip)

; ink.asm - the annotation engine: a command log of strokes replayed onto the
; Working bitmap with GDI+, the Eraser, and Undo (ticket 06). It reads the live
; Snip through dib_snip and is fed input by editor.asm. Coordinates are the
; Snip's own pixels (Editor client less the toolbar), so a stroke replays
; identically. A stroke is uncommitted until ink_end, which is when it lands in
; Working; ink_preview draws the in-progress stroke over a paint for feedback.
ink_init        PROTO STDCALL                          ; BOOL ink_init(void) - GDI+ startup, once
ink_reset       PROTO STDCALL                          ; void - drop the log for a new Snip
ink_start       PROTO STDCALL :DWORD, :SDWORD, :SDWORD, :DWORD  ; BOOL ink_start(tool, x, y, dpi)
ink_extend      PROTO STDCALL :SDWORD, :SDWORD         ; void ink_extend(x, y)
ink_end         PROTO STDCALL                          ; void - commit the stroke
ink_preview     PROTO STDCALL :DWORD, :SDWORD, :SDWORD, :DWORD, :DWORD, :DWORD, :DWORD  ; void ink_preview(hdc, ox, oy, vw, vh, sw, sh) - scaled to the Editor's fit
ink_erase_begin PROTO STDCALL                          ; void - start an eraser drag
ink_erase       PROTO STDCALL :SDWORD, :SDWORD, :DWORD ; BOOL ink_erase(x, y, dpi)
ink_erase_end   PROTO STDCALL                          ; void - end an eraser drag
ink_undo        PROTO STDCALL                          ; BOOL - revert the last operation

; The annotation tools, as the Editor's active-tool value.
INK_PEN         EQU 0
INK_HILITE      EQU 1
INK_ERASER      EQU 2

; err.asm - the error surface: one MessageBoxW per failure (ticket 11). A module
; reports by id; err.asm owns the wording and the style. Every failure is
; recoverable except the startup ones, which end the process.
err_show PROTO STDCALL :DWORD, :DWORD   ; int err_show(HWND hwndOwner, DWORD id)

; The ERR_* ids err_show maps to a message, in err_table order. Adding one means
; a constant here, a string and a table entry in err.asm, and ERR_LAST moved on.
; An id above ERR_LAST is ignored rather than read past the table.
ERR_CAPTURE        EQU 0     ; a Selection could not be captured
ERR_COPY           EQU 1     ; the Snip could not go on the clipboard
ERR_CLIPBOARD_BUSY EQU 2     ; the clipboard is held by another application
ERR_SAVE           EQU 3     ; the Snip could not be written
ERR_STARTUP        EQU 4     ; COM or the WIC factory is unavailable (fatal)
ERR_SHELL          EQU 5     ; the Shell window could not be created (fatal)
ERR_LAST           EQU ERR_SHELL

ENDIF
