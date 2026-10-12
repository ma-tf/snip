; shell.asm
; The Shell window: the app's main window and the one place a snip starts.
;
; A New button and two drop-downs (mode and Delay). Both controls are
; owner-drawn by ui.asm (ADR-0004): the buttons carry BS_OWNERDRAW and the
; drop-downs are plain ComboBox controls with CBS_OWNERDRAWFIXED, so they take
; the Fluent look and go dark on a dark system. Each open row carries a 16x16
; glyph and its label; the closed face is icon-only (ticket 07). The glyphs are
; drawn by ui.asm directly - no image list and no icon resources, so no .rsrc
; section and no resource compiler. shell.asm tags each row with a UI_GLYPH_* id
; through CB_SETITEMDATA. Either drop-down records its choice in App; New starts
; a Snipping session through select.asm.
;
; The window is resizable. The controls are fixed at the top; the space below
; them carries a centred hint that advertises Alt+N, laid out in WM_SIZE. The
; hint is a stock Static control, transparent over the window background. See
; docs/shell.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC shell_create

; Forward declarations so INVOKE can reach callees defined later in the file.
shell_on_create  PROTO STDCALL :DWORD, :DWORD
shell_layout     PROTO STDCALL :DWORD
shell_combo_add  PROTO STDCALL :DWORD, :DWORD, :DWORD
shell_focus_combo PROTO STDCALL :DWORD, :DWORD

; ---------------------------------------------------------------------------
; Statics. Module-private: the Shell is a singleton, so its window class can
; live here rather than in App.
;
; Strings and glyph ids are read-only, so they live in .const (.rdata);
; shell_wc and shell_hint are zero-initialised and live in .data? (.bss).
; Neither costs file bytes, which is what keeps the image small. See
; docs/architecture.md.
; ---------------------------------------------------------------------------
.const
shell_class   DW 'S','n','i','p','S','h','e','l','l',0
shell_title   DW 'S','n','i','p','p','i','n','g',' ','T','o','o','l',0
cls_button    DW 'B','u','t','t','o','n',0
cls_combo     DW 'C','o','m','b','o','B','o','x',0
cls_static    DW 'S','t','a','t','i','c',0

text_new      DW 'N','e','w',0
hint_text     DW 'P','r','e','s','s',' ','A','l','t','+','N',' ','f','o','r',' ','a',' ','n','e','w',' ','s','n','i','p',0

mode_rect     DW 'R','e','c','t','a','n','g','l','e',0
mode_win      DW 'W','i','n','d','o','w',0
mode_full     DW 'F','u','l','l',' ','s','c','r','e','e','n',0
mode_free     DW 'F','r','e','e','f','o','r','m',0

; The Delay rows, in order. The row index is App.delay, and select.asm's
; delay_ms table must agree with this list row for row; adding a value here means
; adding its milliseconds there too.
delay_none    DW 'N','o',' ','d','e','l','a','y',0
delay_3       DW '3',' ','s','e','c','o','n','d','s',0
delay_5       DW '5',' ','s','e','c','o','n','d','s',0
delay_10      DW '1','0',' ','s','e','c','o','n','d','s',0

; The drop-down geometry. The face is the selection field; the create-time height
; is the *whole* dropped-down control, so COMBO_DROP_H counts the face's visible
; height (COMBO_FACE_VIS, which matches the New button) plus the list. The list
; area is four rows tall with a hair of padding and no scrollbar.
;
; The closed face is icon-only (ticket 07), so it is only glyph-and-chevron wide
; (COMBO_FACE_W); the open list stays wide enough for the labels (COMBO_DROP_W),
; which CB_SETDROPPEDWIDTH applies to the popup alone.
COMBO_FACE_H   EQU 22           ; the selection-field item height
COMBO_FACE_VIS EQU 28           ; the face's visible height (item height + border)
COMBO_FACE_W   EQU 52           ; the closed face: the glyph, a gap, and the chevron
COMBO_ROW_H    EQU 28
COMBO_DROP_W   EQU 150          ; the open list: room for the glyph and its label
COMBO_DROP_H   EQU COMBO_FACE_VIS + COMBO_ROW_H*4 + 4

.data?
shell_wc      WNDCLASSEXW <>
shell_hint    DWORD ?            ; the hint Static, laid out in WM_SIZE
shell_theme   DWORD ?            ; the theme flag this window last drew (live update)

; The Shell is resizable and maximizable. The three controls stay fixed at the
; top; the hint is centred in the space below them.
SHELL_STYLE      EQU WS_CAPTION OR WS_SYSMENU OR WS_MINIMIZEBOX OR WS_MAXIMIZEBOX OR WS_THICKFRAME

SHELL_MARGIN     EQU 12          ; inset of the control row and the hint
SHELL_ROW_BOTTOM EQU 46          ; below the 28px control row that starts at y=12
SHELL_MINW       EQU 404         ; client width of the control row plus margins
SHELL_MINH       EQU 120         ; the control row and a line of hint
SHELL_DEFW       EQU 440         ; a little slack over the minimum
SHELL_DEFH       EQU 180

; ---------------------------------------------------------------------------
.code

; ---------------------------------------------------------------------------
; shell_create(app) -> HWND in eax, or 0 if the window could not be made.
; Registers the Shell class, creates the window, and shows it. The controls are
; built in WM_CREATE, where the app pointer arrives as lpCreateParams.
; ---------------------------------------------------------------------------
shell_create PROC USES ebx app:DWORD
    mov  ebx, app

    mov  shell_wc.cbSize, SIZEOF WNDCLASSEXW
    mov  shell_wc.style, CS_HREDRAW OR CS_VREDRAW
    mov  shell_wc.lpfnWndProc, OFFSET shell_wndproc
    mov  shell_wc.cbClsExtra, 0
    mov  shell_wc.cbWndExtra, 0
    mov  eax, [ebx].App.hInstance
    mov  shell_wc.hInstance, eax
    INVOKE theme_bg_brush
    mov  shell_wc.hbrBackground, eax

    INVOKE LoadCursorW, 0, IDC_ARROW
    mov  shell_wc.hCursor, eax

    mov  shell_wc.lpszClassName, OFFSET shell_class

    INVOKE RegisterClassExW, OFFSET shell_wc
    test eax, eax
    jz   shell_create_done_fail

    mov  edx, [ebx].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET shell_class, OFFSET shell_title, SHELL_STYLE, CW_USEDEFAULT, CW_USEDEFAULT, SHELL_DEFW, SHELL_DEFH, 0, 0, edx, ebx
    test eax, eax
    jz   shell_create_done

    mov  ebx, eax            ; hwnd
    INVOKE ShowWindow, ebx, SW_SHOWDEFAULT
    INVOKE UpdateWindow, ebx
    mov  eax, ebx
    jmp  shell_create_done

shell_create_done_fail:
    xor  eax, eax
shell_create_done:
    ret
shell_create ENDP

; ---------------------------------------------------------------------------
; shell_wndproc(hwnd, msg, wParam, lParam)
; ---------------------------------------------------------------------------
shell_wndproc PROC hwnd:DWORD, msg:DWORD, wParam:DWORD, lParam:DWORD
    LOCAL id:DWORD
    LOCAL app:DWORD
    LOCAL rc:RECT

    mov  eax, msg
    cmp  eax, WM_CREATE
    je   wm_create
    cmp  eax, WM_SIZE
    je   wm_size
    cmp  eax, WM_GETMINMAXINFO
    je   wm_minmax
    cmp  eax, WM_CTLCOLORSTATIC
    je   wm_ctlcolor
    cmp  eax, WM_COMMAND
    je   wm_command
    cmp  eax, WM_DRAWITEM
    je   wm_drawitem
    cmp  eax, WM_SETTINGCHANGE
    je   wm_settingchange
    cmp  eax, WM_DESTROY
    je   wm_destroy

wnd_default:
    INVOKE DefWindowProcW, hwnd, msg, wParam, lParam
    ret

wm_create:
    ; app = ((CREATESTRUCTW *)lParam)->lpCreateParams, the struct's first field
    mov  eax, lParam
    mov  eax, [eax]
    INVOKE SetWindowLongW, hwnd, GWLP_USERDATA, eax
    mov  eax, lParam
    mov  eax, [eax]
    INVOKE shell_on_create, hwnd, eax
    xor  eax, eax
    ret

wm_size:
    ; The controls are fixed; only the hint moves. WM_SIZE arrives after
    ; WM_CREATE with the real client size, and again on every resize.
    INVOKE shell_layout, hwnd
    xor  eax, eax
    ret

wm_minmax:
    ; Start from DefWindowProc's limits, then raise the minimum so the window
    ; cannot be dragged smaller than the control row and a line of hint.
    INVOKE DefWindowProcW, hwnd, WM_GETMINMAXINFO, 0, lParam
    mov  rc.left, 0
    mov  rc.top, 0
    mov  rc.right, SHELL_MINW
    mov  rc.bottom, SHELL_MINH
    INVOKE AdjustWindowRect, ADDR rc, SHELL_STYLE, 0
    mov  eax, lParam
    mov  ecx, rc.right
    sub  ecx, rc.left
    mov  [eax].MINMAXINFO.ptMinTrackSize.x, ecx
    mov  ecx, rc.bottom
    sub  ecx, rc.top
    mov  [eax].MINMAXINFO.ptMinTrackSize.y, ecx
    xor  eax, eax
    ret

wm_ctlcolor:
    ; The hint shows the window background through it: transparent text and no
    ; background fill from the static. wParam is the static's HDC.
    INVOKE SetBkMode, wParam, TRANSPARENT_BK
    INVOKE theme_hint_color
    INVOKE SetTextColor, wParam, eax
    INVOKE GetStockObject, NULL_BRUSH
    ret

wm_command:
    ; wParam holds the control id (low word) and the notification (high word);
    ; for a combo notification, lParam is the control's HWND.
    mov  eax, wParam
    and  eax, 0FFFFh
    mov  edx, wParam
    shr  edx, 16
    and  edx, 0FFFFh

    ; An accelerator (ticket 12) arrives here as a WM_COMMAND whose notification
    ; word is 1, which is also CBN_SELCHANGE's value - so the IDA_* ids are
    ; dispatched before any control-notification logic. See docs/keyboard.md.
    cmp  edx, 1
    jne  wm_notify_click
    cmp  eax, IDA_NEW
    je   wm_accel_new
    cmp  eax, IDA_MODE
    je   wm_accel_mode
    cmp  eax, IDA_DELAY
    je   wm_accel_delay
    jmp  wnd_default

wm_notify_click:
    ; New: start a Snipping session (ticket 02).
    cmp  edx, BN_CLICKED
    jne  wm_notify_combo
    cmp  eax, IDC_NEW
    jne  wnd_default
    INVOKE GetWindowLongW, hwnd, GWLP_USERDATA
    INVOKE select_begin, eax
    xor  eax, eax
    ret

; Alt+N: the same as clicking New. select_begin hides the Shell, so it goes last.
wm_accel_new:
    INVOKE GetWindowLongW, hwnd, GWLP_USERDATA
    INVOKE select_begin, eax
    xor  eax, eax
    ret

; Alt+M / Alt+D: put focus in the drop-down and drop it, the reference's
; keyboard path to the choice. shell_focus_combo is shared by the two.
wm_accel_mode:
    INVOKE shell_focus_combo, hwnd, IDC_MODE
    xor  eax, eax
    ret

wm_accel_delay:
    INVOKE shell_focus_combo, hwnd, IDC_DELAY
    xor  eax, eax
    ret

wm_notify_combo:
    cmp  edx, CBN_SELCHANGE
    jne  wnd_default
    cmp  eax, IDC_MODE
    je   wm_combo
    cmp  eax, IDC_DELAY
    jne  wnd_default

wm_combo:
    mov  id, eax             ; which drop-down
    INVOKE GetWindowLongW, hwnd, GWLP_USERDATA
    mov  app, eax
    INVOKE SendMessageW, lParam, CB_GETCURSEL, 0, 0
    mov  edx, id
    mov  ecx, app
    cmp  edx, IDC_MODE
    jne  wm_combo_delay
    mov  [ecx].App.mode, eax
    ret
wm_combo_delay:
    mov  [ecx].App.delay, eax
    ret

; The system theme changed (WM_SETTINGCHANGE). Re-read it; if it differs from
; what this window last drew, rebuild the class background brush and repaint the
; window and its hint. lParam is ignored: on a broadcast it names
; "ImmersiveColorSet", but that pointer is not reliably readable across
; processes, and re-reading the value is the robust check. The Editor gets the
; same broadcast and repaints itself. See docs/theme.md.
wm_settingchange:
    INVOKE theme_refresh
    cmp  eax, shell_theme
    je   wm_settingchange_done
    mov  shell_theme, eax

    ; Re-dress the frame (DWM title bar) and swap the class background.
    INVOKE theme_apply, hwnd
    INVOKE theme_bg_brush
    INVOKE SetClassLongW, hwnd, GCLP_HBRBACKGROUND, eax

    ; Repaint the window and its children (the hint static shows through it).
    INVOKE RedrawWindow, hwnd, 0, 0, RDW_INVALIDATE OR RDW_ERASE OR RDW_ALLCHILDREN OR RDW_UPDATENOW

wm_settingchange_done:
    xor  eax, eax
    ret

; A control asked to be painted. ui.asm owns the look; wParam is the control id
; (which the skin does not need) and lParam is the DRAWITEMSTRUCT.
wm_drawitem:
    INVOKE ui_draw_item, hwnd, lParam
    xor  eax, eax
    ret

wm_destroy:
    INVOKE PostQuitMessage, 0
    xor  eax, eax
    ret
shell_wndproc ENDP

; ---------------------------------------------------------------------------
; shell_focus_combo(hwnd, id) -> eax 0. Alt+M / Alt+D (ticket 12): put focus in
; the drop-down named by id, then drop its list.
;
; A plain ComboBox (ticket 03) honours CB_SHOWDROPDOWN, so opening the list is
; just focus plus that message. The old ComboBoxEx32 ignored it and needed a
; synthesised Alt+Down through SendInput; that whole path is gone with the
; control. Arrow keys still navigate the open list and Escape closes it, both
; supplied by IsDialogMessageW, exactly as before.
; ---------------------------------------------------------------------------
shell_focus_combo PROC hwnd:DWORD, id:DWORD
    INVOKE GetDlgItem, hwnd, id
    test eax, eax
    jz   sfc_done
    INVOKE SetFocus, eax
    INVOKE SendMessageW, eax, CB_SHOWDROPDOWN, 1, 0
sfc_done:
    xor  eax, eax
    ret
shell_focus_combo ENDP

; ---------------------------------------------------------------------------
; shell_on_create(hwnd, app) -> eax 0.
; Builds the three controls and sets the stock font on each.
; ---------------------------------------------------------------------------
shell_on_create PROC USES ebx esi hwnd:DWORD, app:DWORD
    LOCAL hCtl:DWORD
    LOCAL font:DWORD

    mov  ebx, hwnd
    mov  esi, app

    ; Rounded frame, themed title bar, dark common-control theme.
    INVOKE theme_apply, ebx

    ; Record the theme this window is built with, for the live-update compare.
    INVOKE theme_refresh
    mov  shell_theme, eax

    INVOKE GetStockObject, DEFAULT_GUI_FONT
    mov  font, eax

    ; --- New button: 12,12 64x28, id IDC_NEW --------------------------------
    ; BS_OWNERDRAW: ui.asm paints it, a plain button with a leading "+" and label.
    mov  edx, [esi].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET cls_button, OFFSET text_new, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_OWNERDRAW, 12, 12, 64, 28, ebx, IDC_NEW, edx, 0
    mov  hCtl, eax
    INVOKE ui_attach, hCtl, UI_KIND_BUTTON_GLYPH, UI_AMBIENT_BG

    ; --- mode drop-down: 84,12 COMBO_FACE_W x COMBO_DROP_H, id IDC_MODE ------
    ; A plain ComboBox with CBS_OWNERDRAWFIXED: ui.asm paints the face and every
    ; row. WM_SETFONT and CB_SETITEMHEIGHT fix the row and face heights before
    ; the rows are added; each row's glyph id is stashed with CB_SETITEMDATA.
    ; The face is icon-only (ticket 07), so the control is only COMBO_FACE_W wide;
    ; CB_SETDROPPEDWIDTH widens the popup to COMBO_DROP_W so the labels still fit.
    mov  edx, [esi].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET cls_combo, 0, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR CBS_DROPDOWNLIST OR CBS_OWNERDRAWFIXED OR CBS_HASSTRINGS, 84, 12, COMBO_FACE_W, COMBO_DROP_H, ebx, IDC_MODE, edx, 0
    mov  hCtl, eax
    INVOKE SendMessageW, hCtl, WM_SETFONT, font, 1
    INVOKE SendMessageW, hCtl, CB_SETITEMHEIGHT, -1, COMBO_FACE_H
    INVOKE SendMessageW, hCtl, CB_SETITEMHEIGHT, 0, COMBO_ROW_H
    INVOKE SendMessageW, hCtl, CB_SETDROPPEDWIDTH, COMBO_DROP_W, 0
    INVOKE ui_attach, hCtl, UI_KIND_COMBO, UI_AMBIENT_BG
    INVOKE shell_combo_add, hCtl, OFFSET mode_rect, UI_GLYPH_RECT
    INVOKE shell_combo_add, hCtl, OFFSET mode_win, UI_GLYPH_WINDOW
    INVOKE shell_combo_add, hCtl, OFFSET mode_full, UI_GLYPH_FULL
    INVOKE shell_combo_add, hCtl, OFFSET mode_free, UI_GLYPH_FREE
    INVOKE SendMessageW, hCtl, CB_SETCURSEL, 0, 0

    ; --- Delay drop-down: 144,12 COMBO_FACE_W x COMBO_DROP_H, id IDC_DELAY ----
    mov  edx, [esi].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET cls_combo, 0, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR CBS_DROPDOWNLIST OR CBS_OWNERDRAWFIXED OR CBS_HASSTRINGS, 144, 12, COMBO_FACE_W, COMBO_DROP_H, ebx, IDC_DELAY, edx, 0
    mov  hCtl, eax
    INVOKE SendMessageW, hCtl, WM_SETFONT, font, 1
    INVOKE SendMessageW, hCtl, CB_SETITEMHEIGHT, -1, COMBO_FACE_H
    INVOKE SendMessageW, hCtl, CB_SETITEMHEIGHT, 0, COMBO_ROW_H
    INVOKE SendMessageW, hCtl, CB_SETDROPPEDWIDTH, COMBO_DROP_W, 0
    INVOKE ui_attach, hCtl, UI_KIND_COMBO, UI_AMBIENT_BG
    INVOKE shell_combo_add, hCtl, OFFSET delay_none, UI_GLYPH_CLOCK
    INVOKE shell_combo_add, hCtl, OFFSET delay_3, UI_GLYPH_CLOCK
    INVOKE shell_combo_add, hCtl, OFFSET delay_5, UI_GLYPH_CLOCK
    INVOKE shell_combo_add, hCtl, OFFSET delay_10, UI_GLYPH_CLOCK
    INVOKE SendMessageW, hCtl, CB_SETCURSEL, 0, 0

    ; --- hint: centred in the space below the control row, id IDC_HINT -------
    ; Created at a placeholder size; WM_SIZE (which follows WM_CREATE) gives it
    ; the real region through shell_layout.
    mov  edx, [esi].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET cls_static, OFFSET hint_text, WS_CHILD OR WS_VISIBLE OR SS_CENTER OR SS_CENTERIMAGE, SHELL_MARGIN, SHELL_ROW_BOTTOM, 200, 40, ebx, IDC_HINT, edx, 0
    mov  shell_hint, eax
    INVOKE SendMessageW, eax, WM_SETFONT, font, 1

    ; Lay out once here too, so the hint is placed even if no WM_SIZE follows
    ; (it does; re-running is harmless).
    INVOKE shell_layout, ebx

    xor  eax, eax
    ret
shell_on_create ENDP

; ---------------------------------------------------------------------------
; shell_layout(hwnd) -> void. The controls are fixed at the top; the hint fills
; the rectangle below them, inset by SHELL_MARGIN, and centres its text. Called
; from WM_SIZE and once from shell_on_create.
; ---------------------------------------------------------------------------
shell_layout PROC USES edi hwnd:DWORD
    LOCAL rc:RECT

    mov  eax, shell_hint
    test eax, eax
    jz   sl_done

    INVOKE GetClientRect, hwnd, ADDR rc
    mov  edi, rc.right
    sub  edi, SHELL_MARGIN          ; hint width
    mov  edx, rc.bottom
    sub  edx, SHELL_ROW_BOTTOM      ; hint height
    test edi, edi
    jle  sl_done
    test edx, edx
    jle  sl_done
    INVOKE MoveWindow, shell_hint, SHELL_MARGIN, SHELL_ROW_BOTTOM, edi, edx, 1
sl_done:
    ret
shell_layout ENDP

; ---------------------------------------------------------------------------
; shell_combo_add(hcombo, pszText, glyphId) -> void. Adds one owner-draw row:
; the text, then the UI_GLYPH_* id ui.asm will draw, stashed with CB_SETITEMDATA.
; ---------------------------------------------------------------------------
shell_combo_add PROC USES ebx hcombo:DWORD, pszText:DWORD, glyphId:DWORD
    mov  ebx, hcombo
    INVOKE SendMessageW, ebx, CB_ADDSTRING, 0, pszText
    cmp  eax, -1
    je   sca_done
    INVOKE SendMessageW, ebx, CB_SETITEMDATA, eax, glyphId
sca_done:
    ret
shell_combo_add ENDP

END
