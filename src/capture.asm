; capture.asm
; Screen capture: the region of the desktop a Snip is made from, and the window
; that a Window-mode Snip is made from.
;
; Ticket 03 is one BitBlt from the screen DC into a caller's bitmap. The
; Selection is in virtual-screen physical pixels, and those are exactly the
; source coordinates the screen DC accepts - including a negative origin, which
; BitBlt takes and reads back black for the off-desktop part. So the whole
; virtual screen is never captured as an intermediate; the Snip's bitmap is
; filled directly, which is why a Snip owns its pixels outright from the start
; (ADR-0001).
;
; Ticket 08 adds the window path beside it. PrintWindow renders a window into
; the same bitmap, and PW_RENDERFULLCONTENT is what makes a DirectComposition
; window come back with real pixels instead of a black rectangle. PrintWindow
; *blocks* and runs the target's code, so it runs on a worker thread and the UI
; thread waits with a timeout; a hung target is abandoned and the caller falls
; back to a plain PrintWindow, then to a screen blit of the window rect.
;
; The process is per-monitor DPI aware v2 (set in snip.asm before any window),
; so the screen DC is raw physical pixels and the metrics are not virtualised.
;
; This module owns nothing between calls save the lazily resolved
; DwmGetWindowAttribute entry point (see window_frame).
;
; See docs/capture.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC capture_region
PUBLIC capture_window
PUBLIC window_frame

; Forward declarations so INVOKE reaches callees defined later in the file.
cap_print      PROTO STDCALL :DWORD                         ; DWORD cap_print(CAPJOB *job) - the PrintWindow worker
cap_print_try  PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD  ; DWORD cap_print_try(hwnd, hdc, flags, bits, w, h)
cap_content    PROTO STDCALL :DWORD, :DWORD, :DWORD        ; BOOL cap_content(bits, w, h) - any non-black pixel?
dwm_resolve    PROTO STDCALL                                ; void - resolve DwmGetWindowAttribute once

; The worker thread's arguments, built on cap_print_try's stack. It is read
; only while the UI thread is waiting, and the worker's result comes back as the
; thread's exit code, so nothing shared is written but the destination DIB.
CAPJOB STRUCT
    job_hwnd  DWORD ?
    job_hdc   DWORD ?
    job_flags DWORD ?
CAPJOB ENDS

.const
; dwmapi.dll and the one entry point resolved from it, so the build needs no new
; import library (the same Crinkler-safe pattern encode.asm uses for combase).
dwmapi_dll              DB 'dwmapi.dll',0
fn_DwmGetWindowAttribute DB 'DwmGetWindowAttribute',0

.data?
pfn_DwmGetWindowAttribute DWORD ?   ; resolved on first window_frame
dwm_tried                 DWORD ?   ; 1 once resolution has been attempted

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

; ---------------------------------------------------------------------------
; window_frame(HWND hwnd, Rect *out) -> BOOL in eax.
; The top-level window's frame in SCREEN physical pixels. Prefers
; DWMWA_EXTENDED_FRAME_BOUNDS, which excludes the invisible Win11 resize border
; GetWindowRect includes; falls back to GetWindowRect for windows DWM refuses
; (some popups and layered windows). Our Rect has the same layout as RECT, so
; the pointers are interchangeable.
; ---------------------------------------------------------------------------
window_frame PROC USES ebx hwnd:DWORD, frame:DWORD
    INVOKE dwm_resolve
    mov  eax, pfn_DwmGetWindowAttribute
    test eax, eax
    jz   wf_fallback

    ; DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, frame, sizeof RECT)
    ; Called through the pointer, so the arguments are pushed by hand; the
    ; callee is stdcall and balances its own 16 bytes. A nonzero HRESULT
    ; (negative here) means "no DWM frame", e.g. an uncomposited popup.
    push 16
    push frame
    push DWMWA_EXTENDED_FRAME_BOUNDS
    push hwnd
    call eax
    test eax, eax
    js   wf_fallback
    mov  eax, 1
    ret

wf_fallback:
    INVOKE GetWindowRect, hwnd, frame
    test eax, eax
    jz   wf_fail
    mov  eax, 1
    ret
wf_fail:
    xor  eax, eax
    ret
window_frame ENDP

; ---------------------------------------------------------------------------
; dwm_resolve() - load dwmapi.dll and resolve DwmGetWindowAttribute, once. A
; failure leaves the pointer null, which means "always use GetWindowRect"; it
; is not fatal.
; ---------------------------------------------------------------------------
dwm_resolve PROC
    cmp  dwm_tried, 0
    jne  dr_done
    mov  dwm_tried, 1

    INVOKE LoadLibraryA, OFFSET dwmapi_dll
    test eax, eax
    jz   dr_done
    INVOKE GetProcAddress, eax, OFFSET fn_DwmGetWindowAttribute
    mov  pfn_DwmGetWindowAttribute, eax

dr_done:
    ret
dwm_resolve ENDP

; ---------------------------------------------------------------------------
; capture_window(HWND hwnd, Rect *sel, DWORD hdcDst, DWORD w, DWORD h, DWORD bits)
;   -> BOOL in eax.
;
; Fill hdcDst from the window, trying in order: PrintWindow with
; PW_RENDERFULLCONTENT, PrintWindow plain, then a screen blit of *sel (SCREEN
; pixels). A timeout on the first attempt skips straight to the blit, because a
; target that hangs one PrintWindow hangs both. The blit's result is accepted
; even if it is black: a black-but-successful capture is a documented
; limitation, not an error. Returns 0 only when every path failed.
; ---------------------------------------------------------------------------
capture_window PROC USES ebx hwnd:DWORD, sel:DWORD, hdcDst:DWORD, w:DWORD, h:DWORD, bits:DWORD
    ; --- 1. the full-content render ----------------------------------------
    INVOKE cap_print_try, hwnd, hdcDst, PW_RENDERFULLCONTENT, bits, w, h
    cmp  eax, 1
    je   cw_ok
    cmp  eax, 2
    je   cw_blit                     ; timed out: do not try the plain variant

    ; --- 2. a plain render (some apps answer WM_PRINT but not the full path) -
    INVOKE cap_print_try, hwnd, hdcDst, 0, bits, w, h
    cmp  eax, 1
    je   cw_ok

    ; --- 3. the screen blit of the window rect, the guaranteed path ---------
cw_blit:
    INVOKE capture_region, sel, hdcDst, w, h
    test eax, eax
    jz   cw_fail

cw_ok:
    mov  eax, 1
    ret
cw_fail:
    xor  eax, eax
    ret
capture_window ENDP

; ---------------------------------------------------------------------------
; cap_print_try(hwnd, hdc, flags, bits, w, h) -> DWORD status in eax.
; Run one PrintWindow on a worker thread and wait CAP_TIMEOUT_MS for it.
;   1 = the call succeeded and left non-black pixels       (usable)
;   2 = the worker timed out                               (the target is hung)
;   0 = the call failed, or produced an all-black bitmap   (try the next path)
;
; The worker is *always* fully stopped before this returns - on a timeout that
; means TerminateThread, then waiting on the handle, which signals only once the
; thread has actually gone. That is what makes it safe for the caller to reuse
; the destination DC immediately afterwards.
; ---------------------------------------------------------------------------
cap_print_try PROC USES ebx hwnd:DWORD, hdc:DWORD, flags:DWORD, bits:DWORD, w:DWORD, h:DWORD
    LOCAL job:CAPJOB
    LOCAL thread:DWORD
    LOCAL code:DWORD

    mov  eax, hwnd
    mov  job.job_hwnd, eax
    mov  eax, hdc
    mov  job.job_hdc, eax
    mov  eax, flags
    mov  job.job_flags, eax
    mov  code, 0

    ; CreateThread(NULL, 0, cap_print, &job, 0, NULL). The job lives on this
    ; frame and is valid for the whole wait.
    INVOKE CreateThread, 0, 0, OFFSET cap_print, ADDR job, 0, 0
    mov  thread, eax
    test eax, eax
    jz   cpt_fail

    INVOKE WaitForSingleObject, thread, CAP_TIMEOUT_MS
    cmp  eax, WAIT_OBJECT_0
    jne  cpt_timeout

    ; It signalled: PrintWindow's BOOL is the thread's exit code.
    INVOKE GetExitCodeThread, thread, ADDR code
    INVOKE CloseHandle, thread
    cmp  code, 0
    je   cpt_fail                    ; PrintWindow returned FALSE
    INVOKE cap_content, bits, w, h
    test eax, eax
    jz   cpt_fail                    ; succeeded but all black: try the next path
    mov  eax, 1
    ret

cpt_timeout:
    ; -1 is INFINITE. Waiting after TerminateThread guarantees the thread is no
    ; longer touching the DC before the caller reuses it.
    INVOKE TerminateThread, thread, 0
    INVOKE WaitForSingleObject, thread, -1
    INVOKE CloseHandle, thread
    mov  eax, 2
    ret

cpt_fail:
    xor  eax, eax
    ret
cap_print_try ENDP

; ---------------------------------------------------------------------------
; cap_print(CAPJOB *job) -> BOOL in eax. The worker thread body: one
; PrintWindow. Its return value becomes the thread's exit code, which
; cap_print_try reads back, so no shared result field is needed. The thread
; procedure is stdcall, so PROC's epilogue does the ret 4.
; ---------------------------------------------------------------------------
cap_print PROC USES ebx job:DWORD
    mov  ebx, job
    INVOKE PrintWindow, [ebx].CAPJOB.job_hwnd, [ebx].CAPJOB.job_hdc, [ebx].CAPJOB.job_flags
    ret
cap_print ENDP

; ---------------------------------------------------------------------------
; cap_content(bits, w, h) -> BOOL in eax. Nonzero if any pixel has a non-zero
; colour byte. Used to reject the all-black bitmap a DirectComposition window
; returns without PW_RENDERFULLCONTENT, so the fallback chain can advance. The
; alpha byte is ignored: GDI does not manage it, so it carries no information
; here.
; ---------------------------------------------------------------------------
cap_content PROC USES esi ecx bits:DWORD, w:DWORD, h:DWORD
    mov  esi, bits
    test esi, esi
    jz   cc_none
    mov  eax, w
    imul eax, h
    test eax, eax
    jle  cc_none
    mov  ecx, eax

cc_loop:
    mov  eax, [esi]
    and  eax, 000FFFFFFh
    jnz  cc_yes
    add  esi, 4
    dec  ecx
    jnz  cc_loop

cc_none:
    xor  eax, eax
    ret
cc_yes:
    mov  eax, 1
    ret
cap_content ENDP

END
