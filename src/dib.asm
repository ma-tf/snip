; dib.asm
; The Snip: the captured region owned as one cropped 32bpp straight-BGRA DIB,
; with a Pristine twin.
;
; A Snip is made in one shot: allocate Working and Pristine, fill Working from
; the Selection - a screen blit for rect/free-form, PrintWindow for window mode
; (capture.asm) - synthesise alpha, and copy Working into Pristine. No
; full-screen buffer is ever held, and no Snip aliases another surface - it owns
; its pixels outright (ADR-0001).
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
PUBLIC dib_crop_window
PUBLIC dib_crop_free
PUBLIC dib_snip

; Forward declarations so INVOKE reaches callees defined later in the file.
dib_build PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD  ; BOOL dib_build(Snip *sn, DWORD w, DWORD h, Rect *sel, DWORD hwnd) - alloc + capture
dib_fill_opaque PROTO STDCALL :DWORD                    ; void dib_fill_opaque(Snip *sn) - alpha 255, the binary case
dib_coverage PROTO STDCALL :DWORD, :DWORD, :DWORD       ; BOOL dib_coverage(Snip *sn, Pt *path, DWORD n) - the free-form mask
dib_mirror PROTO STDCALL :DWORD                         ; void dib_mirror(Snip *sn) - Working -> Pristine
dib_commit PROTO STDCALL :DWORD                         ; void dib_commit(Snip *src) - replace the live Snip
dib_span PROTO STDCALL :DWORD                           ; DWORD dib_span(Rect *r) - inclusive width
dib_span2 PROTO STDCALL :DWORD                          ; DWORD dib_span2(Rect *r) - inclusive height
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
; dib_crop(Rect *sel) -> BOOL in eax. Make a Snip from a rectangular Selection,
; replacing any previous one. Atomic: the old Snip survives a failure.
;
; All pixels are opaque, so alpha is forced to 255; a rectangular, window, or
; full-screen Snip is binary. Free-form is dib_crop_free.
; ---------------------------------------------------------------------------
dib_crop PROC USES ebx esi edi sel:DWORD
    LOCAL tmp:Snip
    LOCAL w:DWORD
    LOCAL h:DWORD

    mov  ebx, sel
    INVOKE dib_span, ebx
    mov  w, eax
    INVOKE dib_span2, ebx
    mov  h, eax

    cmp  w, 1
    jl   dc_fail
    cmp  h, 1
    jl   dc_fail

    INVOKE dib_build, ADDR tmp, w, h, sel, 0
    test eax, eax
    jz   dc_fail

    INVOKE dib_fill_opaque, ADDR tmp
    INVOKE dib_mirror, ADDR tmp
    INVOKE dib_commit, ADDR tmp

    mov  eax, 1
    ret

dc_fail:
    xor  eax, eax
    ret
dib_crop ENDP

; ---------------------------------------------------------------------------
; dib_crop_window(Rect *sel, DWORD hwnd) -> BOOL in eax. The same build and the
; same atomic replace as dib_crop, but Working is filled by PrintWindow (with the
; region blit as its fallback) instead of the screen blit. A window Snip is
; opaque everywhere, so alpha is forced to 255 like a rectangular one.
; ---------------------------------------------------------------------------
dib_crop_window PROC USES ebx esi edi sel:DWORD, hwnd:DWORD
    LOCAL tmp:Snip
    LOCAL w:DWORD
    LOCAL h:DWORD

    mov  ebx, sel
    INVOKE dib_span, ebx
    mov  w, eax
    INVOKE dib_span2, ebx
    mov  h, eax

    cmp  w, 1
    jl   dw_fail
    cmp  h, 1
    jl   dw_fail

    INVOKE dib_build, ADDR tmp, w, h, sel, hwnd
    test eax, eax
    jz   dw_fail

    INVOKE dib_fill_opaque, ADDR tmp
    INVOKE dib_mirror, ADDR tmp
    INVOKE dib_commit, ADDR tmp

    mov  eax, 1
    ret

dw_fail:
    xor  eax, eax
    ret
dib_crop_window ENDP

; ---------------------------------------------------------------------------
; dib_crop_free(Rect *bbox, Pt *path, DWORD n) -> BOOL in eax. Make a Snip from
; a free-form Trace: the same build as dib_crop, but alpha comes from a GDI+
; coverage mask instead of being forced opaque. The path is in SCREEN pixels;
; it is made bbox-local (and consumed in place) for the fill.
; ---------------------------------------------------------------------------
dib_crop_free PROC USES ebx esi edi sel:DWORD, path:DWORD, n:DWORD
    LOCAL tmp:Snip
    LOCAL w:DWORD
    LOCAL h:DWORD

    mov  ebx, sel
    INVOKE dib_span, ebx
    mov  w, eax
    INVOKE dib_span2, ebx
    mov  h, eax

    cmp  w, 1
    jl   cf_fail
    cmp  h, 1
    jl   cf_fail

    INVOKE dib_build, ADDR tmp, w, h, sel, 0
    test eax, eax
    jz   cf_fail

    INVOKE dib_coverage, ADDR tmp, path, n
    test eax, eax
    jz   cf_free

    INVOKE dib_mirror, ADDR tmp
    INVOKE dib_commit, ADDR tmp

    mov  eax, 1
    ret

cf_free:
    INVOKE snip_free, ADDR tmp
cf_fail:
    xor  eax, eax
    ret
dib_crop_free ENDP

; ---------------------------------------------------------------------------
; dib_span / dib_span2(Rect *r) -> DWORD in eax. The inclusive pixel span:
; geo_width + 1 and geo_height + 1. A box from (5,5) to (5,5) is one pixel.
; ---------------------------------------------------------------------------
dib_span PROC r:DWORD
    INVOKE geo_width, r
    inc  eax
    ret
dib_span ENDP

dib_span2 PROC r:DWORD
    INVOKE geo_height, r
    inc  eax
    ret
dib_span2 ENDP

; ---------------------------------------------------------------------------
; dib_commit(Snip *src) - replace the live Snip with *src. src is consumed; the
; caller must not free it afterwards.
; ---------------------------------------------------------------------------
dib_commit PROC USES esi edi src:DWORD
    INVOKE snip_free, OFFSET cur_snip
    mov  esi, src
    mov  edi, OFFSET cur_snip
    mov  ecx, (SIZEOF Snip) / 4
    rep  movsd
    ret
dib_commit ENDP

; ---------------------------------------------------------------------------
; dib_snip() -> Snip * in eax. The live Snip; its fields are zero when there is
; none, which the Editor treats as "nothing to paint".
; ---------------------------------------------------------------------------
dib_snip PROC
    mov  eax, OFFSET cur_snip
    ret
dib_snip ENDP

; ---------------------------------------------------------------------------
; dib_build(Snip *sn, DWORD w, DWORD h, Rect *sel, DWORD hwnd) -> BOOL in eax.
; Fill *sn with a fresh Snip of w x h pixels captured from the Selection, or zero
; it and return 0. hwnd is 0 for the region blit, or the window to render.
; Anything half-built is freed on the way out. Alpha is left as GDI wrote it
; (zero); the caller synthesises it - opaque or coverage.
; ---------------------------------------------------------------------------
dib_build PROC USES ebx esi edi sn:DWORD, w:DWORD, h:DWORD, sel:DWORD, hwnd:DWORD
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

    ; --- fill Working from the screen, or from the window --------------------
    cmp  hwnd, 0
    je   da_region
    INVOKE capture_window, hwnd, sel, [ebx].Snip.hdc, w, h, [ebx].Snip.bits
    jmp  da_shot
da_region:
    INVOKE capture_region, sel, [ebx].Snip.hdc, w, h
da_shot:
    test eax, eax
    jz   da_fail

    ; --- alpha is the caller's job: dib_fill_opaque or dib_coverage ---------
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
dib_build ENDP

; ---------------------------------------------------------------------------
; dib_fill_opaque(Snip *sn) - force Working's alpha to 255. The binary case:
; rectangular, window, and full-screen Snips are opaque everywhere.
; ---------------------------------------------------------------------------
dib_fill_opaque PROC USES ebx edi sn:DWORD
    mov  ebx, sn
    mov  edi, [ebx].Snip.bits
    test edi, edi
    jz   fo_done
    mov  ecx, [ebx].Snip.w
    cmp  ecx, 1
    jl   fo_done
    mov  eax, [ebx].Snip.h
    cmp  eax, 1
    jl   fo_done
    imul ecx, eax
    mov  eax, 0FF000000h
fo_loop:
    or   dword ptr [edi], eax
    add  edi, 4
    dec  ecx
    jnz  fo_loop
fo_done:
    ret
dib_fill_opaque ENDP

; ---------------------------------------------------------------------------
; dib_mirror(Snip *sn) - copy Working into Pristine, alpha and all, so the two
; start byte-identical. Undo and the Eraser rely on Pristine carrying the Snip's
; true alpha (opaque for a binary Snip, the coverage mask for a free-form one).
; ---------------------------------------------------------------------------
dib_mirror PROC USES ebx esi edi sn:DWORD
    mov  ebx, sn
    mov  edi, [ebx].Snip.bits
    mov  esi, [ebx].Snip.pbits
    test edi, edi
    jz   dm_done
    test esi, esi
    jz   dm_done
    mov  ecx, [ebx].Snip.w
    cmp  ecx, 1
    jl   dm_done
    mov  eax, [ebx].Snip.h
    cmp  eax, 1
    jl   dm_done
    imul ecx, eax
    rep  movsd
dm_done:
    ret
dib_mirror ENDP

; ---------------------------------------------------------------------------
; dib_coverage(Snip *sn, Pt *path, DWORD n) -> BOOL in eax.
;
; Build the free-form Mask: a GDI+ GraphicsPath from the simplified points,
; filled antialiased with nonzero winding onto a zeroed snip-sized scratch
; bitmap. That bitmap's alpha channel *is* the per-pixel coverage, and is copied
; into Working's alpha; the captured colour is never touched. The path arrives
; in screen pixels and is made bbox-local in place - it is the last consumer.
;
; The scratch is wrapped with GdipCreateBitmapFromScan0 rather than drawn through
; a DC: GDI+ leaves a DIB surface's alpha unusable via an HDC (see ink.asm), and
; here the alpha is the whole output. Winding fills a self-crossing loop instead
; of punching a hole through the overlap.
; ---------------------------------------------------------------------------
dib_coverage PROC USES ebx esi edi sn:DWORD, path:DWORD, n:DWORD
    LOCAL hdib:DWORD
    LOCAL bits:DWORD
    LOCAL bmp:DWORD
    LOCAL gfx:DWORD
    LOCAL pth:DWORD
    LOCAL br:DWORD
    LOCAL px:DWORD
    LOCAL py:DWORD
    LOCAL cnt:DWORD
    LOCAL stride:DWORD

    mov  hdib, 0
    mov  bmp, 0
    mov  gfx, 0
    mov  pth, 0
    mov  br, 0

    mov  ebx, sn
    mov  eax, [ebx].Snip.w
    mov  px, eax
    mov  eax, [ebx].Snip.h
    mov  py, eax

    ; Make the path bbox-local: GDI+ fills in the scratch bitmap's own space.
    mov  edi, path
    mov  ecx, n
    test ecx, ecx
    jle  cov_fail
    mov  esi, [ebx].Snip.x
    mov  edx, [ebx].Snip.y
cov_local:
    mov  eax, [edi]
    sub  eax, esi
    mov  [edi], eax
    mov  eax, [edi+4]
    sub  eax, edx
    mov  [edi+4], eax
    add  edi, 8
    dec  ecx
    jnz  cov_local

    ; Zeroed scratch DIB: same size and format as the Snip.
    INVOKE CreateDIBSection, [ebx].Snip.hdc, OFFSET scr_bmi, DIB_RGB_COLORS, ADDR bits, 0, 0
    mov  hdib, eax
    test eax, eax
    jz   cov_fail
    mov  edi, bits
    mov  ecx, px
    imul ecx, py
    xor  eax, eax
    rep  stosd

    ; GDI+ path, filled antialiased.
    mov  eax, px
    shl  eax, 2
    mov  stride, eax
    INVOKE GdipCreateBitmapFromScan0, px, py, stride, PixelFormat32bppARGB, bits, ADDR bmp
    test eax, eax
    jnz  cov_clean
    INVOKE GdipGetImageGraphicsContext, bmp, ADDR gfx
    test eax, eax
    jnz  cov_clean
    INVOKE GdipSetSmoothingMode, gfx, SmoothingModeAntiAlias
    INVOKE GdipCreatePath, FillModeWinding, ADDR pth
    test eax, eax
    jnz  cov_clean
    INVOKE GdipAddPathPolygonI, pth, path, n
    test eax, eax
    jnz  cov_clean
    INVOKE GdipCreateSolidFill, 0FFFFFFFFh, ADDR br
    test eax, eax
    jnz  cov_clean
    INVOKE GdipFillPath, gfx, br, pth
    test eax, eax
    jnz  cov_clean
    INVOKE GdipFlush, gfx, FlushIntentionSync

    ; Working.alpha = coverage, colour untouched.
    mov  esi, [ebx].Snip.bits
    mov  edi, bits
    mov  ecx, px
    imul ecx, py
cov_alpha:
    mov  eax, [edi]
    and  eax, 0FF000000h
    and  dword ptr [esi], 000FFFFFFh
    or   [esi], eax
    add  esi, 4
    add  edi, 4
    dec  ecx
    jnz  cov_alpha

    mov  cnt, 1
    jmp  cov_clean

cov_fail:
    mov  cnt, 0

cov_clean:
    cmp  br, 0
    jz   cov_nb
    INVOKE GdipDeleteBrush, br
cov_nb:
    cmp  pth, 0
    jz   cov_np
    INVOKE GdipDeletePath, pth
cov_np:
    cmp  gfx, 0
    jz   cov_ng
    INVOKE GdipDeleteGraphics, gfx
cov_ng:
    cmp  bmp, 0
    jz   cov_nbmp
    INVOKE GdipDisposeImage, bmp
cov_nbmp:
    cmp  hdib, 0
    jz   cov_done
    INVOKE DeleteObject, hdib
cov_done:
    mov  eax, cnt
    ret
dib_coverage ENDP

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
