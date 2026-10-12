; ui.asm
; The Fluent control skin: owner-draw for the Shell's and Editor's buttons and
; drop-downs, so they carry the Windows 11 look and go dark on a dark system
; without a comctl32 v6 manifest. See docs/ui.md and ADR-0004.
;
; This module owns only how our controls are painted and how they react to the
; mouse. It owns no window and no command: shell.asm and editor.asm keep their
; controls and their WM_COMMAND handling and hand this module the painting.
;
; Ticket 02 paints the buttons. A button is a BS_OWNERDRAW BUTTON; the parent's
; WM_DRAWITEM routes here, and ui_draw_button lays down the Fluent surface: the
; ambient background, a rounded 4px rect, a hairline border, then the label. The
; pressed and disabled looks come from DRAWITEMSTRUCT.itemState, which the button
; supplies without any subclassing; the hover and focus states (ticket 04) do
; not. ui_attach records each control's kind and ambient surface, so this
; module never has to know our control ids.
;
; Ticket 03 paints the drop-downs. A drop-down is a plain ComboBox with
; CBS_OWNERDRAWFIXED | CBS_DROPDOWNLIST; the parent's WM_DRAWITEM arrives once
; for the closed face (itemID == -1) and once per open row, and ui_draw_combo
; paints both. Its row glyphs are drawn as vectors by ui_draw_glyph_id, keyed by
; the id shell.asm stashed with CB_SETITEMDATA.
;
; Ticket 04 adds interaction. ui_attach subclasses each control; ui_subclass_proc
; tracks the pointer with TrackMouseEvent(TME_LEAVE) and remembers the one hot
; control in ui_hot. The hover surface is then chosen at draw time, and
; ODS_FOCUS draws the Fluent focus ring. The subclasses never replace behaviour:
; DefSubclassProc still receives every message.
;
; An icon button (UI_KIND_ICON) carries a Segoe Fluent Icons codepoint as its
; window text. ui_draw_icon renders that codepoint as the real font glyph when
; the icons .ttf can be loaded; otherwise it falls back to a hand-drawn vector,
; so a button is never blank. See ui_load_icon_font for why the face is read
; from the file rather than resolved by name.
;
; The accent and the entry-point names come from dwmapi.dll, resolved with
; LoadLibraryA/GetProcAddress - the Crinkler-safe pattern theme.asm and
; capture.asm already use, so the build gains no import library. Every step is
; best-effort: a missing GDI+ falls back to a label-only button.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC ui_init
PUBLIC ui_attach
PUBLIC ui_draw_item
PUBLIC ui_theme_changed

; Forward declarations so INVOKE reaches callees defined later in the file.
ui_resolve_accent PROTO STDCALL
ui_argb           PROTO STDCALL :DWORD
ui_tint           PROTO STDCALL :DWORD, :DWORD, :DWORD
ui_find           PROTO STDCALL :DWORD
ui_ambient_color  PROTO STDCALL :DWORD
ui_fill_rect      PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
ui_round_rect     PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
ui_draw_button    PROTO STDCALL :DWORD
ui_draw_combo     PROTO STDCALL :DWORD
ui_paint_combo    PROTO STDCALL :DWORD
ui_paint_combo_dc PROTO STDCALL :DWORD, :DWORD
ui_draw_glyph_id  PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD
ui_draw_icon      PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD
ui_draw_glyph     PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD
ui_draw_poly      PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
ui_load_icon_font PROTO STDCALL
ui_icon_path      PROTO STDCALL :DWORD
ui_subclass_proc  PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD

; A GDI+ RectF: four REALs. GdipDrawString takes its layout rect as floats, so
; ui_draw_icon converts the button's integer rect with the x87.
RectF STRUCT
    x DWORD ?
    y DWORD ?
    w DWORD ?
    h DWORD ?
RectF ENDS

; A registered control: its handle, the drawing kind (UI_KIND_*), and the ambient
; surface it sits on (UI_AMBIENT_*). Flat and fixed-size; the app has far fewer
; controls than the cap.
UiSlot STRUCT
    hwnd    DWORD ?
    kind    DWORD ?
    ambient DWORD ?
    glyph   DWORD ?   ; UI_GLYPH_*: the last face glyph drawn, a fallback for the
                      ; ComboBox's mid-selection field repaint
UiSlot ENDS
UI_MAX_CONTROLS EQU 16

; ---------------------------------------------------------------------------
; Read-only data. Colour tokens are COLORREF (0x00BBGGRR); ui_argb sets the
; alpha for GDI+.
; ---------------------------------------------------------------------------
.const
ff_ui          DW 'S','e','g','u','e',' ','U','I',' ','V','a','r','i','a','b','l','e',' ','T','e','x','t',0

dwmapi_dll     DB 'dwmapi.dll',0
fn_dwmcolor    DB 'DwmGetColorizationColor',0

; The Fluent default accent, #0067C0, when DWM will not report the user's colour.
ACCENT_FALLBACK EQU 00C06700h

; UI_RADIUS is the Fluent 2 control corner radius, in pixels. PEN_W_1 is a 1.0
; stroke width; ARCF_* are the arc angles as IEEE-754 float bits (GDI+ REALs).
UI_RADIUS      EQU 4
PEN_W_1        EQU 03F800000h
PEN_W_ICON     EQU 03FC00000h   ; 1.5f: the icon stroke width
ARCF_0         EQU 000000000h
ARCF_90        EQU 042B40000h
ARCF_180       EQU 043340000h
ARCF_270       EQU 043870000h

; The Editor's tool buttons: their window text is one Segoe Fluent Icons
; codepoint. ui.asm does not read the icon font - like shell.asm's drop-down
; glyphs, these icons are drawn, not loaded - so the codepoint selects a vector
; below. The arrays are on a 16x16 grid, centred by ui_draw_icon.
ICON_SAVE      EQU 0E74Eh
ICON_COPY      EQU 0E8C8h
ICON_PEN       EQU 0E70Fh
ICON_HILITE    EQU 0E7E6h
ICON_ERASER    EQU 0E75Ch
ICON_UNDO      EQU 0E7A7h
ICON_ADD       EQU 0E710h       ; the "+" that prefixes the Editor's New button
ICON_CHEVRON   EQU 0E70Dh       ; the drop-down's down chevron (ticket 03)

; The icon font. The .ttf is read from the Windows font directory into a private
; GDI+ collection (ui_load_icon_font); ICON_EM is 16.0f - the same size as the
; vector grid - and the two files are tried in order: the Windows 11 name first,
; then the Windows 10 one. GdipDrawString needs REALs, and StringAlignmentCenter
; centres the glyph in the button.
ICON_EM        EQU 041800000h   ; 16.0f
UnitPixel      EQU 2
SA_CENTER      EQU 1            ; StringAlignmentCenter
icofile_icons  DW '\','F','o','n','t','s','\','S','e','g','o','e','I','c','o','n','s','.','t','t','f',0
icofile_mdl2   DW '\','F','o','n','t','s','\','s','e','g','m','d','l','2','.','t','t','f',0

ic_save_a  POINT <2,1>,<14,1>,<14,15>,<2,15>,<2,1>       ; floppy outline
ic_save_b  POINT <5,1>,<5,5>,<11,5>,<11,1>               ; shutter
ic_save_c  POINT <4,9>,<12,9>,<12,14>,<4,14>,<4,9>       ; label
ic_copy_a  POINT <5,2>,<14,2>,<14,12>,<5,12>,<5,2>       ; back sheet
ic_copy_b  POINT <2,4>,<11,4>,<11,14>,<2,14>,<2,4>       ; front sheet
ic_pen_a   POINT <12,2>,<4,10>,<2,14>,<3,15>,<6,13>,<14,4>,<12,2>  ; pencil
ic_hl_a    POINT <4,5>,<13,5>,<13,10>,<4,10>,<4,5>       ; highlighter body
ic_hl_b    POINT <4,10>,<2,14>,<8,14>,<4,10>             ; chisel tip
ic_er_a    POINT <3,9>,<8,4>,<14,8>,<9,13>,<3,9>         ; eraser
ic_undo_a  POINT <5,5>,<5,11>,<8,13>,<11,13>,<14,10>     ; undo curve
ic_undo_b  POINT <5,5>,<3,7>,<5,9>                       ; undo arrowhead
ic_chev_a  POINT <4,6>,<8,10>,<12,6>                     ; down chevron

; Drop-down glyphs (ticket 03): the Shell's mode icons and the Delay clock,
; moved here from shell.asm's image list. ui.asm draws them as vectors on the
; same 16x16 grid as the tool icons; shell.asm tags each row with a UI_GLYPH_*
; id through CB_SETITEMDATA, and the closed face looks its id up with
; CB_GETITEMDATA. The clock dial is the one shape a polyline cannot trace, so it
; is drawn with GdipDrawEllipseI.
gl_rect   POINT <2,3>,<14,3>,<14,13>,<2,13>,<2,3>            ; Rectangle mode
gl_win_a  POINT <1,2>,<15,2>,<15,14>,<1,14>,<1,2>            ; Window mode: frame
gl_win_b  POINT <1,5>,<15,5>                                 ; ... and its title bar
gl_full_1 POINT <1,5>,<1,1>,<5,1>                            ; Full screen: corners
gl_full_2 POINT <11,1>,<15,1>,<15,5>
gl_full_3 POINT <15,11>,<15,15>,<11,15>
gl_full_4 POINT <5,15>,<1,15>,<1,11>
gl_free   POINT <3,11>,<4,6>,<8,3>,<12,4>,<9,9>,<5,9>,<6,12>  ; Freeform lasso
gl_hand_v POINT <8,8>,<8,5>                                  ; clock: minute hand
gl_hand_h POINT <8,8>,<11,10>                                ; clock: hour hand

; Ambient surfaces a control's rounded corners reveal.
AMB_BG_LIGHT   EQU 00FFFFFFh      ; the Shell's client (#FFFFFF)
AMB_FACE_LIGHT EQU 00F0F0F0h      ; the Editor's toolbar strip (COLOR_BTNFACE)
AMB_BG_DARK    EQU 00202020h      ; theme.asm's dark client (#202020)
AMB_FACE_DARK  EQU 002B2B2Bh      ; theme.asm's dark surface (#2B2B2B)

; Button tokens, light (L) and dark (D).
SURFACE_LIGHT  EQU 00FDFDFDh
SURFACE_DARK   EQU 002D2D2Dh
PRESSED_LIGHT  EQU 00F0F0F0h
PRESSED_DARK   EQU 00272727h
BORDER_LIGHT   EQU 00E5E5E5h
BORDER_DARK    EQU 003A3A3Ah
TEXT_LIGHT     EQU 001A1A1Ah
TEXT_DARK      EQU 00FFFFFFh
WHITE          EQU 00FFFFFFh
DISABLED_LIGHT EQU 009E9E9Eh
DISABLED_DARK  EQU 006B6B6Bh

; Drop-down and interaction tokens (tickets 03/04). HOVER_* is the pointer-over
; surface, shared by buttons and combos. The combo face and its rows use the same
; Fluent surface as a button; a selected row is SEL_MIX percent of the accent
; blended into that surface, with a 3px accent bar.
HOVER_LIGHT    EQU 00F5F5F5h
HOVER_DARK     EQU 00323232h
COMBO_FACE_LIGHT EQU 00FFFFFFh
COMBO_FACE_DARK  EQU 002D2D2Dh
SEL_MIX        EQU 22            ; % of the accent mixed into a selected row

; ---------------------------------------------------------------------------
; Mutable data. Zero-initialised, so .data? (.bss): no file bytes.
; ---------------------------------------------------------------------------
.data?
ui_ready      DWORD ?          ; GDI+ is up: the skin may draw
ui_token      DWORD ?          ; the skin's own GdiplusStartup token
ui_hot        DWORD ?          ; HWND: the control the pointer is over (ticket 04)
ui_font_gdi   DWORD ?          ; HFONT: the button label, drawn with GDI for ClearType
ui_accent     DWORD ?          ; COLORREF: the primary button's fill
ui_iconcoll   DWORD ?          ; GpFontCollection*: the icons .ttf, loaded from file
ui_iconfamily DWORD ?          ; GpFontFamily*: the icon face, taken from that collection
ui_iconfont   DWORD ?          ; GpFont*: the icon glyph font, 0 when unavailable
ui_iconfamarr DWORD 4 DUP(?)   ; scratch: the collection's family list
ui_fontpath   WORD 260 DUP(?)  ; scratch: %WINDIR%\Fonts\<icons>.ttf
pfn_DwmGetColorizationColor DWORD ?
ura_color     DWORD ?          ; scratch: DwmGetColorizationColor's ARGB out
ura_opaque    DWORD ?          ; scratch: its BOOL opaque-blend out
ui_slots      UiSlot UI_MAX_CONTROLS DUP(<>)
ui_ptbuf      POINT 16 DUP(<>)   ; scratch: one icon polyline, translated to the button

.code

; ---------------------------------------------------------------------------
; ui_init() -> BOOL in eax. Called once from snip.asm before any window exists.
;
; Starts GDI+ on its own token (ink.asm keeps its own; GDI+ allows more than one
; startup pair), then resolves the accent, loads the two font families, and
; builds the label font. A failure at any step is not fatal: ui_ready stays 0 and
; the caller's controls fall back to the label-only / classic look.
; ---------------------------------------------------------------------------
ui_init PROC
    LOCAL gsi:GdiplusStartupInput

    mov  ui_ready, 0
    mov  gsi.GdiplusVersion, 1
    mov  gsi.DebugEventCallback, 0
    mov  gsi.SuppressBackgroundThread, 0
    mov  gsi.SuppressExternalCodecs, 0

    INVOKE GdiplusStartup, OFFSET ui_token, ADDR gsi, 0
    test eax, eax
    jnz  ui_init_no
    mov  ui_ready, 1

    INVOKE ui_resolve_accent

    ; The label font is GDI's: ClearType text is crisper than GDI+'s, and the
    ; button label is the one place it matters. CreateFontW maps an absent face
    ; to the closest installed substitute, so an older system still gets text.
    ; (The icon buttons draw a Segoe Fluent Icons glyph; ui_load_icon_font below
    ; reads the face from its .ttf, because this image will not resolve it by
    ; name.)
    INVOKE CreateFontW, -14, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, 0, OFFSET ff_ui
    mov  ui_font_gdi, eax

    INVOKE ui_load_icon_font

    mov  eax, 1
    ret
ui_init_no:
    xor  eax, eax
    ret
ui_init ENDP

; ---------------------------------------------------------------------------
; ui_theme_changed() -> void. Called from each window's WM_SETTINGCHANGE handler
; after theme_refresh. The accent can move with the theme, so it is re-resolved;
; the controls repaint through the RedrawWindow(... RDW_ALLCHILDREN) the caller
; already issues. Ticket 05 extends this to the dark control palette (already
; keyed live off theme_is_dark at draw time).
; ---------------------------------------------------------------------------
ui_theme_changed PROC
    cmp  ui_ready, 0
    je   utc_done
    INVOKE ui_resolve_accent
utc_done:
    ret
ui_theme_changed ENDP

; ---------------------------------------------------------------------------
; ui_attach(control, kind, ambient) -> void. Records a control for the skin:
; its drawing kind (UI_KIND_*) and the surface it sits on (UI_AMBIENT_*), then
; subclasses it (ticket 04) so the skin sees the pointer for hover. The
; control's own style already carries BS_OWNERDRAW / CBS_OWNERDRAWFIXED. Called
; from shell_on_create and editor_on_create.
; ---------------------------------------------------------------------------
ui_attach PROC USES ebx esi edi control:DWORD, kind:DWORD, ambient:DWORD
    mov  ebx, control

    ; Ticket 04: watch the pointer. The subclass forwards everything it does not
    ; use (DefSubclassProc), so no control behaviour changes.
    INVOKE SetWindowSubclass, ebx, OFFSET ui_subclass_proc, 0, 0

    INVOKE ui_find, ebx
    cmp  eax, -1
    je   ua_add

    ; Update the existing slot.
    imul eax, eax, SIZEOF UiSlot
    add  eax, OFFSET ui_slots
    mov  [eax].UiSlot.hwnd, ebx
    mov  ecx, kind
    mov  [eax].UiSlot.kind, ecx
    mov  ecx, ambient
    mov  [eax].UiSlot.ambient, ecx
    ret

ua_add:
    mov  ecx, 0
    mov  edx, OFFSET ui_slots
ua_scan:
    cmp  ecx, UI_MAX_CONTROLS
    jae  ua_done                  ; full: the control simply draws with defaults
    cmp  [edx].UiSlot.hwnd, 0
    je   ua_free
    add  edx, SIZEOF UiSlot
    inc  ecx
    jmp  ua_scan
ua_free:
    mov  [edx].UiSlot.hwnd, ebx
    mov  eax, kind
    mov  [edx].UiSlot.kind, eax
    mov  eax, ambient
    mov  [edx].UiSlot.ambient, eax
ua_done:
    ret
ui_attach ENDP

; ---------------------------------------------------------------------------
; ui_find(control) -> eax = the slot index, or -1. Linear over a tiny table.
; ---------------------------------------------------------------------------
ui_find PROC control:DWORD
    mov  ecx, 0
    mov  edx, OFFSET ui_slots
uf_loop:
    cmp  ecx, UI_MAX_CONTROLS
    jae  uf_none
    mov  eax, [edx].UiSlot.hwnd
    test eax, eax
    jz   uf_next
    cmp  eax, control
    je   uf_hit
uf_next:
    add  edx, SIZEOF UiSlot
    inc  ecx
    jmp  uf_loop
uf_hit:
    mov  eax, ecx
    ret
uf_none:
    mov  eax, -1
    ret
ui_find ENDP

; ---------------------------------------------------------------------------
; ui_subclass_proc(hwnd, msg, wParam, lParam, id, ref) -> LRESULT. The
; SetWindowSubclass procedure for each attached control (ticket 04). It tracks
; the one hot control so the skin can draw the hover surface: the first
; WM_MOUSEMOVE arms TrackMouseEvent(TME_LEAVE) and invalidates the control;
; WM_MOUSELEAVE clears it. Every other message goes to DefSubclassProc, so no
; control behaviour is replaced.
; ---------------------------------------------------------------------------
ui_subclass_proc PROC hwnd:DWORD, msg:DWORD, wParam:DWORD, lParam:DWORD, id:DWORD, ref:DWORD
    LOCAL tme:TRACKMOUSEEVENT

    cmp  msg, WM_MOUSEMOVE
    je   usp_move
    cmp  msg, WM_MOUSELEAVE
    je   usp_leave
    cmp  msg, WM_PAINT
    je   usp_paint
    cmp  msg, WM_ERASEBKGND
    je   usp_erase
    cmp  msg, WM_SETFOCUS
    je   usp_focus
    cmp  msg, WM_KILLFOCUS
    je   usp_focus
    cmp  msg, WM_NCPAINT
    je   usp_ncpaint
    jmp  usp_default

; A drop-down's face is painted by the skin, not the ComboBox: the base control
; draws a classic 3-D border and a drop-down arrow button that owner-draw never
; covers. ui_paint_combo takes the whole paint (BeginPaint validates the update
; region), so the control never draws its face. Buttons keep their WM_PAINT.
usp_paint:
    INVOKE ui_find, hwnd
    cmp  eax, -1
    je   usp_default
    imul eax, eax, SIZEOF UiSlot
    add  eax, OFFSET ui_slots
    cmp  [eax].UiSlot.kind, UI_KIND_COMBO
    jne  usp_default
    INVOKE ui_paint_combo, hwnd
    xor  eax, eax
    ret

; A drop-down erases nothing itself; the face paint fills the whole client.
usp_erase:
    INVOKE ui_find, hwnd
    cmp  eax, -1
    je   usp_default
    imul eax, eax, SIZEOF UiSlot
    add  eax, OFFSET ui_slots
    cmp  [eax].UiSlot.kind, UI_KIND_COMBO
    jne  usp_default
    mov  eax, 1
    ret

; The control redraws its field (border and all) on a focus change, outside the
; WM_PAINT path; let it, then invalidate so our face repaints over it.
usp_focus:
    INVOKE ui_find, hwnd
    cmp  eax, -1
    je   usp_default
    imul eax, eax, SIZEOF UiSlot
    add  eax, OFFSET ui_slots
    cmp  [eax].UiSlot.kind, UI_KIND_COMBO
    jne  usp_default
    INVOKE DefSubclassProc, hwnd, msg, wParam, lParam
    INVOKE InvalidateRect, hwnd, 0, 0
    xor  eax, eax
    ret

; The ComboBox paints a classic 1px frame (a grey top/left edge) in WM_NCPAINT,
; over our Fluent face. Suppress it for combos; our face already covers the frame
; area, and the control has no real non-client area (window rect == client rect).
usp_ncpaint:
    INVOKE ui_find, hwnd
    cmp  eax, -1
    je   usp_default
    imul eax, eax, SIZEOF UiSlot
    add  eax, OFFSET ui_slots
    cmp  [eax].UiSlot.kind, UI_KIND_COMBO
    jne  usp_default
    xor  eax, eax
    ret

usp_move:
    mov  eax, hwnd
    cmp  ui_hot, eax
    je   usp_default              ; already hot: TME_LEAVE is armed
    mov  ui_hot, eax
    mov  tme.cbSize, SIZEOF TRACKMOUSEEVENT
    mov  tme.dwFlags, TME_LEAVE
    mov  eax, hwnd
    mov  tme.hwndTrack, eax
    mov  tme.dwHoverTime, 0
    INVOKE TrackMouseEvent, ADDR tme
    INVOKE InvalidateRect, hwnd, 0, 0
    jmp  usp_default

usp_leave:
    mov  eax, hwnd
    cmp  ui_hot, eax
    jne  usp_leave_repaint
    mov  ui_hot, 0
usp_leave_repaint:
    ; Always repaint on leave: even if another control has already claimed the
    ; hot slot, this control still holds a stale hover fill until it redraws.
    INVOKE InvalidateRect, hwnd, 0, 0
    jmp  usp_default

usp_default:
    INVOKE DefSubclassProc, hwnd, msg, wParam, lParam
    ret
ui_subclass_proc ENDP

; ---------------------------------------------------------------------------
; ui_draw_item(parent, dis) -> void. The single WM_DRAWITEM entry point, called
; from shell_wndproc and editor_wndproc. Dispatches on CtlType: a button, or a
; drop-down list row.
; ---------------------------------------------------------------------------
ui_draw_item PROC USES esi parent:DWORD, dis:DWORD
    LOCAL dch:DWORD

    mov  esi, dis
    test esi, esi
    jz   udi_done
    mov  eax, [esi].DRAWITEMSTRUCT.CtlType
    cmp  eax, ODT_BUTTON
    je   udi_button
    cmp  eax, ODT_COMBOBOX
    je   udi_combo
    jmp  udi_done
udi_button:
    INVOKE ui_draw_button, esi
    jmp  udi_done

udi_combo:
    ; An open-list row (itemID >= 0) draws straight into the DC the ComboBox
    ; supplied: that DC is clipped to the row's rcItem, which is exactly what
    ; ui_draw_combo fills, so it needs no re-targeting.
    ;
    ; The selection *field* is different. Its DC (itemID == -1, or ODS_COMBOBOXEDIT)
    ; is clipped to the field rect - the face minus the drop-down arrow button -
    ; but ucc_face lays the face out across the whole client, so drawing through
    ; that clip paints its fill and border over only the left ~34px of the face
    ; ui_paint_combo already drew. Anything spanning the client loses its left
    ; edge, and the focus ring loses the most: only a focused whole-client pass
    ; draws one, so choosing an item leaves a ring with its left side wiped - the
    ; broken "focus border" box across the drop-down. Repaint the field through
    ; our own full-client DC instead so this face is identical to the WM_PAINT
    ; one. See ui_paint_combo_dc.
    mov  eax, [esi].DRAWITEMSTRUCT.itemID
    cmp  eax, 0FFFFFFFFh
    je   udi_combo_face
    test [esi].DRAWITEMSTRUCT.itemState, ODS_COMBOBOXEDIT
    jz   udi_combo_row
udi_combo_face:
    INVOKE GetDC, [esi].DRAWITEMSTRUCT.hwndItem
    test eax, eax
    jz   udi_done                    ; no DC: leave the face to the next WM_PAINT
    mov  dch, eax
    INVOKE ui_paint_combo_dc, [esi].DRAWITEMSTRUCT.hwndItem, dch
    INVOKE ReleaseDC, [esi].DRAWITEMSTRUCT.hwndItem, dch
    jmp  udi_done

udi_combo_row:
    INVOKE ui_draw_combo, esi
udi_done:
    xor  eax, eax
    ret
ui_draw_item ENDP

; ---------------------------------------------------------------------------
; ui_draw_button(dis) -> void. Paints one Fluent button into dis->hDC.
;
; The full control rect is filled with the ambient surface first, then the
; rounded surface inset by one pixel is drawn over it, so the antialiased corners
; sit on the right background rather than black (the plain-HDC hazard docs/ink.md
; and docs/overlay.md record). The label is drawn with GDI afterwards for
; ClearType, after GdipFlush drains the batched shape.
; ---------------------------------------------------------------------------
ui_draw_button PROC USES ebx esi edi dis:DWORD
    LOCAL gfx:DWORD
    LOCAL kind:DWORD
    LOCAL ambientRole:DWORD
    LOCAL dark:DWORD
    LOCAL fillCr:DWORD
    LOCAL borderCr:DWORD
    LOCAL textCr:DWORD
    LOCAL pressedCr:DWORD
    LOCAL disabledCr:DWORD
    LOCAL hoverCr:DWORD
    LOCAL ambientCr:DWORD
    LOCAL glyph:DWORD
    LOCAL w:DWORD
    LOCAL h:DWORD
    LOCAL x:DWORD
    LOCAL y:DWORD
    LOCAL rc:RECT
    LOCAL gr:RECT
    LOCAL mrc:RECT
    LOCAL textW:DWORD
    LOCAL glyphx:DWORD
    LOCAL hasGlyph:DWORD
    LOCAL buf[64]:WORD

    mov  esi, dis
    mov  gfx, 0
    mov  kind, UI_KIND_BUTTON
    mov  ambientRole, UI_AMBIENT_BG

    ; rcItem -> the local RECT (also the DrawTextW target).
    mov  eax, [esi].DRAWITEMSTRUCT.rcItem.left
    mov  rc.left, eax
    mov  eax, [esi].DRAWITEMSTRUCT.rcItem.top
    mov  rc.top, eax
    mov  eax, [esi].DRAWITEMSTRUCT.rcItem.right
    mov  rc.right, eax
    mov  eax, [esi].DRAWITEMSTRUCT.rcItem.bottom
    mov  rc.bottom, eax

    ; Kind and ambient from the registration; defaults stand if unattached.
    mov  eax, [esi].DRAWITEMSTRUCT.hwndItem
    INVOKE ui_find, eax
    cmp  eax, -1
    je   udb_slot_done
    imul eax, eax, SIZEOF UiSlot
    add  eax, OFFSET ui_slots
    mov  ecx, [eax].UiSlot.kind
    mov  kind, ecx
    mov  ecx, [eax].UiSlot.ambient
    mov  ambientRole, ecx
udb_slot_done:

    INVOKE theme_is_dark
    mov  dark, eax

    ; Base tokens by theme.
    cmp  dark, 0
    je   udb_light
    mov  fillCr, SURFACE_DARK
    mov  borderCr, BORDER_DARK
    mov  textCr, TEXT_DARK
    mov  pressedCr, PRESSED_DARK
    mov  disabledCr, DISABLED_DARK
    mov  hoverCr, HOVER_DARK
    jmp  udb_colors_done
udb_light:
    mov  fillCr, SURFACE_LIGHT
    mov  borderCr, BORDER_LIGHT
    mov  textCr, TEXT_LIGHT
    mov  pressedCr, PRESSED_LIGHT
    mov  disabledCr, DISABLED_LIGHT
    mov  hoverCr, HOVER_LIGHT
udb_colors_done:

    ; The primary button is accent-filled, white text, no border.
    cmp  kind, UI_KIND_BUTTON_PRIMARY
    jne  udb_not_primary
    mov  eax, ui_accent
    mov  fillCr, eax
    mov  borderCr, 0
    mov  textCr, WHITE
udb_not_primary:

    ; Hover (ticket 04): the pointer is over this control. The primary keeps its
    ; accent fill, and a disabled control does not react.
    mov  eax, [esi].DRAWITEMSTRUCT.hwndItem
    cmp  eax, ui_hot
    jne  udb_not_hover
    cmp  kind, UI_KIND_BUTTON_PRIMARY
    je   udb_not_hover
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_DISABLED
    jnz  udb_not_hover
    mov  eax, hoverCr
    mov  fillCr, eax
udb_not_hover:

    ; Pressed overrides the fill (the accent already reads as active).
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_SELECTED
    jz   udb_not_pressed
    cmp  kind, UI_KIND_BUTTON_PRIMARY
    je   udb_not_pressed
    mov  eax, pressedCr
    mov  fillCr, eax
udb_not_pressed:

    ; Disabled: muted text.
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_DISABLED
    jz   udb_not_disabled
    mov  eax, disabledCr
    mov  textCr, eax
udb_not_disabled:

    ; Full-rect size.
    mov  eax, rc.right
    sub  eax, rc.left
    mov  w, eax
    mov  eax, rc.bottom
    sub  eax, rc.top
    mov  h, eax

    ; The label / glyph text, fetched once.
    INVOKE GetWindowTextW, [esi].DRAWITEMSTRUCT.hwndItem, ADDR buf, 64

    ; A labelled glyph button ("+ New") lays its "+" and its label out as one
    ; centred group. The label width is measured with the label font; the group
    ; is (16px glyph + 4px gap + label), centred on the button.
    mov  hasGlyph, 0
    cmp  kind, UI_KIND_BUTTON_GLYPH
    jne  udb_layout_done
    cmp  ui_iconfont, 0
    je   udb_layout_done
    cmp  ui_font_gdi, 0
    je   udb_measure
    INVOKE SelectObject, [esi].DRAWITEMSTRUCT.hDC, ui_font_gdi
udb_measure:
    mov  mrc.left, 0
    mov  mrc.top, 0
    mov  mrc.right, 0
    mov  mrc.bottom, 0
    INVOKE DrawTextW, [esi].DRAWITEMSTRUCT.hDC, ADDR buf, -1, ADDR mrc, DT_CALCRECT OR DT_SINGLELINE
    mov  eax, mrc.right
    mov  textW, eax
    add  eax, 20                 ; + the 16px glyph and the 4px gap
    mov  edx, w
    sub  edx, eax
    sar  edx, 1
    add  edx, rc.left
    mov  glyphx, edx
    mov  hasGlyph, 1
udb_layout_done:

    INVOKE GdipCreateFromHDC, [esi].DRAWITEMSTRUCT.hDC, ADDR gfx
    test eax, eax
    jnz  udb_text
    cmp  gfx, 0
    je   udb_text

    INVOKE GdipSetSmoothingMode, gfx, SmoothingModeAntiAlias

    ; Ambient wash over the whole rect.
    INVOKE ui_ambient_color, ambientRole
    mov  ambientCr, eax
    INVOKE ui_fill_rect, gfx, rc.left, rc.top, w, h, ambientCr

    ; Rounded surface, inset 1px so the hairline border is not clipped.
    mov  eax, rc.left
    inc  eax
    mov  x, eax
    mov  eax, rc.top
    inc  eax
    mov  y, eax
    mov  eax, w
    sub  eax, 2
    mov  w, eax
    mov  eax, h
    sub  eax, 2
    mov  h, eax

    ; Focus draws its ring at inset 2 below; drop the inset-1 hairline here so a
    ; focused control shows one ring, not a hairline inside it (which reads as a
    ; doubled border / a second control).
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_FOCUS
    jz   udb_surface_border
    mov  borderCr, 0
udb_surface_border:
    INVOKE ui_round_rect, gfx, x, y, w, h, UI_RADIUS, fillCr, borderCr

    ; An icon button's glyph (or a labelled button's leading "+") is drawn with
    ; GDI+ (its family renders the Segoe Fluent Icons PUA codepoints reliably); a
    ; plain button's label is GDI below.
    cmp  kind, UI_KIND_ICON
    je   udb_icon_glyph
    cmp  kind, UI_KIND_BUTTON_GLYPH
    je   udb_lead_glyph
    jmp  udb_no_glyph
udb_icon_glyph:
    movzx eax, WORD PTR buf
    mov  glyph, eax
    cmp  glyph, 0
    je   udb_no_glyph
    INVOKE ui_draw_icon, gfx, glyph, ADDR rc, textCr
    jmp  udb_no_glyph
udb_lead_glyph:
    ; The centred "+" box, when the icon font loaded.
    cmp  hasGlyph, 0
    je   udb_no_glyph
    mov  eax, glyphx
    mov  gr.left, eax
    mov  eax, rc.top
    mov  gr.top, eax
    mov  eax, glyphx
    add  eax, 16
    mov  gr.right, eax
    mov  eax, rc.bottom
    mov  gr.bottom, eax
    INVOKE ui_draw_icon, gfx, ICON_ADD, ADDR gr, textCr
udb_no_glyph:
    ; Focus ring (ticket 04): a Fluent accent ring inset by 2px, stroke-only.
    ; On the accent-filled primary a white ring reads instead of accent-on-accent.
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_FOCUS
    jz   udb_no_focus
    mov  eax, rc.left
    add  eax, 2
    mov  x, eax
    mov  eax, rc.top
    add  eax, 2
    mov  y, eax
    mov  eax, rc.right
    sub  eax, rc.left
    sub  eax, 4
    mov  w, eax
    mov  eax, rc.bottom
    sub  eax, rc.top
    sub  eax, 4
    mov  h, eax
    mov  ecx, ui_accent
    cmp  kind, UI_KIND_BUTTON_PRIMARY
    jne  udb_focus_cr
    mov  ecx, WHITE
udb_focus_cr:
    INVOKE ui_round_rect, gfx, x, y, w, h, UI_RADIUS, 0, ecx
udb_no_focus:
    INVOKE GdipFlush, gfx, FlushIntentionSync
    INVOKE GdipDeleteGraphics, gfx

udb_text:
    ; Labels only. Icon buttons were painted in the GDI+ block above.
    cmp  kind, UI_KIND_ICON
    je   udb_done
    INVOKE SetBkMode, [esi].DRAWITEMSTRUCT.hDC, TRANSPARENT_BK
    INVOKE SetTextColor, [esi].DRAWITEMSTRUCT.hDC, textCr
    cmp  ui_font_gdi, 0
    je   udb_fmt
    INVOKE SelectObject, [esi].DRAWITEMSTRUCT.hDC, ui_font_gdi
udb_fmt:
    ; A labelled glyph button's text sits to the right of its "+"; every other
    ; label is centred.
    cmp  hasGlyph, 0
    je   udb_center_draw
    mov  eax, glyphx
    add  eax, 20
    mov  rc.left, eax
    INVOKE DrawTextW, [esi].DRAWITEMSTRUCT.hDC, ADDR buf, -1, ADDR rc, DT_LEFT OR DT_VCENTER OR DT_SINGLELINE
    jmp  udb_done
udb_center_draw:
    INVOKE DrawTextW, [esi].DRAWITEMSTRUCT.hDC, ADDR buf, -1, ADDR rc, DT_CENTER OR DT_VCENTER OR DT_SINGLELINE
udb_done:
    xor  eax, eax
    ret
ui_draw_button ENDP

; ---------------------------------------------------------------------------
; ui_draw_combo(dis) -> void. Paints one draw of an owner-draw ComboBox (ticket
; 03): either a closed selection face (itemID == -1, ODS_COMBOBOXEDIT) or an open
; list row. Both fill the ambient surface first, then draw the glyph; the face
; adds the Fluent surface, a hairline border, and the chevron, and is icon-only
; (ticket 07), while a row also draws its text. A selected row gets the accent
; tint and a 3px accent bar.
;
; The Shell's own list rows arrive here from the parent's WM_DRAWITEM. The face
; arrives from ui_paint_combo_dc's synthetic DRAWITEMSTRUCT, because the base
; ComboBox's classic border and arrow button are only removed by painting the
; whole client ourselves.
;
; The face's text and glyph come from the current selection (CB_GETCURSEL ->
; CB_GETLBTEXT/CB_GETITEMDATA); a row's glyph is DRAWITEMSTRUCT.itemData, the id
; shell.asm stashed with CB_SETITEMDATA. The open list box's own border and
; scrollbar stay classic - only the rows are skinned. See ADR-0004.
; ---------------------------------------------------------------------------
ui_draw_combo PROC USES ebx esi edi dis:DWORD
    LOCAL gfx:DWORD
    LOCAL ambientRole:DWORD
    LOCAL dark:DWORD
    LOCAL faceCr:DWORD
    LOCAL borderCr:DWORD
    LOCAL textCr:DWORD
    LOCAL hoverCr:DWORD
    LOCAL disabledCr:DWORD
    LOCAL ambientCr:DWORD
    LOCAL fillCr:DWORD
    LOCAL isFace:DWORD
    LOCAL facePainted:DWORD
    LOCAL slot:DWORD
    LOCAL sel:DWORD
    LOCAL glyph:DWORD
    LOCAL w:DWORD
    LOCAL h:DWORD
    LOCAL x:DWORD
    LOCAL y:DWORD
    LOCAL rc:RECT
    LOCAL gr:RECT
    LOCAL tr:RECT
    LOCAL buf[64]:WORD

    mov  esi, dis
    mov  gfx, 0
    mov  ambientRole, UI_AMBIENT_BG
    mov  facePainted, 0
    mov  slot, 0

    ; rcItem -> rc.
    mov  eax, [esi].DRAWITEMSTRUCT.rcItem.left
    mov  rc.left, eax
    mov  eax, [esi].DRAWITEMSTRUCT.rcItem.top
    mov  rc.top, eax
    mov  eax, [esi].DRAWITEMSTRUCT.rcItem.right
    mov  rc.right, eax
    mov  eax, [esi].DRAWITEMSTRUCT.rcItem.bottom
    mov  rc.bottom, eax

    ; Ambient from the registration; the default stands if unattached.
    mov  eax, [esi].DRAWITEMSTRUCT.hwndItem
    INVOKE ui_find, eax
    cmp  eax, -1
    je   ucc_slot_done
    imul eax, eax, SIZEOF UiSlot
    add  eax, OFFSET ui_slots
    mov  ecx, [eax].UiSlot.ambient
    mov  ambientRole, ecx
    mov  slot, eax
ucc_slot_done:

    INVOKE theme_is_dark
    mov  dark, eax
    cmp  dark, 0
    je   ucc_light
    mov  faceCr, COMBO_FACE_DARK
    mov  borderCr, BORDER_DARK
    mov  textCr, TEXT_DARK
    mov  hoverCr, HOVER_DARK
    mov  disabledCr, DISABLED_DARK
    jmp  ucc_colors_done
ucc_light:
    mov  faceCr, COMBO_FACE_LIGHT
    mov  borderCr, BORDER_LIGHT
    mov  textCr, TEXT_LIGHT
    mov  hoverCr, HOVER_LIGHT
    mov  disabledCr, DISABLED_LIGHT
ucc_colors_done:

    ; Selection face, or a list row?
    mov  isFace, 0
    mov  eax, [esi].DRAWITEMSTRUCT.itemID
    cmp  eax, 0FFFFFFFFh
    je   ucc_face
    test [esi].DRAWITEMSTRUCT.itemState, ODS_COMBOBOXEDIT
    jnz  ucc_face
    jmp  ucc_row

ucc_face:
    mov  isFace, 1
    ; Paint the face from the control's *whole* client rect, not the field
    ; sub-rect the ComboBox hands to a WM_DRAWITEM face draw. The field rect
    ; excludes the drop-down arrow area, so a field-width face would leave the
    ; arrow area showing the ui_paint_combo face beneath (and put its chevron at
    ; a different x): the doubled drop-down. With the client rect, the WM_DRAWITEM
    ; face and ui_paint_combo's face are identical, so whichever paints last the
    ; result is one face and one chevron - but only if both draw through a DC
    ; that spans the whole client. The ComboBox's own face DC does not; it is
    ; clipped to the field rect. ui_draw_item therefore re-targets that face
    ; through our own DC. See ui_paint_combo_dc.
    mov  eax, [esi].DRAWITEMSTRUCT.hwndItem
    lea  ecx, rc
    INVOKE GetClientRect, eax, ecx
    mov  glyph, UI_GLYPH_NONE
    mov  WORD PTR buf, 0
    INVOKE SendMessageW, [esi].DRAWITEMSTRUCT.hwndItem, CB_GETCURSEL, 0, 0
    mov  sel, eax
    cmp  eax, -1
    je   ucc_face_cached
    INVOKE SendMessageW, [esi].DRAWITEMSTRUCT.hwndItem, CB_GETLBTEXT, sel, ADDR buf
    INVOKE SendMessageW, [esi].DRAWITEMSTRUCT.hwndItem, CB_GETITEMDATA, sel, 0
    mov  glyph, eax
    ; The ComboBox repaints its field mid-selection, when CB_GETCURSEL can be -1
    ; or CB_GETITEMDATA can come back 0 / CB_ERR: remember the glyph per control
    ; and fall back to it so the face never flashes blank (a white box).
    cmp  eax, UI_GLYPH_RECT
    jb   ucc_face_cached
    cmp  eax, UI_GLYPH_CLOCK
    ja   ucc_face_cached
    cmp  slot, 0
    je   ucc_paint
    mov  ecx, slot
    mov  [ecx].UiSlot.glyph, eax
    jmp  ucc_paint
ucc_face_cached:
    cmp  slot, 0
    je   ucc_paint
    mov  ecx, slot
    mov  eax, [ecx].UiSlot.glyph
    mov  glyph, eax
    jmp  ucc_paint

ucc_row:
    ; The row's glyph id is what CB_SETITEMDATA stashed for this index.
    mov  eax, [esi].DRAWITEMSTRUCT.itemData
    mov  glyph, eax
    mov  eax, [esi].DRAWITEMSTRUCT.itemID
    mov  sel, eax
    INVOKE SendMessageW, [esi].DRAWITEMSTRUCT.hwndItem, CB_GETLBTEXT, sel, ADDR buf

ucc_paint:
    ; A disabled control mutes its text.
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_DISABLED
    jz   ucc_not_disabled
    mov  eax, disabledCr
    mov  textCr, eax
ucc_not_disabled:

    ; Full-rect size.
    mov  eax, rc.right
    sub  eax, rc.left
    mov  w, eax
    mov  eax, rc.bottom
    sub  eax, rc.top
    mov  h, eax

    INVOKE GdipCreateFromHDC, [esi].DRAWITEMSTRUCT.hDC, ADDR gfx
    test eax, eax
    jnz  ucc_text
    cmp  gfx, 0
    je   ucc_text
    INVOKE GdipSetSmoothingMode, gfx, SmoothingModeAntiAlias

    ; Ambient wash over the whole row.
    INVOKE ui_ambient_color, ambientRole
    mov  ambientCr, eax
    INVOKE ui_fill_rect, gfx, rc.left, rc.top, w, h, ambientCr

    cmp  isFace, 0
    je   ucc_draw_row

    ; --- the closed selection face -----------------------------------------
    ; Hover lightens the surface; the pressed state is not delivered here.
    mov  eax, faceCr
    mov  edx, [esi].DRAWITEMSTRUCT.hwndItem
    cmp  edx, ui_hot
    jne  ucc_face_fill
    mov  eax, hoverCr
ucc_face_fill:
    mov  fillCr, eax
    ; Focus draws its ring at inset 2 below; drop the inset-1 hairline so a
    ; focused face shows one ring, not a doubled border.
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_FOCUS
    jz   ucc_face_hairline
    mov  borderCr, 0
ucc_face_hairline:
    ; Rounded face, inset 1px so the hairline border is not clipped.
    mov  eax, rc.left
    inc  eax
    mov  x, eax
    mov  eax, rc.top
    inc  eax
    mov  y, eax
    mov  eax, w
    sub  eax, 2
    mov  ecx, eax                 ; face width
    mov  eax, h
    sub  eax, 2                   ; face height
    INVOKE ui_round_rect, gfx, x, y, ecx, eax, UI_RADIUS, fillCr, borderCr

    ; The selected row's glyph, on the left.
    cmp  glyph, UI_GLYPH_NONE
    je   ucc_face_chev
    mov  eax, rc.left
    add  eax, 6
    mov  gr.left, eax
    mov  eax, rc.top
    mov  ecx, rc.bottom
    add  eax, ecx
    sar  eax, 1
    sub  eax, 8
    mov  gr.top, eax
    mov  eax, gr.left
    add  eax, 16
    mov  gr.right, eax
    mov  eax, gr.top
    add  eax, 16
    mov  gr.bottom, eax
    INVOKE ui_draw_glyph_id, gfx, glyph, ADDR gr, textCr

ucc_face_chev:
    ; The chevron, on the right.
    mov  eax, rc.right
    sub  eax, 20
    mov  gr.left, eax
    mov  eax, rc.top
    mov  ecx, rc.bottom
    add  eax, ecx
    sar  eax, 1
    sub  eax, 8
    mov  gr.top, eax
    mov  eax, gr.left
    add  eax, 16
    mov  gr.right, eax
    mov  eax, gr.top
    add  eax, 16
    mov  gr.bottom, eax
    INVOKE ui_draw_icon, gfx, ICON_CHEVRON, ADDR gr, textCr

    ; Focus ring (ticket 04): a stroke-only accent ring, 2px in.
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_FOCUS
    jz   ucc_flush
    mov  eax, rc.left
    add  eax, 2
    mov  x, eax
    mov  eax, rc.top
    add  eax, 2
    mov  y, eax
    mov  eax, rc.right
    sub  eax, rc.left
    sub  eax, 4
    mov  w, eax
    mov  eax, rc.bottom
    sub  eax, rc.top
    sub  eax, 4
    mov  h, eax
    INVOKE ui_round_rect, gfx, x, y, w, h, UI_RADIUS, 0, ui_accent
    jmp  ucc_flush

ucc_draw_row:
    ; --- a list row ---------------------------------------------------------
    mov  eax, [esi].DRAWITEMSTRUCT.itemState
    test eax, ODS_SELECTED
    jz   ucc_row_glyph
    ; Accent-tinted fill, then a 3px accent bar inset vertically by 4px.
    INVOKE ui_tint, ui_accent, ambientCr, SEL_MIX
    mov  edx, eax
    INVOKE ui_fill_rect, gfx, rc.left, rc.top, w, h, edx
    mov  eax, rc.left
    add  eax, 2
    mov  ecx, rc.top
    add  ecx, 4
    mov  edx, h
    sub  edx, 8
    INVOKE ui_fill_rect, gfx, eax, ecx, 3, edx, ui_accent

ucc_row_glyph:
    cmp  glyph, UI_GLYPH_NONE
    je   ucc_flush
    mov  eax, rc.left
    add  eax, 8
    mov  gr.left, eax
    mov  eax, rc.top
    mov  ecx, rc.bottom
    add  eax, ecx
    sar  eax, 1
    sub  eax, 8
    mov  gr.top, eax
    mov  eax, gr.left
    add  eax, 16
    mov  gr.right, eax
    mov  eax, gr.top
    add  eax, 16
    mov  gr.bottom, eax
    INVOKE ui_draw_glyph_id, gfx, glyph, ADDR gr, textCr

ucc_flush:
    INVOKE GdipFlush, gfx, FlushIntentionSync
    INVOKE GdipDeleteGraphics, gfx
    mov  facePainted, 1           ; GDI+ painted this draw; see ucc_text

ucc_text:
    ; The closed face is icon-only (ticket 07): the glyph and chevron name the
    ; selection, matching the Win11 Snipping Tool, so the label is dropped. If
    ; GDI+ never drew the face, keep the label so the control is never blank -
    ; the same best-effort fallback the rest of the skin uses.
    cmp  isFace, 0
    je   ucc_text_label
    cmp  facePainted, 0
    jne  ucc_text_done

ucc_text_label:
    ; Text with GDI for ClearType, inset past the glyph and (on the face) before
    ; the chevron.
    INVOKE SetBkMode, [esi].DRAWITEMSTRUCT.hDC, TRANSPARENT_BK
    INVOKE SetTextColor, [esi].DRAWITEMSTRUCT.hDC, textCr
    cmp  ui_font_gdi, 0
    je   ucc_fmt
    INVOKE SelectObject, [esi].DRAWITEMSTRUCT.hDC, ui_font_gdi
ucc_fmt:
    mov  eax, rc.left
    mov  tr.left, eax
    mov  eax, rc.right
    mov  tr.right, eax
    mov  eax, rc.top
    mov  tr.top, eax
    mov  eax, rc.bottom
    mov  tr.bottom, eax
    add  tr.left, 6
    cmp  glyph, UI_GLYPH_NONE
    je   ucc_text_face
    add  tr.left, 18               ; past the 16px glyph and its gap
ucc_text_face:
    cmp  isFace, 0
    je   ucc_text_draw
    sub  tr.right, 22              ; leave room for the chevron
ucc_text_draw:
    INVOKE DrawTextW, [esi].DRAWITEMSTRUCT.hDC, ADDR buf, -1, ADDR tr, DT_LEFT OR DT_VCENTER OR DT_SINGLELINE
ucc_text_done:
    xor  eax, eax
    ret
ui_draw_combo ENDP

; ---------------------------------------------------------------------------
; ui_paint_combo(hwnd) -> void. The subclass's WM_PAINT: BeginPaint (which
; validates the update region) and paint the whole client through
; ui_paint_combo_dc, then EndPaint.
; ---------------------------------------------------------------------------
ui_paint_combo PROC hwnd:DWORD
    LOCAL ps:PAINTSTRUCT

    INVOKE BeginPaint, hwnd, ADDR ps
    test eax, eax
    jz   upc_done
    INVOKE ui_paint_combo_dc, hwnd, eax
    INVOKE EndPaint, hwnd, ADDR ps
upc_done:
    ret
ui_paint_combo ENDP

; ---------------------------------------------------------------------------
; ui_paint_combo_dc(hwnd, hdc) -> void. Paints a drop-down's closed face - the
; whole client, its glyph, chevron and focus ring - into an explicit DC, as a
; synthetic DRAWITEMSTRUCT (itemID == -1, the selection field, focused when the
; control has focus). The base ComboBox draws a classic 3-D border (a grey edge
; on the top/left of the client) and a drop-down arrow button that owner-draw's
; rcItem never covers; taking the whole paint ourselves removes both, and
; reusing ui_draw_combo keeps all the face drawing in one place.
;
; Two callers, and they must agree:
;
;   * ui_paint_combo, from the subclass's WM_PAINT, with BeginPaint's DC; and
;   * ui_draw_item, for the ComboBox's own face WM_DRAWITEM.
;
; The second caller must not draw into the DC the ComboBox supplies. That DC is
; clipped to the *field* rect - the face minus the drop-down arrow button -
; while the face is laid out across the whole client. Painting a whole-client
; face through the field clip lays its fill and border over only the left ~34px
; of what WM_PAINT already drew there, slicing the left edge off anything that
; spans the client. The focus ring shows it worst: only a focused whole-client
; pass draws one, so a selection leaves a ring with its left side wiped - the
; broken "focus border" box across a just-chosen drop-down. ui_draw_item hands
; this function its own full-client DC instead, so both callers are identical,
; which is exactly what ucc_face's whole-client geometry assumes.
; ---------------------------------------------------------------------------
ui_paint_combo_dc PROC USES esi hwnd:DWORD, hdc:DWORD
    LOCAL dis:DRAWITEMSTRUCT

    mov  dis.CtlType, ODT_COMBOBOX
    mov  dis.CtlID, 0
    mov  dis.itemID, 0FFFFFFFFh        ; the selection field
    mov  dis.itemAction, 0
    mov  dis.itemState, 0
    INVOKE GetFocus
    cmp  eax, hwnd
    jne  updc_nofocus
    mov  dis.itemState, ODS_FOCUS
updc_nofocus:
    mov  eax, hwnd
    mov  dis.hwndItem, eax
    mov  eax, hdc
    mov  dis.hDC, eax
    lea  eax, dis.rcItem
    INVOKE GetClientRect, hwnd, eax
    mov  dis.itemData, 0

    INVOKE ui_draw_combo, ADDR dis
    ret
ui_paint_combo_dc ENDP

; ---------------------------------------------------------------------------
; ui_tint(accent, base, pct) -> COLORREF. base blended pct percent toward accent,
; channel by channel. Draws the selected-row surface so it follows the user's
; accent without a second hardcoded palette.
; ---------------------------------------------------------------------------
ui_tint PROC USES ebx esi edi accent:DWORD, base:DWORD, pct:DWORD
    LOCAL b:DWORD

    xor  ebx, ebx                  ; result
    xor  esi, esi                  ; channel shift: 0, 8, 16
    mov  edi, 3
ut_loop:
    mov  eax, accent
    mov  ecx, esi
    shr  eax, cl
    and  eax, 0FFh                 ; accent channel
    mov  edx, base
    shr  edx, cl
    and  edx, 0FFh                 ; base channel
    mov  b, edx
    sub  eax, edx                  ; a - b
    imul eax, pct
    cdq
    mov  ecx, 100
    idiv ecx                       ; (a - b) * pct / 100
    add  eax, b
    test eax, eax
    jns  ut_hi
    xor  eax, eax                  ; clamp below 0
ut_hi:
    cmp  eax, 0FFh
    jle  ut_put
    mov  eax, 0FFh                 ; clamp above 255
ut_put:
    mov  ecx, esi
    shl  eax, cl
    or   ebx, eax
    add  esi, 8
    dec  edi
    jnz  ut_loop
    mov  eax, ebx
    ret
ui_tint ENDP

; ---------------------------------------------------------------------------
; ui_draw_glyph_id(gfx, id, prc, cr) -> void. Draws the drop-down glyph for a
; UI_GLYPH_* id, centred on prc, in cr: the Shell's mode icons and the Delay
; clock as vectors on a 16x16 grid. Unlike ui_draw_icon it never uses the icon
; font - these shapes have no codepoint - so it is always available.
; ---------------------------------------------------------------------------
ui_draw_glyph_id PROC USES ebx esi edi gfx:DWORD, id:DWORD, prc:DWORD, cr:DWORD
    LOCAL pen:DWORD
    LOCAL argb:DWORD
    LOCAL ox:DWORD
    LOCAL oy:DWORD
    LOCAL ex:DWORD
    LOCAL ey:DWORD

    mov  pen, 0
    cmp  gfx, 0
    je   ugd_done
    cmp  id, UI_GLYPH_NONE
    je   ugd_done

    ; ox/oy place the 16x16 grid's top-left at the cell centre minus 8.
    mov  esi, prc
    mov  eax, [esi].RECT.left
    add  eax, [esi].RECT.right
    sar  eax, 1
    sub  eax, 8
    mov  ox, eax
    mov  eax, [esi].RECT.top
    add  eax, [esi].RECT.bottom
    sar  eax, 1
    sub  eax, 8
    mov  oy, eax

    INVOKE ui_argb, cr
    mov  argb, eax
    INVOKE GdipCreatePen1, argb, PEN_W_ICON, UnitPixel, ADDR pen
    test eax, eax
    jnz  ugd_done
    cmp  pen, 0
    je   ugd_done
    INVOKE GdipSetPenStartCap, pen, LineCapRound
    INVOKE GdipSetPenEndCap, pen, LineCapRound
    INVOKE GdipSetPenLineJoin, pen, LineJoinRound

    mov  eax, id
    cmp  eax, UI_GLYPH_RECT
    je   ugd_rect
    cmp  eax, UI_GLYPH_WINDOW
    je   ugd_win
    cmp  eax, UI_GLYPH_FULL
    je   ugd_full
    cmp  eax, UI_GLYPH_FREE
    je   ugd_free
    cmp  eax, UI_GLYPH_CLOCK
    je   ugd_clock
    jmp  ugd_cleanup

ugd_rect:
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_rect, 5, ox, oy
    jmp  ugd_cleanup
ugd_win:
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_win_a, 5, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_win_b, 2, ox, oy
    jmp  ugd_cleanup
ugd_full:
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_full_1, 3, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_full_2, 3, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_full_3, 3, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_full_4, 3, ox, oy
    jmp  ugd_cleanup
ugd_free:
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_free, 7, ox, oy
    jmp  ugd_cleanup
ugd_clock:
    mov  eax, ox
    add  eax, 2
    mov  ex, eax
    mov  eax, oy
    add  eax, 2
    mov  ey, eax
    INVOKE GdipDrawEllipseI, gfx, pen, ex, ey, 12, 12
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_hand_v, 2, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET gl_hand_h, 2, ox, oy

ugd_cleanup:
    INVOKE GdipDeletePen, pen
ugd_done:
    ret
ui_draw_glyph_id ENDP

; ---------------------------------------------------------------------------
; ui_load_icon_font() -> void. Builds ui_iconfont from a Segoe Fluent Icons .ttf
; read into a private GDI+ collection. Best-effort: on any failure ui_iconfont
; stays 0 and ui_draw_icon falls back to the vector glyphs.
;
; The face is taken from the collection's own family list, never looked up by
; name: this image's installed-font collection omits the Segoe families (GDI+
; returns FontFamilyNotFound for "Segoe UI" and "Segoe Fluent Icons" alike,
; though GDI enumerates them and a .NET probe resolves them), and a by-name
; lookup inside the private collection fails the same way. The file itself is
; perfectly readable, so the family handle is the reliable route.
; ---------------------------------------------------------------------------
ui_load_icon_font PROC USES ebx esi edi
    LOCAL count:DWORD
    LOCAL found:DWORD

    mov  ui_iconfont, 0
    mov  ui_iconcoll, 0
    mov  ui_iconfamily, 0

    INVOKE GdipNewPrivateFontCollection, ADDR ui_iconcoll
    test eax, eax
    jnz  ulif_done
    cmp  ui_iconcoll, 0
    je   ulif_done

    ; %WINDIR%\Fonts\SegoeIcons.ttf, else %WINDIR%\Fonts\segmdl2.ttf.
    INVOKE ui_icon_path, OFFSET icofile_icons
    INVOKE GdipPrivateAddFontFile, ui_iconcoll, ADDR ui_fontpath
    test eax, eax
    jz   ulif_families
    INVOKE ui_icon_path, OFFSET icofile_mdl2
    INVOKE GdipPrivateAddFontFile, ui_iconcoll, ADDR ui_fontpath
    test eax, eax
    jnz  ulif_done

ulif_families:
    mov  count, 0
    INVOKE GdipGetFontCollectionFamilyCount, ui_iconcoll, ADDR count
    cmp  count, 0
    jle  ulif_done
    cmp  count, 4
    jle  ulif_cap
    mov  count, 4
ulif_cap:
    INVOKE GdipGetFontCollectionFamilyList, ui_iconcoll, count, ADDR ui_iconfamarr, ADDR found
    cmp  found, 0
    jle  ulif_done
    mov  eax, ui_iconfamarr
    mov  ui_iconfamily, eax

    INVOKE GdipCreateFont, ui_iconfamily, ICON_EM, 0, UnitPixel, ADDR ui_iconfont
ulif_done:
    ret
ui_load_icon_font ENDP

; ---------------------------------------------------------------------------
; ui_icon_path(sufx) -> void. Writes GetWindowsDirectoryW(sufx) into ui_fontpath,
; where sufx is a wide "\Fonts\<file>.ttf".
; ---------------------------------------------------------------------------
ui_icon_path PROC USES esi edi sufx:DWORD
    INVOKE GetWindowsDirectoryW, ADDR ui_fontpath, 260
    lea  edi, ui_fontpath
    lea  edi, [edi + eax*2]
    mov  esi, sufx
uip_copy:
    mov  ax, [esi]
    mov  [edi], ax
    test ax, ax
    jz   uip_done
    add  esi, 2
    add  edi, 2
    jmp  uip_copy
uip_done:
    ret
ui_icon_path ENDP

; ---------------------------------------------------------------------------
; ui_draw_glyph(gfx, glyph, prc, cr) -> void. Draws the codepoint glyph from the
; loaded icon font, centred in the button rect, in the colour cr. The layout rect
; is the button as REALs (x87 float conversion) with centre/centre alignment, and
; the brush is a solid fill in cr. All GDI+ objects are freed.
; ---------------------------------------------------------------------------
ui_draw_glyph PROC USES ebx esi edi gfx:DWORD, glyph:DWORD, prc:DWORD, cr:DWORD
    LOCAL brush:DWORD
    LOCAL sfmt:DWORD
    LOCAL rf:RectF
    LOCAL gstr[4]:WORD

    mov  brush, 0
    mov  sfmt, 0

    ; glyph -> a one-character wide string.
    mov  eax, glyph
    mov  WORD PTR gstr, ax
    mov  WORD PTR [gstr+2], 0

    ; rf = the button rect, as REALs.
    mov  esi, prc
    fild DWORD PTR [esi]
    fstp DWORD PTR rf.x
    fild DWORD PTR [esi+4]
    fstp DWORD PTR rf.y
    mov  eax, [esi+8]
    sub  eax, [esi]
    mov  DWORD PTR rf.w, eax
    fild DWORD PTR rf.w
    fstp DWORD PTR rf.w
    mov  eax, [esi+12]
    sub  eax, [esi+4]
    mov  DWORD PTR rf.h, eax
    fild DWORD PTR rf.h
    fstp DWORD PTR rf.h

    INVOKE ui_argb, cr
    mov  ebx, eax
    INVOKE GdipCreateSolidFill, ebx, ADDR brush
    cmp  brush, 0
    je   udg_done

    INVOKE GdipCreateStringFormat, 0, 0, ADDR sfmt
    cmp  sfmt, 0
    je   udg_brush

    INVOKE GdipSetStringFormatAlign, sfmt, SA_CENTER
    INVOKE GdipSetStringFormatLineAlign, sfmt, SA_CENTER
    INVOKE GdipDrawString, gfx, ADDR gstr, 1, ui_iconfont, ADDR rf, sfmt, brush
    INVOKE GdipDeleteStringFormat, sfmt

udg_brush:
    INVOKE GdipDeleteBrush, brush
udg_done:
    ret
ui_draw_glyph ENDP

; ---------------------------------------------------------------------------
; ui_draw_icon(gfx, glyph, prc, cr) -> void. Draws the tool icon for a Segoe
; Fluent Icons codepoint, centred on prc, in cr. When the icon font loaded
; (ui_load_icon_font), the real font glyph is drawn via GdipDrawString; otherwise
; the codepoint is hand-drawn as a vector polyline (ic_* on a 16x16 grid) with an
; antialiased pen, so the button is never blank. Best-effort: any failure draws
; nothing.
; ---------------------------------------------------------------------------
ui_draw_icon PROC USES ebx gfx:DWORD, glyph:DWORD, prc:DWORD, cr:DWORD
    LOCAL pen:DWORD
    LOCAL argb:DWORD
    LOCAL ox:DWORD
    LOCAL oy:DWORD

    mov  pen, 0
    cmp  gfx, 0
    je   udi_done
    cmp  glyph, 0
    je   udi_done

    ; The real font glyph when the icon font loaded; the vectors otherwise.
    cmp  ui_iconfont, 0
    je   udi_vectors
    INVOKE ui_draw_glyph, gfx, glyph, prc, cr
    jmp  udi_done

udi_vectors:
    ; ox/oy place the 16x16 grid's top-left at the button's centre minus 8.
    mov  esi, prc
    mov  eax, [esi].RECT.left
    add  eax, [esi].RECT.right
    sar  eax, 1
    sub  eax, 8
    mov  ox, eax
    mov  eax, [esi].RECT.top
    add  eax, [esi].RECT.bottom
    sar  eax, 1
    sub  eax, 8
    mov  oy, eax

    INVOKE ui_argb, cr
    mov  argb, eax
    INVOKE GdipCreatePen1, argb, PEN_W_ICON, UnitPixel, ADDR pen
    test eax, eax
    jnz  udi_done
    cmp  pen, 0
    je   udi_done
    INVOKE GdipSetPenStartCap, pen, LineCapRound
    INVOKE GdipSetPenEndCap, pen, LineCapRound
    INVOKE GdipSetPenLineJoin, pen, LineJoinRound

    mov  eax, glyph
    cmp  eax, ICON_SAVE
    je   udi_save
    cmp  eax, ICON_COPY
    je   udi_copy
    cmp  eax, ICON_PEN
    je   udi_pen
    cmp  eax, ICON_HILITE
    je   udi_hl
    cmp  eax, ICON_ERASER
    je   udi_er
    cmp  eax, ICON_UNDO
    je   udi_undo
    cmp  eax, ICON_CHEVRON
    je   udi_chev
    jmp  udi_cleanup

udi_save:
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_save_a, 5, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_save_b, 4, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_save_c, 5, ox, oy
    jmp  udi_cleanup
udi_copy:
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_copy_a, 5, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_copy_b, 5, ox, oy
    jmp  udi_cleanup
udi_pen:
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_pen_a, 7, ox, oy
    jmp  udi_cleanup
udi_hl:
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_hl_a, 5, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_hl_b, 4, ox, oy
    jmp  udi_cleanup
udi_er:
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_er_a, 5, ox, oy
    jmp  udi_cleanup
udi_undo:
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_undo_a, 5, ox, oy
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_undo_b, 4, ox, oy
    jmp  udi_cleanup
udi_chev:
    INVOKE ui_draw_poly, gfx, pen, OFFSET ic_chev_a, 3, ox, oy

udi_cleanup:
    INVOKE GdipDeletePen, pen
udi_done:
    ret
ui_draw_icon ENDP

; ---------------------------------------------------------------------------
; ui_draw_poly(gfx, pen, ppts, n, ox, oy) -> void. Translates n GpPoints by
; (ox, oy) into the shared scratch and draws them as one open polyline.
; ---------------------------------------------------------------------------
ui_draw_poly PROC USES ebx esi edi gfx:DWORD, pen:DWORD, ppts:DWORD, n:DWORD, ox:DWORD, oy:DWORD
    mov  esi, ppts
    mov  edi, OFFSET ui_ptbuf
    mov  ecx, n
udp_loop:
    test ecx, ecx
    jz   udp_draw
    mov  eax, [esi].POINT.x
    add  eax, ox
    mov  [edi].POINT.x, eax
    mov  eax, [esi].POINT.y
    add  eax, oy
    mov  [edi].POINT.y, eax
    add  esi, SIZEOF POINT
    add  edi, SIZEOF POINT
    dec  ecx
    jmp  udp_loop
udp_draw:
    INVOKE GdipDrawLinesI, gfx, pen, OFFSET ui_ptbuf, n
    ret
ui_draw_poly ENDP

; ---------------------------------------------------------------------------
; ui_ambient_color(role) -> COLORREF. The surface behind a control, per theme.
; ---------------------------------------------------------------------------
ui_ambient_color PROC USES ebx role:DWORD
    INVOKE theme_is_dark
    test eax, eax
    jz   uac_light
    cmp  role, UI_AMBIENT_FACE
    je   uac_dark_face
    mov  eax, AMB_BG_DARK
    ret
uac_dark_face:
    mov  eax, AMB_FACE_DARK
    ret
uac_light:
    cmp  role, UI_AMBIENT_FACE
    je   uac_light_face
    mov  eax, AMB_BG_LIGHT
    ret
uac_light_face:
    mov  eax, AMB_FACE_LIGHT
    ret
ui_ambient_color ENDP

; ---------------------------------------------------------------------------
; ui_argb(colorref) -> ARGB. COLORREF 0x00BBGGRR -> 0xFFRRGGBB, swapped for
; GDI+'s channel order with an opaque alpha.
; ---------------------------------------------------------------------------
ui_argb PROC colorref:DWORD
    mov  eax, colorref
    mov  edx, eax
    and  edx, 0FFh
    shl  edx, 16                  ; r << 16
    mov  ecx, eax
    shr  ecx, 8
    and  ecx, 0FFh
    shl  ecx, 8                   ; g << 8
    or   edx, ecx
    mov  ecx, eax
    shr  ecx, 16
    and  ecx, 0FFh                ; b
    or   edx, ecx
    or   edx, 0FF000000h          ; opaque
    mov  eax, edx
    ret
ui_argb ENDP

; ---------------------------------------------------------------------------
; ui_fill_rect(gfx, x, y, w, h, colorref) -> void. One opaque solid fill.
; ---------------------------------------------------------------------------
ui_fill_rect PROC USES ebx gfx:DWORD, x:DWORD, y:DWORD, w:DWORD, h:DWORD, colorref:DWORD
    LOCAL brush:DWORD
    LOCAL argb:DWORD
    mov  brush, 0
    INVOKE ui_argb, colorref
    mov  argb, eax
    INVOKE GdipCreateSolidFill, argb, ADDR brush
    test eax, eax
    jnz  ufr_done
    cmp  brush, 0
    je   ufr_done
    INVOKE GdipFillRectangleI, gfx, brush, x, y, w, h
    INVOKE GdipDeleteBrush, brush
ufr_done:
    ret
ui_fill_rect ENDP

; ---------------------------------------------------------------------------
; ui_round_rect(gfx, x, y, w, h, radius, fillCr, borderCr) -> void. One
; antialiased rounded rectangle: four arcs closed into a path, filled, and (when
; borderCr is nonzero) stroked with a 1px border. All GDI+ objects are freed.
; ---------------------------------------------------------------------------
ui_round_rect PROC USES ebx esi edi gfx:DWORD, x:DWORD, y:DWORD, w:DWORD, h:DWORD, radius:DWORD, fillCr:DWORD, borderCr:DWORD
    LOCAL path:DWORD
    LOCAL brush:DWORD
    LOCAL pen:DWORD
    LOCAL d:DWORD
    LOCAL argb:DWORD

    mov  path, 0
    mov  brush, 0
    mov  pen, 0

    INVOKE GdipCreatePath, FillModeWinding, ADDR path
    test eax, eax
    jnz  urr_done
    cmp  path, 0
    je   urr_done

    mov  eax, radius
    shl  eax, 1
    mov  d, eax                   ; arc box is 2r x 2r

    ; TL(180), TR(270), BR(0), BL(90), +90 each; AddArc lines between them.
    INVOKE GdipAddPathArcI, path, x, y, d, d, ARCF_180, ARCF_90
    mov  eax, x
    add  eax, w
    sub  eax, d
    INVOKE GdipAddPathArcI, path, eax, y, d, d, ARCF_270, ARCF_90
    mov  eax, x
    add  eax, w
    sub  eax, d
    mov  edx, y
    add  edx, h
    sub  edx, d
    INVOKE GdipAddPathArcI, path, eax, edx, d, d, ARCF_0, ARCF_90
    mov  edx, y
    add  edx, h
    sub  edx, d
    INVOKE GdipAddPathArcI, path, x, edx, d, d, ARCF_90, ARCF_90
    INVOKE GdipClosePathFigure, path

    ; Fill (skipped when fillCr == 0, which draws a stroke-only ring).
    cmp  fillCr, 0
    je   urr_border
    INVOKE ui_argb, fillCr
    mov  argb, eax
    INVOKE GdipCreateSolidFill, argb, ADDR brush
    test eax, eax
    jnz  urr_cleanup
    cmp  brush, 0
    je   urr_cleanup
    INVOKE GdipFillPath, gfx, brush, path

    ; Border.
urr_border:
    cmp  borderCr, 0
    je   urr_cleanup
    INVOKE ui_argb, borderCr
    mov  argb, eax
    INVOKE GdipCreatePen1, argb, PEN_W_1, UnitPixel, ADDR pen
    test eax, eax
    jnz  urr_cleanup
    cmp  pen, 0
    je   urr_cleanup
    INVOKE GdipDrawPath, gfx, pen, path

urr_cleanup:
    cmp  pen, 0
    je   urr_c1
    INVOKE GdipDeletePen, pen
urr_c1:
    cmp  brush, 0
    je   urr_c2
    INVOKE GdipDeleteBrush, brush
urr_c2:
    cmp  path, 0
    je   urr_done
    INVOKE GdipDeletePath, path
urr_done:
    ret
ui_round_rect ENDP

; ---------------------------------------------------------------------------
; ui_resolve_accent() -> void. Sets ui_accent to the user's accent colour, or to
; ACCENT_FALLBACK. DwmGetColorizationColor is resolved once and cached; it
; returns 0xAARRGGBB, converted here to a COLORREF. Best-effort: any failure
; keeps the fallback.
; ---------------------------------------------------------------------------
ui_resolve_accent PROC
    mov  ui_accent, ACCENT_FALLBACK

    mov  eax, pfn_DwmGetColorizationColor
    test eax, eax
    jnz  ura_call                 ; already resolved

    INVOKE LoadLibraryA, OFFSET dwmapi_dll
    test eax, eax
    jz   ura_done
    INVOKE GetProcAddress, eax, OFFSET fn_dwmcolor
    mov  pfn_DwmGetColorizationColor, eax
    test eax, eax
    jz   ura_done

ura_call:
    mov  eax, pfn_DwmGetColorizationColor
    push OFFSET ura_opaque
    push OFFSET ura_color
    call eax
    test eax, eax
    jnz  ura_done                 ; nonzero HRESULT: keep the fallback

    ; ARGB (0xAARRGGBB) -> COLORREF (0x00BBGGRR), swapping the R and B bytes.
    mov  ecx, ura_color
    mov  eax, ecx
    shr  eax, 16
    and  eax, 0FFh                ; r
    mov  edx, ecx
    shr  edx, 8
    and  edx, 0FFh                ; g
    shl  edx, 8
    or   eax, edx                 ; r | g << 8
    and  ecx, 0FFh                ; b
    shl  ecx, 16
    or   eax, ecx                 ; r | g << 8 | b << 16
    mov  ui_accent, eax

ura_done:
    ret
ui_resolve_accent ENDP

END
