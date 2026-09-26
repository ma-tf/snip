; dib.asm
; The Snip: the captured region owned as one cropped 32bpp straight-BGRA DIB,
; with a Pristine twin.
;
; A Snip is made in one shot: allocate Working and Pristine, blit the Selection
; straight from the screen into Working (capture.asm), force alpha to 255, and
; copy Working into Pristine. No full-screen buffer is ever held, and no Snip
; aliases another surface - it owns its pixels outright (ADR-0001).
;
; Alpha is synthesised because the screen DC supplies none: GDI blits colour,
; leaves the alpha byte as the destination had it. Straight BGRA with a real
; alpha channel is what WIC accepts unchanged (ticket 05) and what free-form
; cuts and the Eraser will use (tickets 06/07).
;
; dib_crop is atomic. It builds the new Snip in a local and only frees the old
; one once the new one exists, so a failed capture leaves the Editor showing the
; previous Snip instead of a wrecked one (ticket 11).
;
; See docs/capture.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC dib_crop
PUBLIC dib_snip

; Forward declarations so INVOKE reaches callees defined later in the file.
dib_alloc PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD  ; BOOL dib_alloc(Snip *sn, DWORD w, DWORD h, Rect *sel)
snip_free PROTO STDCALL :DWORD                          ; void snip_free(Snip *sn)

; ---------------------------------------------------------------------------
; Statics. One live Snip at a time, so the instance lives here; editor.asm reads
; it through dib_snip. scr_bmi is the shared pixel-format header both DIBs are
; created from. Zero-initialised, so .data? (.bss): no file bytes.
; ---------------------------------------------------------------------------
.data?
cur_snip Snip <>
scr_bmi  BITMAPINFOHEADER <>

.code

; ---------------------------------------------------------------------------
; dib_crop(Rect *sel) -> BOOL in eax. Make a Snip from the Selection, replacing
; any previous one. Atomic: the old Snip survives a failure.
; ---------------------------------------------------------------------------
dib_crop PROC USES ebx esi edi sel:DWORD
    LOCAL tmp:Snip
    LOCAL w:DWORD
    LOCAL h:DWORD

    mov  ebx, sel

    ; The Selection's inclusive span: a box from (5,5) to (5,5) is one pixel,
    ; right-left == 0, so the width is geo_width + 1.
    INVOKE geo_width, ebx
    inc  eax
    mov  w, eax
    INVOKE geo_height, ebx
    inc  eax
    mov  h, eax

    cmp  w, 1
    jl   dc_fail
    cmp  h, 1
    jl   dc_fail

    INVOKE dib_alloc, ADDR tmp, w, h, sel
    test eax, eax
    jz   dc_fail

    ; Commit: drop the old Snip, then move the new one in. Nothing can be
    ; holding the old pointers across this call - the Editor paints on demand.
    INVOKE snip_free, OFFSET cur_snip
    lea  esi, tmp
    mov  edi, OFFSET cur_snip
    mov  ecx, (SIZEOF Snip) / 4
    rep  movsd

    mov  eax, 1
    ret

dc_fail:
    xor  eax, eax
    ret
dib_crop ENDP

; ---------------------------------------------------------------------------
; dib_snip() -> Snip * in eax. The live Snip; its fields are zero when there is
; none, which the Editor treats as "nothing to paint".
; ---------------------------------------------------------------------------
dib_snip PROC
    mov  eax, OFFSET cur_snip
    ret
dib_snip ENDP

; ---------------------------------------------------------------------------
; dib_alloc(Snip *sn, DWORD w, DWORD h, Rect *sel) -> BOOL in eax. Fill *sn with
; a fresh Snip of w x h pixels captured from the Selection, or zero it and
; return 0. Anything half-built is freed on the way out.
; ---------------------------------------------------------------------------
dib_alloc PROC USES ebx esi edi sn:DWORD, w:DWORD, h:DWORD, sel:DWORD
    LOCAL hdcScr:DWORD
    LOCAL bitsW:DWORD
    LOCAL bitsP:DWORD

    mov  hdcScr, 0
    mov  bitsW, 0
    mov  bitsP, 0

    ; Start from zero, so a partial failure frees cleanly and fields the caller
    ; might read (hdc, width) are never stale.
    mov  edi, sn
    xor  eax, eax
    mov  ecx, (SIZEOF Snip) / 4
    rep  stosd

    ; One header serves both DIBs: same size, same format. Top-down (negative
    ; height) so row 0 is the top row, matching the screen.
    mov  scr_bmi.biSize, SIZEOF BITMAPINFOHEADER
    mov  eax, w
    mov  scr_bmi.biWidth, eax
    mov  eax, h
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

    INVOKE GetDC, 0
    mov  hdcScr, eax
    test eax, eax
    jz   da_fail

    ; --- Working: the DIB, plus a memory DC holding it ----------------------
    mov  ebx, sn
    INVOKE CreateCompatibleDC, hdcScr
    mov  [ebx].Snip.hdc, eax
    test eax, eax
    jz   da_fail

    INVOKE CreateDIBSection, hdcScr, OFFSET scr_bmi, DIB_RGB_COLORS, ADDR bitsW, 0, 0
    mov  [ebx].Snip.hdib, eax
    test eax, eax
    jz   da_fail
    mov  ecx, bitsW
    mov  [ebx].Snip.bits, ecx

    INVOKE SelectObject, [ebx].Snip.hdc, [ebx].Snip.hdib
    mov  [ebx].Snip.oldbm, eax

    ; --- Pristine: the same pixels, never drawn on --------------------------
    INVOKE CreateDIBSection, hdcScr, OFFSET scr_bmi, DIB_RGB_COLORS, ADDR bitsP, 0, 0
    mov  [ebx].Snip.pristine, eax
    test eax, eax
    jz   da_fail
    mov  ecx, bitsP
    mov  [ebx].Snip.pbits, ecx

    ; --- fill Working from the screen ---------------------------------------
    INVOKE capture_region, sel, [ebx].Snip.hdc, w, h
    test eax, eax
    jz   da_fail

    ; --- synthesise alpha, and mirror into Pristine -------------------------
    ; GDI left the alpha byte 0. Force 255 on Working and copy the result into
    ; Pristine in the same pass, so the two start byte-identical.
    mov  esi, bitsW
    mov  edi, bitsP
    mov  ecx, w
    imul ecx, h
    jle  da_commit
    mov  edx, 0FF000000h
da_px:
    mov  eax, [esi]
    or   eax, edx
    mov  [esi], eax
    mov  [edi], eax
    add  esi, 4
    add  edi, 4
    dec  ecx
    jnz  da_px

da_commit:
    mov  ebx, sn
    mov  eax, w
    mov  [ebx].Snip.w, eax
    mov  eax, h
    mov  [ebx].Snip.h, eax
    mov  eax, sel
    mov  ecx, [eax].Rect.left
    mov  [ebx].Snip.x, ecx
    mov  ecx, [eax].Rect.top
    mov  [ebx].Snip.y, ecx

    INVOKE ReleaseDC, 0, hdcScr
    mov  eax, 1
    ret

da_fail:
    INVOKE snip_free, sn
    cmp  hdcScr, 0
    jz   da_fail_ret
    INVOKE ReleaseDC, 0, hdcScr
da_fail_ret:
    xor  eax, eax
    ret
dib_alloc ENDP

; ---------------------------------------------------------------------------
; snip_free(Snip *sn) - release a Snip's bitmaps and DC. Safe on a zero struct,
; which is what a partly-built dib_alloc leaves behind.
;
; Order matters: the Working bitmap must be deselected before it can be deleted,
; and the DC must go before or after the bitmap but never with one still in it.
; ---------------------------------------------------------------------------
snip_free PROC USES ebx esi sn:DWORD
    mov  ebx, sn
    test ebx, ebx
    jz   sf_done

    ; Working: deselect, delete the bitmap, delete the DC.
    mov  eax, [ebx].Snip.hdc
    test eax, eax
    jz   sf_pristine
    mov  ecx, [ebx].Snip.hdib
    test ecx, ecx
    jz   sf_del_dc
    mov  edx, [ebx].Snip.oldbm
    test edx, edx
    jz   sf_del_bmp
    INVOKE SelectObject, eax, edx
sf_del_bmp:
    INVOKE DeleteObject, [ebx].Snip.hdib
    mov  [ebx].Snip.hdib, 0
sf_del_dc:
    INVOKE DeleteDC, [ebx].Snip.hdc
    mov  [ebx].Snip.hdc, 0

sf_pristine:
    mov  eax, [ebx].Snip.pristine
    test eax, eax
    jz   sf_zero
    INVOKE DeleteObject, eax
    mov  [ebx].Snip.pristine, 0

sf_zero:
    mov  [ebx].Snip.bits, 0
    mov  [ebx].Snip.pbits, 0
    mov  [ebx].Snip.oldbm, 0
sf_done:
    ret
snip_free ENDP

END
