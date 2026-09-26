; win32.inc - platform binding: Win32 imports, SDK constants, and struct layouts.
;
; This is the mechanical layer between our code and the OS. It holds exactly one
; declaration of each Win32 function we import and each SDK structure we use, so
; no two modules can disagree about a signature or a layout.
;
; It is deliberately NOT our module interface - that is snip.inc. Keep project
; types, project constants, and project IDs out of this file. Add a declaration
; only when a module calls it; unused imports are still a cost.

IFNDEF WIN32_INC
WIN32_INC EQU 1

; ---------------------------------------------------------------------------
; kernel32
; ---------------------------------------------------------------------------
EXTERN GetModuleHandleW:PROC
EXTERN ExitProcess:PROC

; ---------------------------------------------------------------------------
; user32
; ---------------------------------------------------------------------------
EXTERN SetProcessDpiAwarenessContext:PROC
EXTERN LoadCursorW:PROC
EXTERN RegisterClassExW:PROC
EXTERN CreateWindowExW:PROC
EXTERN ShowWindow:PROC
EXTERN UpdateWindow:PROC
EXTERN GetMessageW:PROC
EXTERN TranslateMessage:PROC
EXTERN DispatchMessageW:PROC
EXTERN DefWindowProcW:PROC
EXTERN PostQuitMessage:PROC
EXTERN GetWindowLongPtrW:PROC
EXTERN SetWindowLongPtrW:PROC
EXTERN SendMessageW:PROC
EXTERN GetDC:PROC
EXTERN ReleaseDC:PROC

; ---------------------------------------------------------------------------
; gdi32
; ---------------------------------------------------------------------------
EXTERN GetStockObject:PROC
EXTERN CreateCompatibleDC:PROC
EXTERN CreateDIBSection:PROC
EXTERN CreatePen:PROC
EXTERN SelectObject:PROC
EXTERN DeleteObject:PROC
EXTERN DeleteDC:PROC
EXTERN Rectangle:PROC
EXTERN Ellipse:PROC
EXTERN Polyline:PROC

; ---------------------------------------------------------------------------
; comctl32 - ComboBoxEx and its image list. Registered at process init.
; ---------------------------------------------------------------------------
EXTERN InitCommonControlsEx:PROC
EXTERN ImageList_Create:PROC
EXTERN ImageList_AddMasked:PROC
EXTERN ImageList_Destroy:PROC

; ---------------------------------------------------------------------------
; Window styles and messages (numeric values from the SDK headers)
; ---------------------------------------------------------------------------
WS_CAPTION          EQU 00C00000h
WS_SYSMENU          EQU 00080000h
WS_MINIMIZEBOX      EQU 00020000h
WS_CHILD            EQU 40000000h
WS_VISIBLE          EQU 10000000h
WS_TABSTOP          EQU 00010000h

BS_PUSHBUTTON       EQU 0
CBS_DROPDOWNLIST    EQU 3

CW_USEDEFAULT       EQU 80000000h
SW_SHOWDEFAULT      EQU 10
CS_HREDRAW          EQU 0002h
CS_VREDRAW          EQU 0001h
IDC_ARROW           EQU 7F00h          ; 32512, an HCURSOR ordinal
COLOR_WINDOW_1      EQU 6              ; (COLOR_WINDOW + 1), a valid pseudo-HBRUSH
DEFAULT_GUI_FONT    EQU 17

WM_CREATE           EQU 0001h
WM_DESTROY          EQU 0002h
WM_COMMAND          EQU 0111h
WM_SETFONT          EQU 0030h

CBN_SELCHANGE       EQU 1

CB_GETCURSEL        EQU 0147h
CB_SETCURSEL        EQU 014Eh

; ComboBoxEx (comctl32). CBEM_* are WM_USER-relative; ICC registers the class.
WM_USER             EQU 0400h
ICC_USEREX_CLASSES  EQU 0200h
CBEM_SETIMAGELIST   EQU WM_USER + 2

; CBEM_INSERTITEMW is the wide variant (WM_USER + 11).
CBEM_INSERTITEMW    EQU WM_USER + 11
CBEIF_TEXT          EQU 00000001h
CBEIF_IMAGE         EQU 00000002h
CBEIF_SELECTEDIMAGE EQU 00000004h

; Image list: 24-bit colour with a mask. ComboBoxEx draws the list opaquely, so
; a 32-bit list's alpha is ignored; the colour-key mask is what makes the glyph
; background transparent. See shell.asm.
ILC_COLOR24         EQU 18h
ILC_MASK            EQU 00000001h

; GDI drawing
PS_SOLID            EQU 0
BLACK_BRUSH         EQU 4              ; GetStockObject ordinal
NULL_BRUSH          EQU 5              ; GetStockObject ordinal (hollow)
BI_RGB              EQU 0
DIB_RGB_COLORS      EQU 0

GWLP_USERDATA       EQU -21

DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 EQU -4

; ---------------------------------------------------------------------------
; Structures (exact x64 layouts from the SDK headers)
; ---------------------------------------------------------------------------
WNDCLASSEXW STRUCT 8
    cbSize          DWORD   ?
    style           DWORD   ?
    lpfnWndProc     QWORD   ?
    cbClsExtra      DWORD   ?
    cbWndExtra      DWORD   ?
    hInstance       QWORD   ?
    hIcon           QWORD   ?
    hCursor         QWORD   ?
    hbrBackground   QWORD   ?
    lpszMenuName    QWORD   ?
    lpszClassName   QWORD   ?
    hIconSm         QWORD   ?
WNDCLASSEXW ENDS                       ; sizeof == 80

MSG STRUCT 8
    hwnd     QWORD ?
    message  DWORD ?
    _pad0    DWORD ?
    wParam   QWORD ?
    lParam   QWORD ?
    time     DWORD ?
    ptX      DWORD ?
    ptY      DWORD ?
    lPrivate DWORD ?
MSG ENDS                               ; sizeof == 48

POINT STRUCT 4
    x        SDWORD ?
    y        SDWORD ?
POINT ENDS                             ; sizeof == 8

BITMAPINFOHEADER STRUCT 4
    biSize          DWORD ?
    biWidth         SDWORD ?
    biHeight        SDWORD ?
    biPlanes        WORD ?
    biBitCount      WORD ?
    biCompression   DWORD ?
    biSizeImage     DWORD ?
    biXPelsPerMeter SDWORD ?
    biYPelsPerMeter SDWORD ?
    biClrUsed       DWORD ?
    biClrImportant  DWORD ?
BITMAPINFOHEADER ENDS                  ; sizeof == 40

INITCOMMONCONTROLSEX STRUCT 8
    dwSize   DWORD ?
    dwICC    DWORD ?
INITCOMMONCONTROLSEX ENDS              ; sizeof == 8

; x64 layout: iItem (INT_PTR) forces 8-byte alignment, so fMask is followed by
; four padding bytes and lParam lands on an 8-byte boundary at offset 48.
; (The field is fMask, not mask: MASK is a MASM operator.)
COMBOBOXEXITEMW STRUCT 8
    fMask           DWORD ?
    _pad0           DWORD ?
    iItem           QWORD ?
    pszText         QWORD ?
    cchTextMax      DWORD ?
    iImage          DWORD ?
    iSelectedImage  DWORD ?
    iOverlay        DWORD ?
    iIndent         DWORD ?
    _pad1           DWORD ?
    lParam          QWORD ?
COMBOBOXEXITEMW ENDS                   ; sizeof == 56

ENDIF
