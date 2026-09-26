; win32.inc - platform binding: Win32 imports, SDK constants, and struct layouts.
;
; This is the mechanical layer between our code and the OS. It holds exactly one
; declaration of each Win32 function we import and each SDK structure we use, so
; no two modules can disagree about a signature or a layout.
;
; It is deliberately NOT our module interface - that is snip.inc. Keep project
; types, project constants, and project IDs out of this file. Add a declaration
; only when a module calls it; unused imports are still a cost.
;
; Target is 32-bit x86 under WOW64 on Windows 11. Functions are stdcall and the
; prototypes carry parameter types so MASM's INVOKE can push arguments. Note the
; x86 SDK does not export the ...LongPtrW forms; the 32-bit build calls the plain
; Get/SetWindowLongW. See docs/adr/0002-x86-for-crinkler.md.

IFNDEF WIN32_INC
WIN32_INC EQU 1

; ---------------------------------------------------------------------------
; kernel32
; ---------------------------------------------------------------------------
GetModuleHandleW PROTO STDCALL :DWORD
ExitProcess      PROTO STDCALL :DWORD

; ---------------------------------------------------------------------------
; user32
; ---------------------------------------------------------------------------
SetProcessDpiAwarenessContext PROTO STDCALL :DWORD
LoadCursorW                   PROTO STDCALL :DWORD, :DWORD
RegisterClassExW              PROTO STDCALL :DWORD
CreateWindowExW               PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :SDWORD, :SDWORD, :SDWORD, :SDWORD, :DWORD, :DWORD, :DWORD, :DWORD
ShowWindow                    PROTO STDCALL :DWORD, :SDWORD
UpdateWindow                  PROTO STDCALL :DWORD
GetMessageW                   PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD
TranslateMessage              PROTO STDCALL :DWORD
DispatchMessageW              PROTO STDCALL :DWORD
DefWindowProcW                PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD
PostQuitMessage               PROTO STDCALL :SDWORD
GetWindowLongW                PROTO STDCALL :DWORD, :SDWORD
SetWindowLongW                PROTO STDCALL :DWORD, :SDWORD, :SDWORD
SendMessageW                  PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD
GetDC                         PROTO STDCALL :DWORD
ReleaseDC                     PROTO STDCALL :DWORD, :DWORD

; ---------------------------------------------------------------------------
; gdi32
; ---------------------------------------------------------------------------
GetStockObject     PROTO STDCALL :SDWORD
CreateCompatibleDC PROTO STDCALL :DWORD
CreateDIBSection   PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
CreatePen          PROTO STDCALL :SDWORD, :SDWORD, :DWORD
SelectObject       PROTO STDCALL :DWORD, :DWORD
DeleteObject       PROTO STDCALL :DWORD
DeleteDC           PROTO STDCALL :DWORD
Rectangle          PROTO STDCALL :DWORD, :SDWORD, :SDWORD, :SDWORD, :SDWORD
Ellipse            PROTO STDCALL :DWORD, :SDWORD, :SDWORD, :SDWORD, :SDWORD
Polyline           PROTO STDCALL :DWORD, :DWORD, :SDWORD

; ---------------------------------------------------------------------------
; comctl32 - ComboBoxEx and its image list. Registered at process init.
; ---------------------------------------------------------------------------
InitCommonControlsEx PROTO STDCALL :DWORD
ImageList_Create     PROTO STDCALL :SDWORD, :SDWORD, :DWORD, :SDWORD, :SDWORD
ImageList_AddMasked  PROTO STDCALL :DWORD, :DWORD, :DWORD
ImageList_Destroy    PROTO STDCALL :DWORD

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
; Structures (exact x86 layouts from the SDK headers)
; ---------------------------------------------------------------------------
WNDCLASSEXW STRUCT
    cbSize          DWORD   ?
    style           DWORD   ?
    lpfnWndProc     DWORD   ?
    cbClsExtra      DWORD   ?
    cbWndExtra      DWORD   ?
    hInstance       DWORD   ?
    hIcon           DWORD   ?
    hCursor         DWORD   ?
    hbrBackground   DWORD   ?
    lpszMenuName    DWORD   ?
    lpszClassName   DWORD   ?
    hIconSm         DWORD   ?
WNDCLASSEXW ENDS                        ; sizeof == 48

POINT STRUCT
    x        SDWORD ?
    y        SDWORD ?
POINT ENDS                             ; sizeof == 8

MSG STRUCT
    hwnd     DWORD ?
    message  DWORD ?
    wParam   DWORD ?
    lParam   DWORD ?
    time     DWORD ?
    pt       POINT <>
    lPrivate DWORD ?
MSG ENDS                               ; sizeof == 32

BITMAPINFOHEADER STRUCT
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

INITCOMMONCONTROLSEX STRUCT
    dwSize   DWORD ?
    dwICC    DWORD ?
INITCOMMONCONTROLSEX ENDS              ; sizeof == 8

; x86 layout: every field is pointer- or INT-sized (4 bytes), so there is no
; padding and sizeof == 36. On x64 iItem (INT_PTR) forced 8-byte alignment and
; sizeof was 56. (The field is fMask, not mask: MASK is a MASM operator.)
COMBOBOXEXITEMW STRUCT
    fMask           DWORD ?
    iItem           DWORD ?
    pszText         DWORD ?
    cchTextMax      DWORD ?
    iImage          DWORD ?
    iSelectedImage  DWORD ?
    iOverlay        DWORD ?
    iIndent         DWORD ?
    lParam          DWORD ?
COMBOBOXEXITEMW ENDS                   ; sizeof == 36

ENDIF
