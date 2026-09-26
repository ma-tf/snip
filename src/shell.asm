; shell.asm
; The Shell window: the app's main window and the one place a snip starts.
;
; A New button and two ComboBoxEx drop-downs (mode and Delay), each row carrying
; a 16x16 icon drawn at runtime with GDI into a shared image list - no icon
; resources, so no .rsrc section and no resource compiler. Either drop-down
; records its choice in App; New does nothing yet. Starting a session is ticket
; 02. See docs/shell.md.

option casemap:none

include snip.inc
include win32.inc

PUBLIC shell_create

; ---------------------------------------------------------------------------
; Statics. Module-private: the Shell is a singleton, so its window class can
; live here rather than in App.
;
; Strings are read-only, so they live in .const (.rdata); shell_wc is
; zero-initialised and lives in .data? (.bss). Neither costs file bytes, which
; is what keeps the image small. See docs/architecture.md.
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
shell_icons   QWORD ?            ; HIMAGELIST, ours to destroy. Module-private
                                 ; because the Shell is a singleton.

SHELL_STYLE   EQU WS_CAPTION OR WS_SYSMENU OR WS_MINIMIZEBOX

; ---------------------------------------------------------------------------
.code

; ---------------------------------------------------------------------------
; shell_create(app) -> HWND in rax, or 0 if the window could not be made.
; Registers the Shell class, creates the window, and shows it. The controls are
; built in WM_CREATE, where the app pointer arrives as lpCreateParams.
; ---------------------------------------------------------------------------
shell_create PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    sub  rsp, 68h            ; 0x20 shadow + 0x60 stack args, aligned
    .allocstack 68h
    .endprolog

    mov  rbx, rcx            ; app

    mov  shell_wc.cbSize, SIZEOF WNDCLASSEXW
    mov  shell_wc.style, CS_HREDRAW OR CS_VREDRAW
    lea  rax, shell_wndproc
    mov  shell_wc.lpfnWndProc, rax
    mov  shell_wc.cbClsExtra, 0
    mov  shell_wc.cbWndExtra, 0
    mov  rax, [rbx].App.hInstance
    mov  shell_wc.hInstance, rax
    mov  shell_wc.hbrBackground, COLOR_WINDOW_1

    xor  ecx, ecx
    mov  edx, IDC_ARROW
    call LoadCursorW
    mov  shell_wc.hCursor, rax

    lea  rax, shell_class
    mov  shell_wc.lpszClassName, rax

    lea  rcx, shell_wc
    call RegisterClassExW
    test eax, eax
    jnz  shell_registered
    xor  eax, eax
    jmp  shell_create_done

shell_registered:
    ; CreateWindowExW(0, class, title, style, CW_USEDEFAULT, CW_USEDEFAULT,
    ;                 420, 140, NULL, NULL, hinst, app)
    mov  qword ptr [rsp+20h], CW_USEDEFAULT
    mov  qword ptr [rsp+28h], CW_USEDEFAULT
    mov  qword ptr [rsp+30h], 420
    mov  qword ptr [rsp+38h], 140
    mov  qword ptr [rsp+40h], 0
    mov  qword ptr [rsp+48h], 0
    mov  rax, [rbx].App.hInstance
    mov  qword ptr [rsp+50h], rax
    mov  qword ptr [rsp+58h], rbx           ; lpParam = app
    xor  ecx, ecx
    lea  rdx, shell_class
    lea  r8, shell_title
    mov  r9d, SHELL_STYLE
    call CreateWindowExW
    mov  rsi, rax
    test rax, rax
    jz   shell_create_done

    mov  rcx, rsi
    mov  edx, SW_SHOWDEFAULT
    call ShowWindow
    mov  rcx, rsi
    call UpdateWindow
    mov  rax, rsi

shell_create_done:
    add  rsp, 68h
    pop  rsi
    pop  rbx
    ret
shell_create ENDP

; ---------------------------------------------------------------------------
; shell_wndproc(hwnd, msg, wParam, lParam)
; ---------------------------------------------------------------------------
shell_wndproc PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    sub  rsp, 28h
    .allocstack 28h
    .endprolog

    mov  rbx, rcx            ; hwnd
    mov  r12d, edx           ; msg
    mov  rsi, r8             ; wParam
    mov  rdi, r9             ; lParam

    cmp  r12d, WM_CREATE
    je   wm_create
    cmp  r12d, WM_COMMAND
    je   wm_command
    cmp  r12d, WM_DESTROY
    je   wm_destroy

wnd_default:
    mov  rcx, rbx
    mov  edx, r12d
    mov  r8, rsi
    mov  r9, rdi
    call DefWindowProcW
    jmp  wnd_done

wm_create:
    ; app = ((CREATESTRUCTW *)lParam)->lpCreateParams, the struct's first field
    mov  rax, [rdi]
    mov  rcx, rbx
    mov  edx, GWLP_USERDATA
    mov  r8, rax
    call SetWindowLongPtrW
    mov  rcx, rbx
    mov  rdx, [rdi]
    call shell_on_create
    xor  eax, eax
    jmp  wnd_done

wm_command:
    ; wParam holds the control id (low word) and the notification (high word);
    ; for a combo notification, lParam is the control's HWND.
    mov  eax, esi
    and  eax, 0FFFFh
    mov  edx, esi
    shr  edx, 16
    and  edx, 0FFFFh
    cmp  edx, CBN_SELCHANGE
    jne  wnd_default
    cmp  eax, IDC_MODE
    je   wm_combo
    cmp  eax, IDC_DELAY
    jne  wnd_default

wm_combo:
    mov  r12d, eax           ; which drop-down
    mov  rcx, rbx
    mov  edx, GWLP_USERDATA
    call GetWindowLongPtrW
    mov  rsi, rax            ; app
    mov  rcx, rdi            ; the combo that changed
    mov  edx, CB_GETCURSEL
    xor  r8d, r8d
    xor  r9d, r9d
    call SendMessageW
    cmp  r12d, IDC_MODE
    jne  wm_combo_delay
    mov  [rsi].App.mode, eax
    jmp  wnd_done
wm_combo_delay:
    mov  [rsi].App.delay, eax
    jmp  wnd_done

wm_destroy:
    ; The image list is ours, not the controls': destroy it before we quit.
    mov  rcx, shell_icons
    test rcx, rcx
    jz   wm_destroy_quit
    call ImageList_Destroy
    mov  shell_icons, 0
wm_destroy_quit:
    xor  ecx, ecx
    call PostQuitMessage
    xor  eax, eax

wnd_done:
    add  rsp, 28h
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    ret
shell_wndproc ENDP

; ---------------------------------------------------------------------------
; shell_on_create(hwnd, app) -> eax 0.
; Builds the three controls and sets the stock font on each.
; ---------------------------------------------------------------------------
shell_on_create PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    sub  rsp, 68h
    .allocstack 68h
    .endprolog

    mov  rbx, rcx            ; hwnd
    mov  rsi, rdx            ; app

    mov  ecx, DEFAULT_GUI_FONT
    call GetStockObject
    mov  rdi, rax            ; font

    ; One image list of 16x16 glyphs, shared by both drop-downs. Built before
    ; the controls so each item can name its image.
    call shell_make_icons
    mov  shell_icons, rax

    ; --- New button: 12,12 64x26, id IDC_NEW --------------------------------
    mov  qword ptr [rsp+20h], 12
    mov  qword ptr [rsp+28h], 12
    mov  qword ptr [rsp+30h], 64
    mov  qword ptr [rsp+38h], 26
    mov  qword ptr [rsp+40h], rbx
    mov  qword ptr [rsp+48h], IDC_NEW
    mov  rax, [rsi].App.hInstance
    mov  qword ptr [rsp+50h], rax
    mov  qword ptr [rsp+58h], 0
    xor  ecx, ecx
    lea  rdx, cls_button
    lea  r8, text_new
    mov  r9d, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR BS_PUSHBUTTON
    call CreateWindowExW
    mov  rcx, rax
    mov  edx, WM_SETFONT
    mov  r8, rdi
    mov  r9d, 1
    call SendMessageW

    ; --- mode drop-down: 84,12 150x100, id IDC_MODE -------------------------
    mov  qword ptr [rsp+20h], 84
    mov  qword ptr [rsp+28h], 12
    mov  qword ptr [rsp+30h], 150
    mov  qword ptr [rsp+38h], 100
    mov  qword ptr [rsp+40h], rbx
    mov  qword ptr [rsp+48h], IDC_MODE
    mov  rax, [rsi].App.hInstance
    mov  qword ptr [rsp+50h], rax
    mov  qword ptr [rsp+58h], 0
    xor  ecx, ecx
    lea  rdx, cls_combo
    xor  r8d, r8d
    mov  r9d, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR CBS_DROPDOWNLIST
    call CreateWindowExW
    mov  r12, rax

    mov  rcx, r12
    mov  edx, CBEM_SETIMAGELIST
    xor  r8d, r8d
    mov  r9, shell_icons
    call SendMessageW

    mov  rcx, r12
    lea  rdx, mode_rect
    mov  r8d, ICON_RECT
    call shell_combo_item
    mov  rcx, r12
    lea  rdx, mode_win
    mov  r8d, ICON_WINDOW
    call shell_combo_item
    mov  rcx, r12
    lea  rdx, mode_full
    mov  r8d, ICON_FULL
    call shell_combo_item
    mov  rcx, r12
    lea  rdx, mode_free
    mov  r8d, ICON_FREE
    call shell_combo_item

    mov  rcx, r12
    mov  edx, CB_SETCURSEL
    xor  r8d, r8d
    xor  r9d, r9d
    call SendMessageW
    mov  rcx, r12
    mov  edx, WM_SETFONT
    mov  r8, rdi
    mov  r9d, 1
    call SendMessageW

    ; --- Delay drop-down: 242,12 150x100, id IDC_DELAY ----------------------
    mov  qword ptr [rsp+20h], 242
    mov  qword ptr [rsp+28h], 12
    mov  qword ptr [rsp+30h], 150
    mov  qword ptr [rsp+38h], 100
    mov  qword ptr [rsp+40h], rbx
    mov  qword ptr [rsp+48h], IDC_DELAY
    mov  rax, [rsi].App.hInstance
    mov  qword ptr [rsp+50h], rax
    mov  qword ptr [rsp+58h], 0
    xor  ecx, ecx
    lea  rdx, cls_combo
    xor  r8d, r8d
    mov  r9d, WS_CHILD OR WS_VISIBLE OR WS_TABSTOP OR CBS_DROPDOWNLIST
    call CreateWindowExW
    mov  r12, rax

    mov  rcx, r12
    mov  edx, CBEM_SETIMAGELIST
    xor  r8d, r8d
    mov  r9, shell_icons
    call SendMessageW

    mov  rcx, r12
    lea  rdx, delay_none
    mov  r8d, ICON_CLOCK
    call shell_combo_item
    mov  rcx, r12
    lea  rdx, delay_3
    mov  r8d, ICON_CLOCK
    call shell_combo_item
    mov  rcx, r12
    lea  rdx, delay_5
    mov  r8d, ICON_CLOCK
    call shell_combo_item
    mov  rcx, r12
    lea  rdx, delay_10
    mov  r8d, ICON_CLOCK
    call shell_combo_item

    mov  rcx, r12
    mov  edx, CB_SETCURSEL
    xor  r8d, r8d
    xor  r9d, r9d
    call SendMessageW
    mov  rcx, r12
    mov  edx, WM_SETFONT
    mov  r8, rdi
    mov  r9d, 1
    call SendMessageW

    xor  eax, eax
    add  rsp, 68h
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    ret
shell_on_create ENDP

; ---------------------------------------------------------------------------
; shell_combo_item(hcombo, pszText, imageIndex) -> eax = new index or CB_ERR.
; Adds one ComboBoxEx row carrying text and an image-list index. The
; COMBOBOXEXITEMW lives on this frame; SendMessageW copies what it needs.
; ---------------------------------------------------------------------------
shell_combo_item PROC FRAME
    push rbx
    .pushreg rbx
    sub  rsp, 60h            ; 0x20 shadow + 0x38 struct, aligned
    .allocstack 60h
    .endprolog

    mov  rbx, rcx            ; combo

    mov  dword ptr [rsp+20h], CBEIF_TEXT OR CBEIF_IMAGE OR CBEIF_SELECTEDIMAGE
    mov  dword ptr [rsp+24h], 0
    mov  qword ptr [rsp+28h], -1          ; iItem: append
    mov  qword ptr [rsp+30h], rdx         ; pszText
    mov  dword ptr [rsp+38h], 0           ; cchTextMax
    mov  dword ptr [rsp+3Ch], r8d         ; iImage
    mov  dword ptr [rsp+40h], r8d         ; iSelectedImage
    mov  dword ptr [rsp+44h], 0           ; iOverlay
    mov  dword ptr [rsp+48h], 0           ; iIndent
    mov  dword ptr [rsp+4Ch], 0
    mov  qword ptr [rsp+50h], 0           ; lParam

    mov  rcx, rbx
    mov  edx, CBEM_INSERTITEMW
    xor  r8d, r8d
    lea  r9, [rsp+20h]
    call SendMessageW

    add  rsp, 60h
    pop  rbx
    ret
shell_combo_item ENDP

; ---------------------------------------------------------------------------
; shell_make_icons() -> HIMAGELIST in rax, or 0 if it could not be built.
; Creates one 16x16 masked image list and draws the five drop-down glyphs into
; it with GDI - no icon resources, so no .rsrc section. Each glyph is drawn into
; a scratch 32bpp DIB over an ICON_COLORKEY background; smi_publish adds it with
; that colour as the mask. The list is shared by both drop-downs; WM_DESTROY
; destroys it.
; ---------------------------------------------------------------------------
shell_make_icons PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    push r13
    .pushreg r13
    push r14
    .pushreg r14
    push r15
    .pushreg r15
    sub  rsp, 40h            ; 0x20 shadow + Rectangle/Ellipse stack args
    .allocstack 40h
    .endprolog

    mov  rbx, 0              ; himl (result)
    mov  rsi, 0              ; DIB bits
    mov  r12, 0              ; screen DC
    mov  r13, 0              ; memory DC
    mov  r14, 0              ; DIB
    mov  r15, 0              ; old bitmap
    mov  rdi, 0              ; black pen

    ; himl = ImageList_Create(16, 16, ILC_COLOR24|ILC_MASK, 8, 1)
    mov  ecx, ICON_SIZE
    mov  edx, ICON_SIZE
    mov  r8d, ILC_COLOR24 OR ILC_MASK
    mov  r9d, 8
    mov  qword ptr [rsp+20h], 1
    call ImageList_Create
    mov  rbx, rax
    test rax, rax
    jz   smi_done

    ; hdcScreen = GetDC(NULL); hdcMem = CreateCompatibleDC(hdcScreen)
    xor  ecx, ecx
    call GetDC
    mov  r12, rax
    mov  rcx, r12
    call CreateCompatibleDC
    mov  r13, rax

    ; hbm = CreateDIBSection(hdcScreen, &smi_bmi, DIB_RGB_COLORS, &bits, 0, 0)
    ; A DIB section, not CreateCompatibleBitmap: pinning 32bpp gives us the bits
    ; pointer, so smi_clear can fill the background in memory rather than GDI.
    mov  rcx, r12
    lea  rdx, smi_bmi
    mov  r8d, DIB_RGB_COLORS
    lea  r9, [rsp+30h]
    mov  qword ptr [rsp+20h], 0
    mov  qword ptr [rsp+28h], 0
    call CreateDIBSection
    mov  r14, rax
    mov  rsi, qword ptr [rsp+30h]
    mov  rcx, r13
    mov  rdx, r14
    call SelectObject
    mov  r15, rax

    ; the 1px black pen, selected for the run
    mov  ecx, PS_SOLID
    mov  edx, 1
    xor  r8d, r8d
    call CreatePen
    mov  rdi, rax
    mov  rcx, r13
    mov  rdx, rdi
    call SelectObject

    ; --- icon 0: Rectangle -------------------------------------------------
    mov  rcx, rsi
    call smi_clear
    mov  rcx, r13
    call smi_hollow
    mov  rcx, r13
    mov  edx, 2
    mov  r8d, 3
    mov  r9d, 14
    mov  qword ptr [rsp+20h], 13
    call Rectangle
    ; A bitmap may live in only one DC: deselect before smi_publish selects the
    ; DIB into the image list, then reselect it for the next glyph.
    mov  rcx, r13
    mov  rdx, r15
    call SelectObject
    mov  rcx, rbx
    mov  rdx, r14
    call smi_publish
    mov  rcx, r13
    mov  rdx, r14
    call SelectObject

    ; --- icon 1: Window (frame plus filled title bar) ----------------------
    mov  rcx, rsi
    call smi_clear
    mov  rcx, r13
    call smi_hollow
    mov  rcx, r13
    mov  edx, 1
    mov  r8d, 2
    mov  r9d, 15
    mov  qword ptr [rsp+20h], 14
    call Rectangle
    mov  ecx, BLACK_BRUSH
    call GetStockObject
    mov  rcx, r13
    mov  rdx, rax
    call SelectObject
    mov  rcx, r13
    mov  edx, 1
    mov  r8d, 2
    mov  r9d, 15
    mov  qword ptr [rsp+20h], 5
    call Rectangle
    ; A bitmap may live in only one DC: deselect before smi_publish selects the
    ; DIB into the image list, then reselect it for the next glyph.
    mov  rcx, r13
    mov  rdx, r15
    call SelectObject
    mov  rcx, rbx
    mov  rdx, r14
    call smi_publish
    mov  rcx, r13
    mov  rdx, r14
    call SelectObject

    ; --- icon 2: Full screen (four corner brackets) ------------------------
    mov  rcx, rsi
    call smi_clear
    mov  rcx, r13
    call smi_hollow
    mov  rcx, r13
    lea  rdx, pts_tl
    mov  r8d, 3
    call Polyline
    mov  rcx, r13
    lea  rdx, pts_tr
    mov  r8d, 3
    call Polyline
    mov  rcx, r13
    lea  rdx, pts_br
    mov  r8d, 3
    call Polyline
    mov  rcx, r13
    lea  rdx, pts_bl
    mov  r8d, 3
    call Polyline
    ; A bitmap may live in only one DC: deselect before smi_publish selects the
    ; DIB into the image list, then reselect it for the next glyph.
    mov  rcx, r13
    mov  rdx, r15
    call SelectObject
    mov  rcx, rbx
    mov  rdx, r14
    call smi_publish
    mov  rcx, r13
    mov  rdx, r14
    call SelectObject

    ; --- icon 3: Freeform (a lasso squiggle) -------------------------------
    mov  rcx, rsi
    call smi_clear
    mov  rcx, r13
    call smi_hollow
    mov  rcx, r13
    lea  rdx, pts_free
    mov  r8d, 7
    call Polyline
    ; A bitmap may live in only one DC: deselect before smi_publish selects the
    ; DIB into the image list, then reselect it for the next glyph.
    mov  rcx, r13
    mov  rdx, r15
    call SelectObject
    mov  rcx, rbx
    mov  rdx, r14
    call smi_publish
    mov  rcx, r13
    mov  rdx, r14
    call SelectObject

    ; --- icon 4: Clock (dial plus two hands) -------------------------------
    mov  rcx, rsi
    call smi_clear
    mov  rcx, r13
    call smi_hollow
    mov  rcx, r13
    mov  edx, 2
    mov  r8d, 2
    mov  r9d, 14
    mov  qword ptr [rsp+20h], 14
    call Ellipse
    mov  rcx, r13
    lea  rdx, pts_hand_v
    mov  r8d, 2
    call Polyline
    mov  rcx, r13
    lea  rdx, pts_hand_h
    mov  r8d, 2
    call Polyline
    ; A bitmap may live in only one DC: deselect before smi_publish selects the
    ; DIB into the image list, then reselect it for the next glyph.
    mov  rcx, r13
    mov  rdx, r15
    call SelectObject
    mov  rcx, rbx
    mov  rdx, r14
    call smi_publish
    mov  rcx, r13
    mov  rdx, r14
    call SelectObject

smi_done:
    ; restore the old bitmap, then free the DC before the still-selected pen
    test r15, r15
    jz   smi_free_bmp
    mov  rcx, r13
    mov  rdx, r15
    call SelectObject
smi_free_bmp:
    test r14, r14
    jz   smi_free_dc
    mov  rcx, r14
    call DeleteObject
smi_free_dc:
    test r13, r13
    jz   smi_free_screen
    mov  rcx, r13
    call DeleteDC
smi_free_screen:
    test r12, r12
    jz   smi_free_pen
    xor  ecx, ecx
    mov  rdx, r12
    call ReleaseDC
smi_free_pen:
    test rdi, rdi
    jz   smi_return
    mov  rcx, rdi
    call DeleteObject
smi_return:
    mov  rax, rbx
    add  rsp, 40h
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    ret
shell_make_icons ENDP

; ---------------------------------------------------------------------------
; smi_clear(bits) - fill the 16x16 DIB with ICON_COLORKEY. Done in memory, not
; with a GDI brush: a selected-brush PatBlt left the DIB black. Leaf.
; ---------------------------------------------------------------------------
smi_clear PROC
    push rdi
    mov  rdi, rcx
    mov  ecx, ICON_SIZE * ICON_SIZE
    mov  eax, ICON_COLORKEY
    rep stosd
    pop  rdi
    ret
smi_clear ENDP

; ---------------------------------------------------------------------------
; smi_hollow(hdc) - select the stock hollow brush, so shapes are outlines.
; ---------------------------------------------------------------------------
smi_hollow PROC FRAME
    push rbx
    .pushreg rbx
    sub  rsp, 20h
    .allocstack 20h
    .endprolog
    mov  rbx, rcx
    mov  ecx, NULL_BRUSH
    call GetStockObject
    mov  rcx, rbx
    mov  rdx, rax
    call SelectObject
    add  rsp, 20h
    pop  rbx
    ret
smi_hollow ENDP

; ---------------------------------------------------------------------------
; smi_publish(himl, hbm) - add the drawn glyph to the list, keying
; ICON_COLORKEY out of the background.
; ---------------------------------------------------------------------------
smi_publish PROC FRAME
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    sub  rsp, 28h
    .allocstack 28h
    .endprolog
    mov  rbx, rcx
    mov  rsi, rdx
    mov  rcx, rbx
    mov  rdx, rsi
    mov  r8d, ICON_COLORKEY
    call ImageList_AddMasked
    add  rsp, 28h
    pop  rsi
    pop  rbx
    ret
smi_publish ENDP

END
