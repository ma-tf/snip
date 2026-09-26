; capture.asm
; Screen capture: the region of the desktop a Snip is made from.
;
; Ticket 03 is one BitBlt from the screen DC into a caller's bitmap. The
; Selection is in virtual-screen physical pixels, and those are exactly the
; source coordinates the screen DC accepts - including a negative origin, which
; BitBlt takes and reads back black for the off-desktop part. So the whole
; virtual screen is never captured as an intermediate; the Snip's bitmap is
; filled directly, which is why a Snip owns its pixels outright from the start
; (ADR-0001).
;
; The process is per-monitor DPI aware v2 (set in snip.asm before any window),
; so the screen DC is raw physical pixels and the metrics are not virtualised.
;
; This module owns nothing between calls. Window mode (ticket 08) adds a
; PrintWindow path beside capture_region; the region blit stays the fallback.
;
; See docs/capture.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC capture_region

.code

; ---------------------------------------------------------------------------
; capture_region(Rect *sel, DWORD hdcDst, DWORD w, DWORD h) -> BOOL in eax.
; Blit the Selection from the screen into hdcDst at (0,0). The destination is a
; 32bpp DIB section the caller owns, sized w x h, so no scaling or conversion
; happens. An empty rectangle is a failure, not a quiet no-op.
; ---------------------------------------------------------------------------
capture_region PROC USES esi sel:DWORD, hdcDst:DWORD, w:DWORD, h:DWORD
    LOCAL hdcScr:DWORD
    LOCAL ok:DWORD
    LOCAL sx:DWORD
    LOCAL sy:DWORD

    mov  ok, 0
    cmp  w, 0
    jle  cr_done
    cmp  h, 0
    jle  cr_done

    ; SRCCOPY | CAPTUREBLT, source at the Selection's screen coordinates. Read
    ; the rectangle into locals first: INVOKE evaluates its arguments while it
    ; sets up the call, and passing a memory operand into a live register is the
    ; kind of thing that reads differently on the two targets.
    mov  esi, sel
    mov  eax, [esi].Rect.left
    mov  sx, eax
    mov  eax, [esi].Rect.top
    mov  sy, eax

    INVOKE GetDC, 0
    mov  hdcScr, eax
    test eax, eax
    jz   cr_done

    INVOKE BitBlt, hdcDst, 0, 0, w, h, hdcScr, sx, sy, SRCCOPY OR CAPTUREBLT
    mov  ok, eax

    INVOKE ReleaseDC, 0, hdcScr

cr_done:
    mov  eax, ok
    ret
capture_region ENDP

END
