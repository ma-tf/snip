; geometry.asm
; Pure Selection maths: Rect normalisation and measurement.
;
; This module is deliberately Win32-free - snip.inc only, never win32.inc - so
; the tricky part (normalising a drag that runs right-to-left or bottom-to-top)
; reads on its own, with no API in the way. Nothing here allocates, calls out,
; or touches the screen; every function is a leaf that returns in eax.
;
; See docs/select.md for how the Selection is built and measured.

.386
.model flat, stdcall
option casemap:none

include snip.inc

PUBLIC geo_normalise
PUBLIC geo_width
PUBLIC geo_height

.code

; ---------------------------------------------------------------------------
; geo_normalise(Rect *r, Pt *a, Pt *b) - write the inclusive bounding rectangle
; of the two points into *r, with left<=right and top<=bottom.
;
; A drag runs in any direction, so either endpoint may be the smaller. The
; rectangle is the raw bounding box of the two points: the width is
; right-left, the height is bottom-top. Ticket 03 crops with a one-pixel
; inclusive box, so a Selection covering exactly px (5,5) has left==right==5
; and right-left==0; the +1 belongs to the crop, not to the Rect. Keeping the
; two apart is why this module is separate from dib.asm.
; ---------------------------------------------------------------------------
geo_normalise PROC USES ebx esi r:DWORD, a:DWORD, b:DWORD
    mov  ebx, r
    mov  esi, a

    ; left = min(a.x, b.x), right = max(a.x, b.x)
    mov  eax, [esi].Pt.x
    mov  ecx, b
    mov  edx, [ecx].Pt.x
    cmp  eax, edx
    jle  gn_x_ordered
    xchg eax, edx
gn_x_ordered:
    mov  [ebx].Rect.left, eax
    mov  [ebx].Rect.right, edx

    ; top = min(a.y, b.y), bottom = max(a.y, b.y)
    mov  eax, [esi].Pt.y
    mov  ecx, b
    mov  edx, [ecx].Pt.y
    cmp  eax, edx
    jle  gn_y_ordered
    xchg eax, edx
gn_y_ordered:
    mov  [ebx].Rect.top, eax
    mov  [ebx].Rect.bottom, edx

    ret
geo_normalise ENDP

; ---------------------------------------------------------------------------
; geo_width(Rect *r) -> SDWORD in eax. right - left.
; ---------------------------------------------------------------------------
geo_width PROC r:DWORD
    mov  eax, r
    mov  ecx, [eax].Rect.right
    sub  ecx, [eax].Rect.left
    mov  eax, ecx
    ret
geo_width ENDP

; ---------------------------------------------------------------------------
; geo_height(Rect *r) -> SDWORD in eax. bottom - top.
; ---------------------------------------------------------------------------
geo_height PROC r:DWORD
    mov  eax, r
    mov  ecx, [eax].Rect.bottom
    sub  ecx, [eax].Rect.top
    mov  eax, ecx
    ret
geo_height ENDP

END
