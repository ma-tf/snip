; err.asm
; The error surface: one MessageBoxW helper and the app's failure messages.
;
; Ticket 11. When a capture, an encode, a clipboard write, or an allocation
; fails, the module that owns the operation aborts it and calls err_show; this
; module owns how the failure is worded and drawn. There is no status bar, no
; log, and no retry loop - the box is the whole surface.
;
; Nothing an operation does exits the process. Only a startup failure (COM or
; the WIC factory unavailable) reports and then ends the process, and that is
; the one call with no window to own the box.
;
; A capture that succeeds but comes back black is NOT reported: that is a
; documented limitation (DRM video, exclusive-fullscreen surfaces), and the
; caller cannot tell it apart from a legitimately black region. See docs/errors.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC err_show

; ---------------------------------------------------------------------------
; Read-only data. The strings and the id table hold only the bytes they spell;
; both live in .const (.rdata), never a writable .data block. See docs/build.md.
; ---------------------------------------------------------------------------
.const
err_caption    DW 'S','n','i','p','p','i','n','g',' ','T','o','o','l',0

err_capture    DW 'T','h','e',' ','s','n','i','p',' ','c','o','u','l','d',' ','n','o','t',' ','b','e',' ','c','a','p','t','u','r','e','d','.',0
err_copy       DW 'T','h','e',' ','s','n','i','p',' ','c','o','u','l','d',' ','n','o','t',' ','b','e',' ','c','o','p','i','e','d','.',0
err_clipboard  DW 'T','h','e',' ','c','l','i','p','b','o','a','r','d',' ','i','s',' ','i','n',' ','u','s','e',' ','b','y',' ','a','n','o','t','h','e','r',' ','a','p','p','l','i','c','a','t','i','o','n','.',0
err_save       DW 'T','h','e',' ','s','n','i','p',' ','c','o','u','l','d',' ','n','o','t',' ','b','e',' ','s','a','v','e','d','.',0
err_startup    DW 'T','h','e',' ','i','m','a','g','i','n','g',' ','c','o','m','p','o','n','e','n','t',' ','i','s',' ','u','n','a','v','a','i','l','a','b','l','e','.',0
err_shell      DW 'T','h','e',' ','m','a','i','n',' ','w','i','n','d','o','w',' ','c','o','u','l','d',' ','n','o','t',' ','b','e',' ','c','r','e','a','t','e','d','.',0

; Indexed by the ERR_* ids in snip.inc, in order.
err_table      DD OFFSET err_capture, OFFSET err_copy, OFFSET err_clipboard
               DD OFFSET err_save, OFFSET err_startup, OFFSET err_shell

.code

; ---------------------------------------------------------------------------
; err_show(DWORD hwndOwner, DWORD id) -> int in eax (MessageBoxW's result).
; Report the failure named by id. hwndOwner is the window the box belongs to,
; or 0 at startup when there is none. An out-of-range id is ignored rather than
; reading past the table. MB_ICONERROR | MB_OK is the only style: every message
; here is a dead end the user can only acknowledge.
; ---------------------------------------------------------------------------
err_show PROC STDCALL hwndOwner:DWORD, id:DWORD
    mov  eax, id
    cmp  eax, ERR_LAST
    ja   es_none
    mov  eax, err_table[eax*4]
    INVOKE MessageBoxW, hwndOwner, eax, OFFSET err_caption, MB_OK OR MB_ICONERROR
    ret
es_none:
    xor  eax, eax
    ret
err_show ENDP

END
