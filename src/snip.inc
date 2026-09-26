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

; The mode drop-down's indices, in list order.
MODE_RECT           EQU 0
MODE_WINDOW         EQU 1
MODE_FULL           EQU 2
MODE_FREE           EQU 3

; ---------------------------------------------------------------------------
; Public labels
; ---------------------------------------------------------------------------
shell_create PROTO STDCALL :DWORD   ; HWND shell_create(App *app) - see shell.asm

; overlay.asm - the Overlay window. It owns its class, its layered DIB, and the
; dim and chrome. It does not own the Selection; select.asm does.
overlay_show    PROTO STDCALL :DWORD, :DWORD        ; BOOL overlay_show(App *app, DWORD mode)
overlay_hide    PROTO STDCALL :DWORD                ; void overlay_hide(App *app)
overlay_repaint PROTO STDCALL :DWORD, :DWORD, :DWORD  ; void overlay_repaint(App *app, Rect *sel, DWORD down)

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

; capture.asm - screen capture. Ticket 03 blits the Selection's region straight
; from the screen DC into a caller's bitmap; ticket 08 adds the PrintWindow path
; for window mode. It owns no state between calls.
capture_region PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD  ; BOOL capture_region(Rect *sel, DWORD hdcDst, DWORD w, DWORD h)

; dib.asm - the Snip: ownership, alpha synthesis, and the Pristine twin. The
; crop maths stays in geometry.asm; this module is the impure DIB plumbing.
dib_crop PROTO STDCALL :DWORD   ; BOOL dib_crop(Rect *sel) - atomic: a failure keeps the old Snip
dib_snip PROTO STDCALL          ; Snip *dib_snip(void)

; editor.asm - the Editor window. Created once, resized and reused per Snip.
editor_open PROTO STDCALL :DWORD  ; BOOL editor_open(App *app)

ENDIF
