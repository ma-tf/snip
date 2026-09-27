; mask.asm
; Free-form Trace geometry: the pure half of a free-form cut.
;
; In free-form mode the user traces a path on the Overlay. This module owns that
; Trace as geometry and nothing else: the sampling acceptance test, the
; Ramer-Douglas-Peucker simplification, the inclusive bounding box, and the
; degenerate test. It never touches Win32, GDI+, or the Snip's pixels, so the
; tricky maths reads on its own. The impure GDI+ coverage fill lives in dib.asm,
; which is the one module that owns Snip pixels.
;
; The Trace is one fixed buffer of 8192 points in .data? (.bss): no allocation,
; no file bytes. The buffer is the raw accepted path while the user drags; on
; release mask_simplify compacts it in place down to the simplified path. The
; bbox is taken from the raw points, so it always contains the simplified one
; and no vertex can be clipped.
;
; A point is accepted only once the pointer has moved a DPI-scaled threshold
; from the last accepted one, so a slow hand does not store hundreds of
; near-collinear points. When the buffer fills, the Trace simply stops accepting
; points rather than dropping or overwriting any.
;
; See docs/freeform.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc

PUBLIC mask_reset
PUBLIC mask_add
PUBLIC mask_bbox
PUBLIC mask_simplify
PUBLIC mask_translate
PUBLIC mask_count
PUBLIC mask_points
PUBLIC mask_degenerate

; Forward declarations so INVOKE reaches callees defined later in the file.
mask_push PROTO STDCALL :DWORD, :DWORD      ; void mask_push(i, j)
mask_scan PROTO STDCALL :DWORD, :DWORD      ; BOOL mask_scan(i, j) - find the far point

; ---------------------------------------------------------------------------
; Constants. The sample threshold is ~3px at 96 DPI, scaled, with a floor of 1
; so a scaled 0 can never make every move acceptable. RDP epsilon is 1px; it is
; compared squared, which is why the distance test below never takes a sqrt.
; ---------------------------------------------------------------------------
MASK_MAX_PTS   EQU 8192          ; the fixed Trace buffer
MASK_RDP_EPS   EQU 1             ; Ramer-Douglas-Peucker epsilon, in pixels
MASK_STACK_MAX EQU 2048          ; RDP stack entries (index pairs); overflow coarsens, never corrupts

; ---------------------------------------------------------------------------
; Statics. A Trace is a singleton, like a Selection. Zero-initialised: .data?
; (.bss), so the 64KB point buffer costs no file bytes. m_* are the RDP scan's
; scratch, written by mask_scan and read by mask_simplify.
; ---------------------------------------------------------------------------
.data?
mask_raw    DWORD MASK_MAX_PTS*2 DUP(?)   ; x,y pairs: Pt layout, == GpPoint
mask_keep   BYTE  MASK_MAX_PTS  DUP(?)    ; RDP "kept" flags
mask_stk    DWORD MASK_STACK_MAX*2 DUP(?) ; RDP work stack, (i,j) pairs
mask_sp     DWORD ?
mask_n      DWORD ?             ; raw accepted point count
mask_sn     DWORD ?             ; simplified point count
mask_minx   SDWORD ?
mask_miny   SDWORD ?
mask_maxx   SDWORD ?
mask_maxy   SDWORD ?
mask_lx     SDWORD ?            ; the last accepted point, for the threshold test
mask_ly     SDWORD ?
mask_thr2   DWORD ?             ; sample threshold, squared
m_bestk     SDWORD ?
m_bestlo    DWORD ?
m_besthi    DWORD ?

.code

; ---------------------------------------------------------------------------
; mask_reset(DWORD dpi) - start a new Trace: clear the points and set the
; sample threshold for the Overlay's effective DPI. dpi 0 falls back to 96.
; ---------------------------------------------------------------------------
mask_reset PROC USES ecx edx dpi:DWORD
    mov  mask_n, 0
    mov  mask_sn, 0
    mov  mask_lx, 0
    mov  mask_ly, 0
    mov  mask_minx, 0
    mov  mask_miny, 0
    mov  mask_maxx, 0
    mov  mask_maxy, 0

    mov  eax, dpi
    test eax, eax
    jnz  mr_dpi
    mov  eax, 96
mr_dpi:
    imul eax, 3
    xor  edx, edx
    mov  ecx, 96
    div  ecx
    test eax, eax
    jnz  mr_thr
    mov  eax, 1
mr_thr:
    imul eax, eax
    mov  mask_thr2, eax
    ret
mask_reset ENDP

; ---------------------------------------------------------------------------
; mask_add(SDWORD x, SDWORD y) -> BOOL in eax. Accept the point if it is at
; least the sample threshold from the last accepted one; the very first point
; is always accepted, and the bbox is seeded from it. Returns 0 on rejection or
; when the buffer is full.
; ---------------------------------------------------------------------------
mask_add PROC USES ebx esi edi xs:SDWORD, ys:SDWORD
    mov  esi, xs
    mov  edi, ys

    mov  eax, mask_n
    cmp  eax, MASK_MAX_PTS
    jge  ma_no

    test eax, eax
    jz   ma_store

    ; squared distance from the last accepted point vs the squared threshold
    mov  ecx, esi
    sub  ecx, mask_lx
    mov  edx, edi
    sub  edx, mask_ly
    imul ecx, ecx
    imul edx, edx
    add  ecx, edx
    cmp  ecx, mask_thr2
    jl   ma_no

ma_store:
    mov  ecx, eax
    shl  ecx, 3
    lea  ebx, mask_raw
    mov  [ebx+ecx], esi
    mov  [ebx+ecx+4], edi
    mov  mask_lx, esi
    mov  mask_ly, edi

    test eax, eax
    jnz  ma_bbox
    ; first point seeds the inclusive bbox
    mov  mask_minx, esi
    mov  mask_maxx, esi
    mov  mask_miny, edi
    mov  mask_maxy, edi
    jmp  ma_inc

ma_bbox:
    cmp  esi, mask_minx
    jge  ma_b1
    mov  mask_minx, esi
ma_b1:
    cmp  esi, mask_maxx
    jle  ma_b2
    mov  mask_maxx, esi
ma_b2:
    cmp  edi, mask_miny
    jge  ma_b3
    mov  mask_miny, edi
ma_b3:
    cmp  edi, mask_maxy
    jle  ma_inc
    mov  mask_maxy, edi

ma_inc:
    inc  mask_n
    mov  eax, 1
    ret

ma_no:
    xor  eax, eax
    ret
mask_add ENDP

; ---------------------------------------------------------------------------
; mask_bbox(Rect *out) - write the inclusive bbox of every accepted point. The
; bbox is tracked during the drag, from the raw points, so it is available for
; the live readout and is a superset of the simplified path.
; ---------------------------------------------------------------------------
mask_bbox PROC USES edx prc:DWORD
    mov  edx, prc
    mov  eax, mask_minx
    mov  [edx].Rect.left, eax
    mov  eax, mask_miny
    mov  [edx].Rect.top, eax
    mov  eax, mask_maxx
    mov  [edx].Rect.right, eax
    mov  eax, mask_maxy
    mov  [edx].Rect.bottom, eax
    ret
mask_bbox ENDP

; ---------------------------------------------------------------------------
; mask_simplify() - Ramer-Douglas-Peucker at eps = 1, over the accepted points,
; compacted in place. A Trace with fewer than 3 points is already its own
; simplification. Iterative with an explicit stack: a hand trace can be deep,
; and recursion is not worth the risk. Stack overflow drops a sub-range, which
; coarsens the path through its endpoints but never corrupts it.
; ---------------------------------------------------------------------------
mask_simplify PROC USES ebx esi edi
    LOCAL i:DWORD
    LOCAL j:DWORD
    LOCAL k:DWORD

    mov  eax, mask_n
    cmp  eax, 3
    jge  ms_go
    mov  mask_sn, eax
    ret

ms_go:
    ; keep[] = 0, then the two endpoints are always kept
    lea  edi, mask_keep
    mov  ecx, mask_n
    xor  eax, eax
    rep  stosb
    mov  byte ptr mask_keep[0], 1
    mov  eax, mask_n
    dec  eax
    mov  byte ptr mask_keep[eax], 1

    mov  mask_sp, 0
    mov  eax, mask_n
    dec  eax
    INVOKE mask_push, 0, eax

ms_loop:
    cmp  mask_sp, 0
    jle  ms_compact
    dec  mask_sp
    mov  eax, mask_sp
    add  eax, eax
    lea  ebx, mask_stk
    mov  ecx, [ebx+eax*4]
    mov  i, ecx
    mov  ecx, [ebx+eax*4+4]
    mov  j, ecx

    ; nothing between i and j to test
    mov  eax, i
    inc  eax
    cmp  j, eax
    jle  ms_loop

    INVOKE mask_scan, i, j
    test eax, eax
    jz   ms_loop

    mov  eax, m_bestk
    mov  k, eax
    mov  byte ptr mask_keep[eax], 1
    INVOKE mask_push, i, k
    INVOKE mask_push, k, j
    jmp  ms_loop

ms_compact:
    ; Move every kept point to the front of mask_raw. The write index never
    ; overtakes the read index, so this is safe in place.
    xor  esi, esi
    xor  ecx, ecx
mcomp_loop:
    cmp  esi, mask_n
    jge  mcomp_done
    cmp  byte ptr mask_keep[esi], 0
    je   mcomp_skip
    mov  eax, esi
    shl  eax, 3
    mov  edx, ecx
    shl  edx, 3
    lea  ebx, mask_raw
    mov  edi, [ebx+eax]
    mov  [ebx+edx], edi
    mov  edi, [ebx+eax+4]
    mov  [ebx+edx+4], edi
    inc  ecx
mcomp_skip:
    inc  esi
    jmp  mcomp_loop
mcomp_done:
    mov  mask_sn, ecx
    ret
mask_simplify ENDP

; ---------------------------------------------------------------------------
; mask_scan(i, j) -> BOOL in eax. Find the accepted point between raw[i] and
; raw[j] farthest from the i..j line, leaving the index in m_bestk and the
; squared distance in m_besthi:m_bestlo. Returns 1 when that distance exceeds
; eps (1px), meaning the range must be split there. The cross product is 64-bit
; because the endpoints can span the whole virtual screen.
; ---------------------------------------------------------------------------
mask_scan PROC USES ebx esi edi xi:DWORD, xj:DWORD
    LOCAL ax0:DWORD
    LOCAL ay0:DWORD
    LOCAL bx0:DWORD
    LOCAL by0:DWORD
    LOCAL ddx:DWORD
    LOCAL ddy:DWORD
    LOCAL seg2:DWORD
    LOCAL k:DWORD

    ; a = raw[i]
    mov  eax, xi
    shl  eax, 3
    lea  ebx, mask_raw
    add  ebx, eax
    mov  ecx, [ebx]
    mov  ax0, ecx
    mov  ecx, [ebx+4]
    mov  ay0, ecx

    ; b = raw[j]
    mov  eax, xj
    shl  eax, 3
    lea  ebx, mask_raw
    add  ebx, eax
    mov  ecx, [ebx]
    mov  bx0, ecx
    mov  ecx, [ebx+4]
    mov  by0, ecx

    mov  eax, bx0
    sub  eax, ax0
    mov  ddx, eax
    mov  eax, by0
    sub  eax, ay0
    mov  ddy, eax

    mov  eax, ddx
    imul eax, ddx
    mov  ecx, ddy
    imul ecx, ddy
    add  eax, ecx
    mov  seg2, eax

    mov  m_bestk, -1
    mov  m_bestlo, 0
    mov  m_besthi, 0

    mov  eax, xi
    inc  eax
    mov  k, eax

msc_loop:
    mov  eax, k
    cmp  eax, xj
    jge  msc_done

    ; p = raw[k]
    shl  eax, 3
    lea  ebx, mask_raw
    add  ebx, eax

    ; u = p.x - a.x ; v = p.y - a.y
    mov  ecx, [ebx]
    sub  ecx, ax0
    mov  eax, ecx
    mov  ecx, ddy
    imul ecx                      ; edx:eax = u * dy
    mov  esi, eax
    mov  edi, edx
    mov  ecx, [ebx+4]
    sub  ecx, ay0
    mov  eax, ecx
    mov  ecx, ddx
    imul ecx                      ; edx:eax = v * dx
    sub  esi, eax
    sbb  edi, edx                 ; edi:esi = cross = u*dy - v*dx

    ; |cross|
    test edi, edi
    jns  msc_abs
    not  esi
    not  edi
    add  esi, 1
    adc  edi, 0
msc_abs:
    test edi, edi
    jz   msc_sq
    ; magnitude above 2^32: treat as the kept point so the range splits here
    mov  m_besthi, 7FFFFFFFh
    mov  m_bestlo, 0FFFFFFFFh
    mov  eax, k
    mov  m_bestk, eax
    jmp  msc_next

msc_sq:
    mov  eax, esi
    mul  esi                      ; edx:eax = cross^2
    cmp  edx, m_besthi
    jb   msc_next
    ja   msc_better
    cmp  eax, m_bestlo
    jbe  msc_next
msc_better:
    mov  m_besthi, edx
    mov  m_bestlo, eax
    mov  ecx, k
    mov  m_bestk, ecx

msc_next:
    inc  k
    jmp  msc_loop

msc_done:
    mov  eax, m_bestk
    cmp  eax, -1
    je   msc_no
    mov  eax, m_besthi
    test eax, eax
    jnz  msc_yes
    mov  eax, m_bestlo
    cmp  eax, seg2
    ja   msc_yes
msc_no:
    xor  eax, eax
    ret
msc_yes:
    mov  eax, 1
    ret
mask_scan ENDP

; ---------------------------------------------------------------------------
; mask_push(i, j) - push one index range for mask_simplify. A full stack drops
; the range; the path is then simplified through its endpoints instead of its
; interior, which is coarser but still a valid subset.
; ---------------------------------------------------------------------------
mask_push PROC USES ebx i:DWORD, j:DWORD
    mov  eax, mask_sp
    cmp  eax, MASK_STACK_MAX
    jge  mp_done
    add  eax, eax
    lea  ebx, mask_stk
    mov  ecx, i
    mov  [ebx+eax*4], ecx
    mov  ecx, j
    mov  [ebx+eax*4+4], ecx
    inc  mask_sp
mp_done:
    ret
mask_push ENDP

; ---------------------------------------------------------------------------
; mask_translate(SDWORD dx, SDWORD dy) - move the simplified points and the bbox
; from the Overlay's virtual-relative space to screen pixels. Called once, at
; the session->Snip boundary, so dib.asm and the Editor work in screen pixels.
; ---------------------------------------------------------------------------
mask_translate PROC USES ebx ecx edx tx:SDWORD, ty:SDWORD
    mov  ecx, mask_sn
    test ecx, ecx
    jz   mt_bbox
    lea  ebx, mask_raw
mt_loop:
    mov  eax, [ebx]
    add  eax, tx
    mov  [ebx], eax
    mov  eax, [ebx+4]
    add  eax, ty
    mov  [ebx+4], eax
    add  ebx, 8
    dec  ecx
    jnz  mt_loop
mt_bbox:
    mov  eax, tx
    add  mask_minx, eax
    add  mask_maxx, eax
    mov  eax, ty
    add  mask_miny, eax
    add  mask_maxy, eax
    ret
mask_translate ENDP

; ---------------------------------------------------------------------------
; mask_count() -> DWORD in eax. The path's point count: the simplified count
; once mask_simplify has run, otherwise the raw accepted count. The preview uses
; it during the drag, before simplification; the crop uses it after.
; ---------------------------------------------------------------------------
mask_count PROC
    mov  eax, mask_sn
    test eax, eax
    jnz  mc_done
    mov  eax, mask_n
mc_done:
    ret
mask_count ENDP

; ---------------------------------------------------------------------------
; mask_points() -> Pt * in eax. The simplified points. Pt is x,y as SDWORDs,
; the same layout as GDI+'s GpPoint, so the array can be handed straight to the
; path builder.
; ---------------------------------------------------------------------------
mask_points PROC
    mov  eax, OFFSET mask_raw
    ret
mask_points ENDP

; ---------------------------------------------------------------------------
; mask_degenerate() -> BOOL in eax. A Trace that is fewer than 3 simplified
; points, or under 2x2 pixels (an inclusive span below 2 on either axis), must
; not become a Snip. The caller leaves the Overlay up instead.
; ---------------------------------------------------------------------------
mask_degenerate PROC
    mov  eax, mask_sn
    cmp  eax, 3
    jl   md_yes
    mov  eax, mask_maxx
    sub  eax, mask_minx
    inc  eax
    cmp  eax, 2
    jl   md_yes
    mov  eax, mask_maxy
    sub  eax, mask_miny
    inc  eax
    cmp  eax, 2
    jl   md_yes
    xor  eax, eax
    ret
md_yes:
    mov  eax, 1
    ret
mask_degenerate ENDP

END
