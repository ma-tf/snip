; ink.asm
; The annotation engine: the ink the Editor draws over a Snip (ticket 06).
;
; The model is a command log, not baked pixels. Each Pen or Highlighter mark is
; a Stroke - a tool, a colour, a width, and the sampled points of one press-to-
; release drag. The Eraser is an operation too: it removes whole strokes. Undo
; pops the last operation and replays the log. Replay means: copy the Pristine
; bitmap into Working, then draw every live stroke onto Working with GDI+, whose
; antialiasing is why GDI+ is here at all. Pristine is never drawn on, so the
; captured pixels are always recoverable and Undo stops at the pristine Snip.
;
; A stroke is uncommitted until ink_end. While the mouse is down, Working still
; holds only committed ink and ink_preview draws the in-progress stroke straight
; onto the paint DC; that way a translucent Highlighter is never double-blended
; across the frames of its own drag. ink_end draws the stroke once into Working,
; where it belongs.
;
; GDI+ draws onto a 32bpp DIB without a usable alpha channel, so after any
; drawing pass we force Working's alpha back to 255. Rectangular Snips are fully
; opaque, so that is correct today; a free-form Snip (ticket 07) will need a
; scratch layer instead. See docs/ink.md.
;
; Colour and width are constants: the reference's Pen and Highlighter are fixed
; presets in this replica (no Customize dialog), and both scale with the
; Editor's DPI.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC ink_init
PUBLIC ink_reset
PUBLIC ink_start
PUBLIC ink_extend
PUBLIC ink_end
PUBLIC ink_preview
PUBLIC ink_erase_begin
PUBLIC ink_erase
PUBLIC ink_erase_end
PUBLIC ink_undo

; Forward declarations so INVOKE reaches callees defined later in the file.
ink_wbits    PROTO STDCALL :DWORD                       ; DWORD ink_wbits(DWORD) - int to float bits
ink_make_pen PROTO STDCALL :DWORD                       ; GpPen *ink_make_pen(Stroke *s)
ink_make_pen_w PROTO STDCALL :DWORD, :DWORD             ; GpPen *ink_make_pen_w(Stroke *s, DWORD w) - explicit width
ink_draw_pts PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD  ; void ink_draw_pts(gfx, pen, GpPoint*, n)
ink_draw_one PROTO STDCALL :DWORD                       ; void ink_draw_one(Stroke *s)
ink_alpha    PROTO STDCALL                              ; void ink_alpha(void) - force Working alpha 255
ink_replay   PROTO STDCALL                              ; void ink_replay(void)
ink_push_op  PROTO STDCALL :DWORD, :DWORD               ; DWORD ink_push_op(kind, idx)

; ---------------------------------------------------------------------------
; The fixed presets. 96-DPI values; scaled by MulDiv at use.
; ---------------------------------------------------------------------------
INK_PEN_COLOR    EQU 0FF005AC8h        ; ARGB: opaque blue, RGB(0,90,200)
INK_HILITE_COLOR EQU 066FFF200h        ; ARGB: yellow RGB(255,242,0) at alpha 0x66
INK_PEN_W        EQU 3
INK_HILITE_W     EQU 16
INK_ERASE_R      EQU 8                 ; eraser hit radius, in pixels
INK_STEP         EQU 2                 ; accept a point after this much movement

; Capacity. The point arena is shared and append-only: strokes and points are
; never recycled, so a long session eventually stops accepting ink. That is the
; same fixed-buffer bargain the free-form Trace makes (ticket 07).
INK_MAX_STROKES  EQU 256
INK_STROKE_MAX   EQU 4096              ; points per stroke
INK_POINT_CAP    EQU 65536             ; points across all strokes
INK_MAX_OPS      EQU 10                ; Undo depth

; Operation kinds. An op that removes a stroke - whether Undo of its creation
; or an Eraser pass - marks the stroke with the op's id; Undo of an Eraser
; restores every stroke carrying that id.
OP_STROKE        EQU 1
OP_ERASE         EQU 2

Stroke STRUCT
    tool    DWORD ?                    ; INK_PEN or INK_HILITE
    color   DWORD ?                    ; GDI+ ARGB
    w       DWORD ?                    ; pen width in pixels, already DPI-scaled
    first   DWORD ?                    ; index of the first point in ink_pts
    n       DWORD ?                    ; point count
    state   DWORD ?                    ; 0 == live, else the op id that removed it
Stroke ENDS                            ; sizeof == 24

Op STRUCT
    kind    DWORD ?                    ; OP_STROKE or OP_ERASE
    idx     DWORD ?                    ; the stroke, for OP_STROKE
    id      DWORD ?                    ; unique, monotonic; the removal tag
Op ENDS                                ; sizeof == 12

.data?
ink_ready   DWORD ?                    ; GDI+ started?
ink_token   DWORD ?                    ; GdiplusStartup token
ink_step    DWORD ?                    ; accepted-movement threshold, this stroke
ink_cur     DWORD ?                    ; stroke in progress, or -1
ink_count   DWORD ?                    ; strokes created (index into ink_strokes)
ink_arena   DWORD ?                    ; next free point slot
ink_top     DWORD ?                    ; operations on the Undo stack
ink_nextid  DWORD ?                    ; next operation id
ink_erasing DWORD ?                    ; an Eraser drag is live
ink_eraseop DWORD ?                    ; the op id it tags removals with, or 0
ink_strokes Stroke INK_MAX_STROKES DUP(<>)
ink_pts     POINT  INK_POINT_CAP DUP(<>)
ink_ops     Op     INK_MAX_OPS DUP(<>)
ink_tmp     POINT  INK_STROKE_MAX DUP(<>)   ; a stroke's points, offset for preview

.code

; ---------------------------------------------------------------------------
; ink_init() -> BOOL in eax. Start GDI+. A failure is not fatal: the annotation
; buttons simply do nothing, exactly as Copy/Save do when WIC is missing.
; ---------------------------------------------------------------------------
ink_init PROC
    LOCAL gsi:GdiplusStartupInput

    mov  ink_ready, 0
    mov  gsi.GdiplusVersion, 1
    mov  gsi.DebugEventCallback, 0
    mov  gsi.SuppressBackgroundThread, 0
    mov  gsi.SuppressExternalCodecs, 0

    INVOKE GdiplusStartup, OFFSET ink_token, ADDR gsi, 0
    test eax, eax
    jnz  ii_no
    mov  ink_ready, 1
    mov  eax, 1
    ret
ii_no:
    xor  eax, eax
    ret
ink_init ENDP

; ---------------------------------------------------------------------------
; ink_reset() - drop the log. A new Snip starts with no annotations.
; ---------------------------------------------------------------------------
ink_reset PROC
    mov  ink_arena, 0
    mov  ink_count, 0
    mov  ink_top, 0
    mov  ink_nextid, 1
    mov  ink_cur, -1
    mov  ink_erasing, 0
    mov  ink_eraseop, 0
    ret
ink_reset ENDP

; ---------------------------------------------------------------------------
; ink_start(tool, x, y, dpi) -> BOOL in eax. Begin a stroke at the pointer.
; Fails if GDI+ is down or the log is full, in which case the Editor simply does
; not start a drag.
; ---------------------------------------------------------------------------
ink_start PROC USES ebx esi edi tool:DWORD, x:SDWORD, y:SDWORD, dpi:DWORD
    LOCAL s:DWORD

    cmp  ink_ready, 0
    je   is_no
    mov  eax, ink_count
    cmp  eax, INK_MAX_STROKES
    jge  is_no
    mov  eax, ink_arena
    cmp  eax, INK_POINT_CAP
    jge  is_no

    ; s = &ink_strokes[ink_count]
    mov  eax, ink_count
    imul eax, eax, SIZEOF Stroke
    lea  edi, ink_strokes
    add  edi, eax
    mov  s, edi

    mov  eax, tool
    mov  [edi].Stroke.tool, eax
    cmp  eax, INK_HILITE
    jne  is_pen
    mov  [edi].Stroke.color, INK_HILITE_COLOR
    INVOKE MulDiv, INK_HILITE_W, dpi, 96
    jmp  is_w
is_pen:
    mov  [edi].Stroke.color, INK_PEN_COLOR
    INVOKE MulDiv, INK_PEN_W, dpi, 96
is_w:
    cmp  eax, 1
    jge  is_w2
    mov  eax, 1
is_w2:
    mov  [edi].Stroke.w, eax

    ; The first point.
    mov  eax, ink_arena
    mov  [edi].Stroke.first, eax
    mov  [edi].Stroke.n, 1
    mov  [edi].Stroke.state, 0
    shl  eax, 3                       ; * sizeof POINT
    add  eax, OFFSET ink_pts
    mov  ecx, x
    mov  [eax], ecx
    mov  ecx, y
    mov  [eax+4], ecx
    inc  ink_arena

    inc  ink_count
    mov  eax, ink_count
    dec  eax
    mov  ink_cur, eax

    INVOKE MulDiv, INK_STEP, dpi, 96
    cmp  eax, 1
    jge  is_step
    mov  eax, 1
is_step:
    mov  ink_step, eax

    mov  eax, 1
    ret
is_no:
    xor  eax, eax
    ret
ink_start ENDP

; ---------------------------------------------------------------------------
; ink_extend(x, y) - append the pointer to the in-progress stroke once it has
; moved far enough. The threshold is what stops a slow drag from hoarding a
; point per pixel.
; ---------------------------------------------------------------------------
ink_extend PROC USES ebx esi edi x:SDWORD, y:SDWORD
    LOCAL s:DWORD

    mov  eax, ink_cur
    cmp  eax, -1
    je   ie_done
    imul eax, eax, SIZEOF Stroke
    lea  edi, ink_strokes
    add  edi, eax
    mov  s, edi

    cmp  [edi].Stroke.n, INK_STROKE_MAX
    jge  ie_done
    mov  eax, ink_arena
    cmp  eax, INK_POINT_CAP
    jge  ie_done

    ; The last accepted point.
    mov  eax, [edi].Stroke.first
    add  eax, [edi].Stroke.n
    dec  eax
    shl  eax, 3
    add  eax, OFFSET ink_pts

    mov  ecx, x
    sub  ecx, [eax]
    mov  edx, y
    sub  edx, [eax+4]
    cmp  ecx, 0
    jge  ie_dx
    neg  ecx
ie_dx:
    cmp  edx, 0
    jge  ie_dy
    neg  edx
ie_dy:
    add  ecx, edx
    cmp  ecx, ink_step
    jl   ie_done

    ; Append it.
    mov  eax, ink_arena
    shl  eax, 3
    add  eax, OFFSET ink_pts
    mov  ecx, x
    mov  [eax], ecx
    mov  ecx, y
    mov  [eax+4], ecx
    inc  ink_arena
    mov  edi, s
    inc  [edi].Stroke.n

ie_done:
    ret
ink_extend ENDP

; ---------------------------------------------------------------------------
; ink_end() - commit the in-progress stroke: draw it once into Working, then
; push it on the Undo stack.
; ---------------------------------------------------------------------------
ink_end PROC USES ebx
    mov  eax, ink_cur
    cmp  eax, -1
    je   end_done
    imul eax, eax, SIZEOF Stroke
    lea  ebx, ink_strokes
    add  ebx, eax

    INVOKE ink_draw_one, ebx
    INVOKE ink_alpha

    mov  eax, ink_cur
    INVOKE ink_push_op, OP_STROKE, eax
    mov  ink_cur, -1
end_done:
    ret
ink_end ENDP

; ---------------------------------------------------------------------------
; ink_preview(hdc, ox, oy, vw, vh, sw, sh) - draw the in-progress stroke onto a
; paint DC, scaled into the Editor's view: (sw,sh) is the Snip's size, (vw,vh) the
; fitted image area, and (ox,oy) its client origin. No-op when no stroke is live,
; so the Editor can call it unconditionally after its image draw.
; ---------------------------------------------------------------------------
ink_preview PROC USES ebx esi edi hdc:DWORD, ox:SDWORD, oy:SDWORD, vw:DWORD, vh:DWORD, sw:DWORD, sh:DWORD
    LOCAL gfx:DWORD
    LOCAL pen:DWORD
    LOCAL cnt:DWORD
    LOCAL npts:DWORD

    mov  eax, ink_cur
    cmp  eax, -1
    je   pv_done
    imul eax, eax, SIZEOF Stroke
    lea  ebx, ink_strokes
    add  ebx, eax

    cmp  sw, 1
    jl   pv_done
    cmp  sh, 1
    jl   pv_done

    mov  gfx, 0
    INVOKE GdipCreateFromHDC, hdc, ADDR gfx
    cmp  gfx, 0
    je   pv_done
    INVOKE GdipSetSmoothingMode, gfx, SmoothingModeAntiAlias

    ; The pen width scales with the view too, so a fitted stroke is as thick live
    ; as it will be once committed (but never thinner than one pixel).
    INVOKE MulDiv, [ebx].Stroke.w, vw, sw
    cmp  eax, 1
    jge  pv_w
    mov  eax, 1
pv_w:
    INVOKE ink_make_pen_w, ebx, eax
    mov  pen, eax
    test eax, eax
    jz   pv_close

    ; Copy the points, scaled into the view and offset. The count lives in a
    ; local because MulDiv clobbers ecx.
    mov  ecx, [ebx].Stroke.n
    cmp  ecx, INK_STROKE_MAX
    jle  pv_n
    mov  ecx, INK_STROKE_MAX
pv_n:
    mov  npts, ecx
    mov  cnt, ecx
    mov  eax, [ebx].Stroke.first
    shl  eax, 3
    add  eax, OFFSET ink_pts
    mov  esi, eax
    lea  edi, ink_tmp
pv_copy:
    cmp  cnt, 0
    jle  pv_draw
    INVOKE MulDiv, [esi], vw, sw
    add  eax, ox
    mov  [edi], eax
    INVOKE MulDiv, [esi+4], vh, sh
    add  eax, oy
    mov  [edi+4], eax
    add  esi, 8
    add  edi, 8
    dec  cnt
    jmp  pv_copy
pv_draw:
    INVOKE ink_draw_pts, gfx, pen, OFFSET ink_tmp, npts
    INVOKE GdipDeletePen, pen

pv_close:
    INVOKE GdipDeleteGraphics, gfx
pv_done:
    ret
ink_preview ENDP

; ---------------------------------------------------------------------------
; ink_erase_begin() / ink_erase_end() - bracket one Eraser drag, so every stroke
; it removes shares a single Undo step.
; ---------------------------------------------------------------------------
ink_erase_begin PROC
    mov  ink_erasing, 1
    mov  ink_eraseop, 0
    ret
ink_erase_begin ENDP

ink_erase_end PROC
    mov  ink_erasing, 0
    mov  ink_eraseop, 0
    ret
ink_erase_end ENDP

; ---------------------------------------------------------------------------
; ink_erase(x, y, dpi) -> BOOL in eax. Remove every live stroke with a point
; within the eraser's radius of the pointer. Points are dense (one every few
; pixels), so a point-to-point test is enough - no segment maths.
; ---------------------------------------------------------------------------
ink_erase PROC USES ebx esi edi x:SDWORD, y:SDWORD, dpi:DWORD
    LOCAL r2:DWORD
    LOCAL hit:DWORD
    LOCAL px:DWORD
    LOCAL py:DWORD

    cmp  ink_erasing, 0
    je   er_no

    mov  hit, 0
    mov  eax, x
    mov  px, eax
    mov  eax, y
    mov  py, eax

    INVOKE MulDiv, INK_ERASE_R, dpi, 96
    cmp  eax, 1
    jge  er_r
    mov  eax, 1
er_r:
    imul eax, eax
    mov  r2, eax

    xor  ebx, ebx
er_loop:
    cmp  ebx, ink_count
    jge  er_after
    imul eax, ebx, SIZEOF Stroke
    lea  edx, ink_strokes
    add  edx, eax
    cmp  [edx].Stroke.state, 0
    jne  er_next

    mov  eax, [edx].Stroke.first
    shl  eax, 3
    add  eax, OFFSET ink_pts
    mov  ecx, [edx].Stroke.n
er_pt:
    test ecx, ecx
    jz   er_next
    mov  esi, [eax]
    sub  esi, px
    imul esi, esi
    mov  edi, [eax+4]
    sub  edi, py
    imul edi, edi
    add  esi, edi
    cmp  esi, r2
    jle  er_hit
    add  eax, 8
    dec  ecx
    jmp  er_pt
er_hit:
    ; The first removal opens the Eraser's Undo step; the rest join it.
    cmp  ink_eraseop, 0
    jne  er_haveop
    INVOKE ink_push_op, OP_ERASE, 0
    mov  ink_eraseop, eax
er_haveop:
    imul eax, ebx, SIZEOF Stroke
    lea  edx, ink_strokes
    add  edx, eax
    mov  eax, ink_eraseop
    mov  [edx].Stroke.state, eax
    mov  hit, 1
er_next:
    inc  ebx
    jmp  er_loop

er_after:
    cmp  hit, 0
    je   er_ret
    INVOKE ink_replay
er_ret:
    mov  eax, hit
    ret
er_no:
    xor  eax, eax
    ret
ink_erase ENDP

; ---------------------------------------------------------------------------
; ink_undo() -> BOOL in eax. Pop the last operation and replay. Undoing a
; stroke removes it; undoing an Eraser pass restores everything it removed.
; ---------------------------------------------------------------------------
ink_undo PROC USES ebx edi
    LOCAL op:DWORD

    cmp  ink_top, 0
    je   un_no
    dec  ink_top
    mov  eax, ink_top
    imul eax, eax, SIZEOF Op
    lea  edx, ink_ops
    add  edx, eax
    mov  op, edx

    mov  eax, [edx].Op.id
    cmp  [edx].Op.kind, OP_STROKE
    jne  un_erase

    ; Undo of a stroke creation: tag the stroke with its own op id.
    mov  ecx, [edx].Op.idx
    imul ecx, ecx, SIZEOF Stroke
    lea  edi, ink_strokes
    add  edi, ecx
    mov  [edi].Stroke.state, eax
    jmp  un_replay

un_erase:
    ; Undo of an Eraser pass: clear the tag it left.
    xor  ebx, ebx
un_loop:
    cmp  ebx, ink_count
    jge  un_replay
    imul ecx, ebx, SIZEOF Stroke
    lea  edi, ink_strokes
    add  edi, ecx
    cmp  [edi].Stroke.state, eax
    jne  un_next
    mov  [edi].Stroke.state, 0
un_next:
    inc  ebx
    jmp  un_loop

un_replay:
    INVOKE ink_replay
    mov  eax, 1
    ret
un_no:
    xor  eax, eax
    ret
ink_undo ENDP

; ---------------------------------------------------------------------------
; ink_replay() - rebuild Working: Pristine, then every live stroke, then the
; alpha repair. This is the single definition of "what the Snip looks like now".
; ---------------------------------------------------------------------------
ink_replay PROC USES ebx esi edi
    LOCAL gfx:DWORD
    LOCAL pen:DWORD
    LOCAL i:DWORD
    LOCAL s:DWORD

    INVOKE dib_snip
    mov  ebx, eax
    mov  eax, [ebx].Snip.hdc
    test eax, eax
    jz   rp_done
    mov  ecx, [ebx].Snip.w
    cmp  ecx, 1
    jl   rp_done
    mov  edx, [ebx].Snip.h
    cmp  edx, 1
    jl   rp_done

    ; Pristine -> Working.
    mov  edi, [ebx].Snip.bits
    mov  esi, [ebx].Snip.pbits
    test edi, edi
    jz   rp_done
    test esi, esi
    jz   rp_done
    imul ecx, edx
    rep  movsd

    mov  gfx, 0
    INVOKE GdipCreateFromHDC, [ebx].Snip.hdc, ADDR gfx
    cmp  gfx, 0
    je   rp_alpha
    INVOKE GdipSetSmoothingMode, gfx, SmoothingModeAntiAlias

    mov  i, 0
rp_loop:
    mov  eax, i
    cmp  eax, ink_count
    jge  rp_loop_done
    imul eax, eax, SIZEOF Stroke
    lea  edi, ink_strokes
    add  edi, eax
    mov  s, edi
    cmp  [edi].Stroke.state, 0
    jne  rp_next

    INVOKE ink_make_pen, edi
    mov  pen, eax
    test eax, eax
    jz   rp_next
    mov  edi, s
    mov  eax, [edi].Stroke.first
    shl  eax, 3
    add  eax, OFFSET ink_pts
    INVOKE ink_draw_pts, gfx, pen, eax, [edi].Stroke.n
    INVOKE GdipDeletePen, pen
rp_next:
    inc  i
    jmp  rp_loop
rp_loop_done:
    INVOKE GdipDeleteGraphics, gfx

rp_alpha:
    INVOKE ink_alpha
rp_done:
    ret
ink_replay ENDP

; ---------------------------------------------------------------------------
; ink_draw_one(Stroke *s) - draw one stroke straight into Working through its
; memory DC. Used by ink_end for a committed stroke.
; ---------------------------------------------------------------------------
ink_draw_one PROC USES ebx edi s:DWORD
    LOCAL gfx:DWORD
    LOCAL pen:DWORD

    INVOKE dib_snip
    mov  ebx, eax
    mov  eax, [ebx].Snip.hdc
    test eax, eax
    jz   do_done

    mov  gfx, 0
    INVOKE GdipCreateFromHDC, [ebx].Snip.hdc, ADDR gfx
    cmp  gfx, 0
    je   do_done
    INVOKE GdipSetSmoothingMode, gfx, SmoothingModeAntiAlias

    mov  edi, s
    INVOKE ink_make_pen, edi
    mov  pen, eax
    test eax, eax
    jz   do_close
    mov  eax, [edi].Stroke.first
    shl  eax, 3
    add  eax, OFFSET ink_pts
    INVOKE ink_draw_pts, gfx, pen, eax, [edi].Stroke.n
    INVOKE GdipDeletePen, pen
do_close:
    INVOKE GdipDeleteGraphics, gfx
do_done:
    ret
ink_draw_one ENDP

; ---------------------------------------------------------------------------
; ink_draw_pts(gfx, pen, GpPoint *pts, n) - one GdipDrawLinesI. A one-point
; stroke (a click) is doubled so the round cap paints a dot.
; ---------------------------------------------------------------------------
ink_draw_pts PROC USES ebx esi edi gfx:DWORD, pen:DWORD, pts:DWORD, n:DWORD
    LOCAL pp:DWORD

    mov  eax, pts
    mov  ecx, n
    cmp  ecx, 0
    jle  dp_done
    cmp  ecx, 1
    jne  dp_call

    lea  edi, ink_tmp
    mov  edx, [eax]                    ; p.x
    mov  [edi], edx
    mov  edx, [eax+4]                  ; p.y
    mov  [edi+4], edx
    mov  edx, [eax]                    ; p2.x
    mov  [edi+8], edx
    mov  edx, [eax+4]                  ; p2.y
    mov  [edi+12], edx
    mov  eax, edi
    mov  ecx, 2

dp_call:
    mov  pp, eax
    INVOKE GdipDrawLinesI, gfx, pen, pp, ecx
dp_done:
    ret
ink_draw_pts ENDP

; ---------------------------------------------------------------------------
; ink_make_pen(Stroke *s) -> GpPen * in eax, or 0. The stroke's own width; the
; committed rasterisation path uses this.
; ---------------------------------------------------------------------------
ink_make_pen PROC s:DWORD
    mov  eax, s
    mov  ecx, [eax].Stroke.w
    INVOKE ink_make_pen_w, eax, ecx
    ret
ink_make_pen ENDP

; ---------------------------------------------------------------------------
; ink_make_pen_w(Stroke *s, DWORD w) -> GpPen * in eax, or 0. As ink_make_pen,
; but with an explicit pixel width: the Editor's live preview scales the pen with
; its fit, while a committed stroke keeps the stroke's own width. GDI+ wants a
; REAL width, so the integer is converted to its float bits.
; ---------------------------------------------------------------------------
ink_make_pen_w PROC USES ebx s:DWORD, w:DWORD
    LOCAL pen:DWORD
    LOCAL wf:DWORD

    mov  ebx, s
    mov  pen, 0
    INVOKE ink_wbits, w
    mov  wf, eax
    INVOKE GdipCreatePen1, [ebx].Stroke.color, wf, UnitPixel, ADDR pen
    test eax, eax
    jnz  mpw_no
    cmp  pen, 0
    je   mpw_no
    INVOKE GdipSetPenStartCap, pen, LineCapRound
    INVOKE GdipSetPenEndCap, pen, LineCapRound
    INVOKE GdipSetPenLineJoin, pen, LineJoinRound
    mov  eax, pen
    ret
mpw_no:
    xor  eax, eax
    ret
ink_make_pen_w ENDP

; ---------------------------------------------------------------------------
; ink_alpha() - repair Working's alpha after GDI+ drawing, from Pristine. GDI+
; leaves the alpha of a DIB surface unusable, so a committed stroke would
; otherwise wreck it. Pristine carries the Snip's true alpha: 255 everywhere for
; a rectangular Snip, the free-form coverage mask for a free-form one (ticket
; 07). Restoring from Pristine keeps both cases correct; forcing 255 would erase
; a free-form cut.
; ---------------------------------------------------------------------------
ink_alpha PROC USES ebx esi edi
    INVOKE dib_snip
    mov  ebx, eax
    mov  edi, [ebx].Snip.bits
    mov  esi, [ebx].Snip.pbits
    test edi, edi
    jz   aa_done
    test esi, esi
    jz   aa_done
    mov  ecx, [ebx].Snip.w
    cmp  ecx, 1
    jl   aa_done
    mov  eax, [ebx].Snip.h
    cmp  eax, 1
    jl   aa_done
    imul ecx, eax
aa_loop:
    mov  eax, [esi]
    and  eax, 0FF000000h
    and  dword ptr [edi], 000FFFFFFh
    or   [edi], eax
    add  esi, 4
    add  edi, 4
    dec  ecx
    jnz  aa_loop
aa_done:
    ret
ink_alpha ENDP

; ---------------------------------------------------------------------------
; ink_push_op(kind, idx) -> DWORD id in eax. Append an operation; when the stack
; is full the oldest falls off, so Undo depth is bounded and stops at the
; pristine Snip once nothing is left. Ids stay unique either way.
; ---------------------------------------------------------------------------
ink_push_op PROC USES ebx esi edi kind:DWORD, idx:DWORD
    LOCAL id:DWORD

    mov  eax, ink_nextid
    mov  id, eax
    inc  ink_nextid

    cmp  ink_top, INK_MAX_OPS
    jl   po_room
    ; Slide the window: drop ops[0].
    mov  esi, OFFSET ink_ops + (SIZEOF Op)
    mov  edi, OFFSET ink_ops
    mov  ecx, (INK_MAX_OPS - 1) * (SIZEOF Op) / 4
    rep  movsd
    dec  ink_top
po_room:
    mov  eax, ink_top
    imul eax, eax, SIZEOF Op
    lea  edi, ink_ops
    add  edi, eax
    mov  eax, kind
    mov  [edi].Op.kind, eax
    mov  eax, idx
    mov  [edi].Op.idx, eax
    mov  eax, id
    mov  [edi].Op.id, eax
    inc  ink_top
    mov  eax, id
    ret
ink_push_op ENDP

; ---------------------------------------------------------------------------
; ink_wbits(DWORD) -> the 32 bits of (float)arg in eax. GDI+ takes REAL widths;
; this is the one place an integer becomes one.
; ---------------------------------------------------------------------------
ink_wbits PROC w:DWORD
    fild dword ptr w
    sub  esp, 4
    fstp dword ptr [esp]
    pop  eax
    ret
ink_wbits ENDP

END
