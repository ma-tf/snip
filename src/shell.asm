; shell.asm
; The Shell window: the app's main window and the one place a snip starts.
;
; A New button and two ComboBoxEx drop-downs (mode and Delay), each row carrying
; a 16x16 icon drawn at runtime with GDI into a shared image list - no icon
; resources, so no .rsrc section and no resource compiler. Either drop-down
; records its choice in App; New does nothing yet. Starting a session is ticket
; 02. See docs/shell.md.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC shell_create

; Forward declarations so INVOKE can reach callees defined later in the file.
shell_on_create  PROTO STDCALL :DWORD, :DWORD
shell_combo_item PROTO STDCALL :DWORD, :DWORD, :DWORD
shell_make_icons PROTO STDCALL
smi_clear        PROTO STDCALL :DWORD
smi_hollow       PROTO STDCALL :DWORD
smi_publish      PROTO STDCALL :DWORD, :DWORD

; ---------------------------------------------------------------------------
; Statics. Module-private: the Shell is a singleton, so its window class can
; live here rather than in App.
;
; Strings and glyph geometry are read-only, so they live in .const (.rdata);
; shell_wc and shell_icons are zero-initialised and live in .data? (.bss).
; Neither costs file bytes, which is what keeps the image small. See
; docs/architecture.md.
; ---------------------------------------------------------------------------
.const
shell_class   DW 'S','n','i','p','S','h','e','l','l',0
shell_title   DW 'S','n','i','p','p','i','n','g',' ','T','o','o','l',0
cls_button    DW 'B','u','t','t','o','n',0
cls_combo     DW 'C','o','m','b','o','B','o','x','E','x','3','2',0

text_new      DW 'N','e','w',0

mode_rect     DW 'R','e','c','t','a','n','g','l','e',0
mode_win      DW 'W','i','n','d','o','w',0
mode_full     DW 'F','u','l','l',' ','s','c','r','e','e','n',0
mode_free     DW 'F','r','e','e','f','o','r','m',0

delay_none    DW 'N','o',' ','d','e','l','a','y',0
delay_3       DW '3',' ','s','e','c','o','n','d','s',0
delay_5       DW '5',' ','s','e','c','o','n','d','s',0
delay_10      DW '1','0',' ','s','e','c','o','n','d','s',0

; Image-list order. Both drop-downs share one list, so the indices are global.
ICON_RECT     EQU 0
ICON_WINDOW   EQU 1
ICON_FULL     EQU 2
ICON_FREE     EQU 3
ICON_CLOCK    EQU 4
ICON_COLORKEY EQU 00FF00FFh        ; magenta: never drawn, the transparency key

ICON_SIZE     EQU 16

; The scratch 32bpp DIB every glyph is drawn into, then masked on the colour key.
smi_bmi       BITMAPINFOHEADER <40, ICON_SIZE, ICON_SIZE, 1, 32, BI_RGB, 0, 0, 0, 0, 0>

; Glyph geometry, in the 16x16 cell. Polylines only, so shell_make_icons needs
; no struct arrays beyond POINT.
pts_tl        POINT <1,5>, <1,1>, <5,1>          ; full-screen corner brackets
pts_tr        POINT <11,1>, <15,1>, <15,5>
pts_br        POINT <15,11>, <15,15>, <11,15>
pts_bl        POINT <5,15>, <1,15>, <1,11>
pts_free      POINT <3,11>, <4,6>, <8,3>, <12,4>, <9,9>, <5,9>, <6,12>
pts_hand_v    POINT <8,8>, <8,5>                  ; clock: minute hand up
pts_hand_h    POINT <8,8>, <11,10>                ; clock: hour hand out

.data?
shell_wc      WNDCLASSEXW <>
shell_icons   DWORD ?            ; HIMAGELIST, ours to destroy. Module-private
                                 ; because the Shell is a singleton.

SHELL_STYLE   EQU WS_CAPTION OR WS_SYSMENU OR WS_MINIMIZEBOX

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
    mov  shell_wc.hbrBackground, COLOR_WINDOW_1

    INVOKE LoadCursorW, 0, IDC_ARROW
    mov  shell_wc.hCursor, eax

    mov  shell_wc.lpszClassName, OFFSET shell_class

    INVOKE RegisterClassExW, OFFSET shell_wc
    test eax, eax
    jz   shell_create_done_fail

    mov  edx, [ebx].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET shell_class, OFFSET shell_title, SHELL_STYLE, CW_USEDEFAULT, CW_USEDEFAULT, 420, 140, 0, 0, edx, ebx
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

    mov  eax, msg
    cmp  eax, WM_CREATE
    je   wm_create
    cmp  eax, WM_COMMAND
    je   wm_command
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

wm_command:
    ; wParam holds the control id (low word) and the notification (high word);
    ; for a combo notification, lParam is the control's HWND.
    mov  eax, wParam
    and  eax, 0FFFFh
    mov  edx, wParam
    shr  edx, 16
    and  edx, 0FFFFh

    ; New: start a Snipping session (ticket 02).
    cmp  edx, BN_CLICKED
    jne  wm_notify_combo
    cmp  eax, IDC_NEW
    jne  wnd_default
    INVOKE GetWindowLongW, hwnd, GWLP_USERDATA
    INVOKE select_begin, eax
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

wm_destroy:
    ; The image list is ours, not the controls': destroy it before we quit.
    mov  eax, shell_icons
    test eax, eax
    jz   wm_destroy_quit
    INVOKE ImageList_Destroy, shell_icons
    mov  shell_icons, 0
wm_destroy_quit:
    INVOKE PostQuitMessage, 0
    xor  eax, eax
    ret
shell_wndproc ENDP

; ---------------------------------------------------------------------------
; shell_on_create(hwnd, app) -> eax 0.
; Builds the three controls and sets the stock font on each.
; ---------------------------------------------------------------------------
shell_on_create PROC USES ebx esi hwnd:DWORD, app:DWORD
    LOCAL hCtl:DWORD
    LOCAL font:DWORD

    mov  ebx, hwnd
    mov  esi, app

    INVOKE GetStockObject, DEFAULT_GUI_FONT
    mov  font, eax

    ; One image list of 16x16 glyphs, shared by both drop-downs. Built before
    ; the controls so each item can name its image.
    INVOKE shell_make_icons
    mov  shell_icons, eax

    ; --- New button: 12,12 64x26, id IDC_NEW --------------------------------
    mov  edx, [esi].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET cls_button, OFFSET text_new, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON, 12, 12, 64, 26, ebx, IDC_NEW, edx, 0
    mov  hCtl, eax
    INVOKE SendMessageW, hCtl, WM_SETFONT, font, 1

    ; --- mode drop-down: 84,12 150x100, id IDC_MODE -------------------------
    mov  edx, [esi].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET cls_combo, 0, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR CBS_DROPDOWNLIST, 84, 12, 150, 100, ebx, IDC_MODE, edx, 0
    mov  hCtl, eax
    INVOKE SendMessageW, hCtl, CBEM_SETIMAGELIST, 0, shell_icons
    INVOKE shell_combo_item, hCtl, OFFSET mode_rect, ICON_RECT
    INVOKE shell_combo_item, hCtl, OFFSET mode_win, ICON_WINDOW
    INVOKE shell_combo_item, hCtl, OFFSET mode_full, ICON_FULL
    INVOKE shell_combo_item, hCtl, OFFSET mode_free, ICON_FREE
    INVOKE SendMessageW, hCtl, CB_SETCURSEL, 0, 0
    INVOKE SendMessageW, hCtl, WM_SETFONT, font, 1

    ; --- Delay drop-down: 242,12 150x100, id IDC_DELAY ----------------------
    mov  edx, [esi].App.hInstance
    INVOKE CreateWindowExW, 0, OFFSET cls_combo, 0, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR CBS_DROPDOWNLIST, 242, 12, 150, 100, ebx, IDC_DELAY, edx, 0
    mov  hCtl, eax
    INVOKE SendMessageW, hCtl, CBEM_SETIMAGELIST, 0, shell_icons
    INVOKE shell_combo_item, hCtl, OFFSET delay_none, ICON_CLOCK
    INVOKE shell_combo_item, hCtl, OFFSET delay_3, ICON_CLOCK
    INVOKE shell_combo_item, hCtl, OFFSET delay_5, ICON_CLOCK
    INVOKE shell_combo_item, hCtl, OFFSET delay_10, ICON_CLOCK
    INVOKE SendMessageW, hCtl, CB_SETCURSEL, 0, 0
    INVOKE SendMessageW, hCtl, WM_SETFONT, font, 1

    xor  eax, eax
    ret
shell_on_create ENDP

; ---------------------------------------------------------------------------
; shell_combo_item(hcombo, pszText, imageIndex) -> eax = new index or CB_ERR.
; Adds one ComboBoxEx row carrying text and an image-list index. The
; COMBOBOXEXITEMW lives on this frame; SendMessageW copies what it needs.
; ---------------------------------------------------------------------------
shell_combo_item PROC hcombo:DWORD, pszText:DWORD, imageIndex:DWORD
    LOCAL item:COMBOBOXEXITEMW

    mov  item.fMask, CBEIF_TEXT OR CBEIF_IMAGE OR CBEIF_SELECTEDIMAGE
    mov  item.iItem, 0FFFFFFFFh           ; append
    mov  eax, pszText
    mov  item.pszText, eax
    mov  item.cchTextMax, 0
    mov  eax, imageIndex
    mov  item.iImage, eax
    mov  item.iSelectedImage, eax
    mov  item.iOverlay, 0
    mov  item.iIndent, 0
    mov  item.lParam, 0

    INVOKE SendMessageW, hcombo, CBEM_INSERTITEMW, 0, ADDR item
    ret
shell_combo_item ENDP

; ---------------------------------------------------------------------------
; shell_make_icons() -> HIMAGELIST in eax, or 0 if it could not be built.
; Creates one 16x16 masked image list and draws the five drop-down glyphs into
; it with GDI - no icon resources, so no .rsrc section. Each glyph is drawn into
; a scratch 32bpp DIB over an ICON_COLORKEY background; smi_publish adds it with
; that colour as the mask. The list is shared by both drop-downs; WM_DESTROY
; destroys it.
; ---------------------------------------------------------------------------
shell_make_icons PROC
    LOCAL himl:DWORD
    LOCAL bits:DWORD
    LOCAL hdcScr:DWORD
    LOCAL hdcMem:DWORD
    LOCAL hdib:DWORD
    LOCAL oldbm:DWORD
    LOCAL hpen:DWORD

    mov  himl, 0
    mov  hdcScr, 0
    mov  hdcMem, 0
    mov  hdib, 0
    mov  oldbm, 0
    mov  hpen, 0

    ; himl = ImageList_Create(16, 16, ILC_COLOR24|ILC_MASK, 8, 1)
    INVOKE ImageList_Create, ICON_SIZE, ICON_SIZE, ILC_COLOR24 OR ILC_MASK, 8, 1
    mov  himl, eax
    test eax, eax
    jz   smi_done

    ; hdcScr = GetDC(NULL); hdcMem = CreateCompatibleDC(hdcScr)
    INVOKE GetDC, 0
    mov  hdcScr, eax
    INVOKE CreateCompatibleDC, hdcScr
    mov  hdcMem, eax

    ; hdib = CreateDIBSection(hdcScr, &smi_bmi, DIB_RGB_COLORS, &bits, 0, 0)
    ; A DIB section, not CreateCompatibleBitmap: pinning 32bpp gives us the bits
    ; pointer, so smi_clear can fill the background in memory rather than GDI.
    INVOKE CreateDIBSection, hdcScr, OFFSET smi_bmi, DIB_RGB_COLORS, ADDR bits, 0, 0
    mov  hdib, eax
    INVOKE SelectObject, hdcMem, hdib
    mov  oldbm, eax

    ; the 1px black pen, selected for the run
    INVOKE CreatePen, PS_SOLID, 1, 0
    mov  hpen, eax
    INVOKE SelectObject, hdcMem, hpen

    ; --- icon 0: Rectangle -------------------------------------------------
    INVOKE smi_clear, bits
    INVOKE smi_hollow, hdcMem
    INVOKE Rectangle, hdcMem, 2, 3, 14, 13
    ; A bitmap may live in only one DC: deselect before smi_publish selects the
    ; DIB into the image list, then reselect it for the next glyph.
    INVOKE SelectObject, hdcMem, oldbm
    INVOKE smi_publish, himl, hdib
    INVOKE SelectObject, hdcMem, hdib

    ; --- icon 1: Window (frame plus filled title bar) ----------------------
    INVOKE smi_clear, bits
    INVOKE smi_hollow, hdcMem
    INVOKE Rectangle, hdcMem, 1, 2, 15, 14
    INVOKE GetStockObject, BLACK_BRUSH
    mov  edx, eax
    INVOKE SelectObject, hdcMem, edx
    INVOKE Rectangle, hdcMem, 1, 2, 15, 5
    INVOKE SelectObject, hdcMem, oldbm
    INVOKE smi_publish, himl, hdib
    INVOKE SelectObject, hdcMem, hdib

    ; --- icon 2: Full screen (four corner brackets) ------------------------
    INVOKE smi_clear, bits
    INVOKE smi_hollow, hdcMem
    INVOKE Polyline, hdcMem, OFFSET pts_tl, 3
    INVOKE Polyline, hdcMem, OFFSET pts_tr, 3
    INVOKE Polyline, hdcMem, OFFSET pts_br, 3
    INVOKE Polyline, hdcMem, OFFSET pts_bl, 3
    INVOKE SelectObject, hdcMem, oldbm
    INVOKE smi_publish, himl, hdib
    INVOKE SelectObject, hdcMem, hdib

    ; --- icon 3: Freeform (a lasso squiggle) -------------------------------
    INVOKE smi_clear, bits
    INVOKE smi_hollow, hdcMem
    INVOKE Polyline, hdcMem, OFFSET pts_free, 7
    INVOKE SelectObject, hdcMem, oldbm
    INVOKE smi_publish, himl, hdib
    INVOKE SelectObject, hdcMem, hdib

    ; --- icon 4: Clock (dial plus two hands) -------------------------------
    INVOKE smi_clear, bits
    INVOKE smi_hollow, hdcMem
    INVOKE Ellipse, hdcMem, 2, 2, 14, 14
    INVOKE Polyline, hdcMem, OFFSET pts_hand_v, 2
    INVOKE Polyline, hdcMem, OFFSET pts_hand_h, 2
    INVOKE SelectObject, hdcMem, oldbm
    INVOKE smi_publish, himl, hdib
    INVOKE SelectObject, hdcMem, hdib

smi_done:
    ; restore the old bitmap, then free the DC before the still-selected pen
    cmp  oldbm, 0
    jz   smi_free_bmp
    INVOKE SelectObject, hdcMem, oldbm
smi_free_bmp:
    cmp  hdib, 0
    jz   smi_free_dc
    INVOKE DeleteObject, hdib
smi_free_dc:
    cmp  hdcMem, 0
    jz   smi_free_screen
    INVOKE DeleteDC, hdcMem
smi_free_screen:
    cmp  hdcScr, 0
    jz   smi_free_pen
    INVOKE ReleaseDC, 0, hdcScr
smi_free_pen:
    cmp  hpen, 0
    jz   smi_return
    INVOKE DeleteObject, hpen
smi_return:
    mov  eax, himl
    ret
shell_make_icons ENDP

; ---------------------------------------------------------------------------
; smi_clear(bits) - fill the 16x16 DIB with ICON_COLORKEY. Done in memory, not
; with a GDI brush: a selected-brush PatBlt left the DIB black. Leaf.
; ---------------------------------------------------------------------------
smi_clear PROC USES edi bits:DWORD
    mov  edi, bits
    mov  ecx, ICON_SIZE * ICON_SIZE
    mov  eax, ICON_COLORKEY
    rep  stosd
    ret
smi_clear ENDP

; ---------------------------------------------------------------------------
; smi_hollow(hdc) - select the stock hollow brush, so shapes are outlines.
; ---------------------------------------------------------------------------
smi_hollow PROC USES ebx hdc:DWORD
    mov  ebx, hdc
    INVOKE GetStockObject, NULL_BRUSH
    mov  edx, eax
    INVOKE SelectObject, ebx, edx
    ret
smi_hollow ENDP

; ---------------------------------------------------------------------------
; smi_publish(himl, hbm) - add the drawn glyph to the list, keying
; ICON_COLORKEY out of the background.
; ---------------------------------------------------------------------------
smi_publish PROC himl:DWORD, hbm:DWORD
    INVOKE ImageList_AddMasked, himl, hbm, ICON_COLORKEY
    ret
smi_publish ENDP

END
