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
MulDiv           PROTO STDCALL :SDWORD, :SDWORD, :SDWORD   ; rounded scale, for DPI chrome
LoadLibraryA     PROTO STDCALL :DWORD                      ; resolve the COM entry points
GetProcAddress   PROTO STDCALL :DWORD, :DWORD
GlobalAlloc      PROTO STDCALL :DWORD, :DWORD              ; clipboard HGLOBALs
GlobalLock       PROTO STDCALL :DWORD
GlobalUnlock     PROTO STDCALL :DWORD
GlobalFree       PROTO STDCALL :DWORD

; ticket 10: the Delay setting waits on the UI thread before the Overlay.
Sleep            PROTO STDCALL :DWORD

; ticket 08: run a blocking PrintWindow on a worker thread and bound the wait.
CreateThread         PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
WaitForSingleObject  PROTO STDCALL :DWORD, :DWORD
GetExitCodeThread    PROTO STDCALL :DWORD, :DWORD
TerminateThread      PROTO STDCALL :DWORD, :DWORD
CloseHandle          PROTO STDCALL :DWORD

; ---------------------------------------------------------------------------
; ole32 is not bound statically. Its COM entry points are forwards to
; api-ms-win-core-com-l1-1-0, an API-set name with no file on disk; the ordinary
; linker follows the forward, but Crinkler reads the exporting DLL's file and
; cannot. encode.asm resolves the five functions from combase.dll (the real
; implementation) with GetProcAddress at startup. See docs/build.md.
; ---------------------------------------------------------------------------

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
GetSystemMetrics              PROTO STDCALL :SDWORD
InvalidateRect                PROTO STDCALL :DWORD, :DWORD, :DWORD
SetCapture                    PROTO STDCALL :DWORD
ReleaseCapture                PROTO STDCALL
SetFocus                      PROTO STDCALL :DWORD
SetForegroundWindow           PROTO STDCALL :DWORD
MoveWindow                    PROTO STDCALL :DWORD, :SDWORD, :SDWORD, :SDWORD, :SDWORD, :DWORD
wsprintfW                     PROTO C :DWORD, :DWORD, :VARARG
SetWindowDisplayAffinity      PROTO STDCALL :DWORD, :DWORD
UpdateLayeredWindow           PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
BeginPaint                    PROTO STDCALL :DWORD, :DWORD
EndPaint                      PROTO STDCALL :DWORD, :DWORD
AdjustWindowRect              PROTO STDCALL :DWORD, :DWORD, :DWORD
MonitorFromRect               PROTO STDCALL :DWORD, :DWORD
GetMonitorInfoW               PROTO STDCALL :DWORD, :DWORD
GetDpiForWindow               PROTO STDCALL :DWORD   ; the Overlay's effective DPI
OpenClipboard                 PROTO STDCALL :DWORD
EmptyClipboard                PROTO STDCALL
SetClipboardData              PROTO STDCALL :DWORD, :DWORD
CloseClipboard                PROTO STDCALL
RegisterClipboardFormatW      PROTO STDCALL :DWORD

; ticket 08: window capture and window-mode hit-testing.
PrintWindow      PROTO STDCALL :DWORD, :DWORD, :DWORD     ; (hwnd, hdcBlt, flags)
GetWindowRect    PROTO STDCALL :DWORD, :DWORD             ; (hwnd, RECT*)
GetClassNameW    PROTO STDCALL :DWORD, :DWORD, :SDWORD
GetDesktopWindow PROTO STDCALL
GetShellWindow   PROTO STDCALL
IsIconic         PROTO STDCALL :DWORD
; WindowFromPoint(POINT point) takes the POINT BY VALUE. Declared here as two
; SDWORDs and called WindowFromPoint(x, y): the two 4-byte pushes are the same
; 8 stack bytes as POINT{x,y}, which is how MASM marshals a by-value struct.
; (POINT is declared further down; a PROTO cannot name it before it exists.)
WindowFromPoint  PROTO STDCALL :SDWORD, :SDWORD
GetAncestor      PROTO STDCALL :DWORD, :DWORD             ; (hwnd, GA_ROOT)

; ticket 09: the monitor under the pointer for full-screen mode.
; MonitorFromPoint(POINT pt, DWORD flags) also takes the POINT BY VALUE, exactly
; like WindowFromPoint: declared as two SDWORDs and called MonitorFromPoint(x, y).
MonitorFromPoint PROTO STDCALL :SDWORD, :SDWORD, :DWORD

; ---------------------------------------------------------------------------
; comdlg32 - the standard Save As dialog (ticket 05).
; ---------------------------------------------------------------------------
GetSaveFileNameW     PROTO STDCALL :DWORD
CommDlgExtendedError PROTO STDCALL

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
FillRect           PROTO STDCALL :DWORD, :DWORD, :DWORD
SetBkMode          PROTO STDCALL :DWORD, :SDWORD
SetTextColor       PROTO STDCALL :DWORD, :DWORD
GetClientRect      PROTO STDCALL :DWORD, :DWORD
GdiFlush           PROTO STDCALL
DrawTextW          PROTO STDCALL :DWORD, :DWORD, :SDWORD, :DWORD, :DWORD
CreateFontW        PROTO STDCALL :SDWORD, :SDWORD, :SDWORD, :SDWORD, :SDWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
BitBlt             PROTO STDCALL :DWORD, :SDWORD, :SDWORD, :SDWORD, :SDWORD, :DWORD, :SDWORD, :SDWORD, :DWORD

; ---------------------------------------------------------------------------
; comctl32 - ComboBoxEx and its image list. Registered at process init.
; ---------------------------------------------------------------------------
InitCommonControlsEx PROTO STDCALL :DWORD
ImageList_Create     PROTO STDCALL :SDWORD, :SDWORD, :DWORD, :SDWORD, :SDWORD
ImageList_AddMasked  PROTO STDCALL :DWORD, :DWORD, :DWORD
ImageList_Destroy    PROTO STDCALL :DWORD

; ---------------------------------------------------------------------------
; gdiplus - antialiased ink for the annotation tools (ticket 06). gdiplus.dll
; is a real file on disk, not an API-set forwarder, so it links statically for
; both the linked and the Crinkler build. REAL width arguments are passed as
; their float bits in a DWORD (see ink.asm). See docs/ink.md.
; ---------------------------------------------------------------------------
GdiplusStartup       PROTO STDCALL :DWORD, :DWORD, :DWORD
GdiplusShutdown      PROTO STDCALL :DWORD
GdipCreateFromHDC    PROTO STDCALL :DWORD, :DWORD
GdipDeleteGraphics   PROTO STDCALL :DWORD
GdipSetSmoothingMode PROTO STDCALL :DWORD, :DWORD
GdipCreatePen1       PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD  ; (ARGB, REAL width, unit, GpPen**)
GdipDeletePen        PROTO STDCALL :DWORD
GdipDrawLinesI       PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD  ; (gfx, pen, GpPoint*, count)
GdipSetPenStartCap   PROTO STDCALL :DWORD, :DWORD
GdipSetPenEndCap     PROTO STDCALL :DWORD, :DWORD
GdipSetPenLineJoin   PROTO STDCALL :DWORD, :DWORD

; The free-form cut (ticket 07): a GraphicsPath filled antialiased into a
; scratch bitmap whose alpha is the coverage mask, plus image drawing for the
; Editor's alpha-aware paint. A path is built from GpPoints (INT x, INT y), the
; same layout as our Pt.
GdipCreatePath       PROTO STDCALL :DWORD, :DWORD   ; (GpFillMode, GpPath**)
GdipDeletePath       PROTO STDCALL :DWORD
GdipAddPathPolygonI  PROTO STDCALL :DWORD, :DWORD, :DWORD  ; (path, GpPoint*, count)
GdipCreateSolidFill  PROTO STDCALL :DWORD, :DWORD   ; (ARGB, GpSolidFill**)
GdipDeleteBrush      PROTO STDCALL :DWORD
GdipFillPath         PROTO STDCALL :DWORD, :DWORD, :DWORD  ; (gfx, brush, path)
GdipFlush            PROTO STDCALL :DWORD, :DWORD   ; (gfx, GpFlushIntention)
GdipCreateBitmapFromScan0 PROTO STDCALL :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
GdipGetImageGraphicsContext PROTO STDCALL :DWORD, :DWORD
GdipDisposeImage     PROTO STDCALL :DWORD
GdipDrawImageI       PROTO STDCALL :DWORD, :DWORD, :SDWORD, :SDWORD  ; (gfx, image, x, y)
; ticket 17: scale the Snip into the Editor's image area, and pick a decent
; downscale filter.
GdipDrawImageRectI   PROTO STDCALL :DWORD, :DWORD, :SDWORD, :SDWORD, :SDWORD, :SDWORD  ; (gfx, image, x, y, w, h)
GdipSetInterpolationMode PROTO STDCALL :DWORD, :DWORD

; ---------------------------------------------------------------------------
; Window styles and messages (numeric values from the SDK headers)
; ---------------------------------------------------------------------------
WS_CAPTION          EQU 00C00000h
WS_SYSMENU          EQU 00080000h
WS_MINIMIZEBOX      EQU 00020000h
WS_MAXIMIZEBOX      EQU 00010000h
WS_THICKFRAME       EQU 00040000h
WS_CHILD            EQU 40000000h
WS_VISIBLE          EQU 10000000h
WS_TABSTOP          EQU 00010000h
WS_POPUP            EQU 80000000h

WS_EX_LAYERED       EQU 00080000h
WS_EX_TRANSPARENT   EQU 00000020h
WS_EX_TOPMOST       EQU 00000008h
WS_EX_TOOLWINDOW    EQU 00000080h

BS_PUSHBUTTON       EQU 0
CBS_DROPDOWNLIST    EQU 3

CW_USEDEFAULT       EQU 80000000h
SW_SHOWDEFAULT      EQU 10
SW_SHOW             EQU 5
SW_HIDE             EQU 0
CS_HREDRAW          EQU 0002h
CS_VREDRAW          EQU 0001h
IDC_ARROW           EQU 7F00h          ; 32512, an HCURSOR ordinal
IDC_CROSS           EQU 7F03h          ; 32515, the crosshair
COLOR_WINDOW_1      EQU 6              ; (COLOR_WINDOW + 1), a valid pseudo-HBRUSH
DEFAULT_GUI_FONT    EQU 17

WM_CREATE           EQU 0001h
WM_DESTROY          EQU 0002h
WM_SIZE             EQU 0005h
WM_PAINT            EQU 000Fh
WM_CLOSE            EQU 0010h
WM_ERASEBKGND       EQU 0014h
WM_DISPLAYCHANGE    EQU 007Eh          ; a monitor was added, removed, or re-scaled
WM_KEYDOWN          EQU 0100h
WM_MOUSEMOVE        EQU 0200h
WM_LBUTTONDOWN      EQU 0201h
WM_LBUTTONUP        EQU 0202h
WM_RBUTTONUP        EQU 0205h
WM_COMMAND          EQU 0111h
WM_SETFONT          EQU 0030h
WM_CAPTURECHANGED   EQU 0215h          ; mouse capture moved; end a drag cleanly
WM_DPICHANGED       EQU 02E0h          ; the window's effective DPI changed
WM_GETMINMAXINFO    EQU 0024h          ; the window is asked for its size limits

SIZE_MINIMIZED      EQU 1              ; WM_SIZE wParam: not a user size choice

BN_CLICKED          EQU 0
CBN_SELCHANGE       EQU 1
BM_SETSTATE         EQU 00F3h          ; show a push button in the pressed state

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
SRCCOPY             EQU 00CC0020h
CAPTUREBLT          EQU 40000000h      ; include layered/composited windows
R2_NOT              EQU 6              ; invert the destination: an always-visible outline
TRANSPARENT_BK      EQU 1
GWL_STYLE           EQU -16
GA_ROOT             EQU 2

; Virtual-screen metrics (GetSystemMetrics). May be negative.
SM_XVIRTUALSCREEN   EQU 76
SM_YVIRTUALSCREEN   EQU 77
SM_CXVIRTUALSCREEN  EQU 78
SM_CYVIRTUALSCREEN  EQU 79

; MonitorFromPoint / MonitorFromRect / GetMonitorInfoW: full-screen mode picks
; the monitor under the pointer, and the Editor sizes itself to the work area.
MONITOR_DEFAULTTONEAREST EQU 2

; SetWindowDisplayAffinity: keep the Overlay out of its own capture.
WDA_NONE            EQU 00000000h
WDA_EXCLUDEFROMCAPTURE EQU 00000011h

; UpdateLayeredWindow
ULW_ALPHA           EQU 00000002h
AC_SRC_OVER         EQU 0
AC_SRC_ALPHA        EQU 1

DWM_CLOAKED         EQU 14             ; DWMWA_CLOAKED

GWLP_USERDATA       EQU -21

VK_ESCAPE           EQU 1Bh

; CreateFontW: the readout plate's font is built per effective DPI.
FW_NORMAL           EQU 400
DEFAULT_CHARSET     EQU 1
OUT_DEFAULT_PRECIS  EQU 0
CLIP_DEFAULT_PRECIS EQU 0
CLEARTYPE_QUALITY   EQU 5

DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 EQU -4

; --- ticket 05: COM/WIC encoding, the clipboard, and the Save As dialog -----
COINIT_APARTMENTTHREADED EQU 2
CLSCTX_INPROC_SERVER     EQU 1
RPC_E_CHANGED_MODE       EQU 80010106h   ; COM already up on this thread, in another mode
GENERIC_WRITE            EQU 40000000h
WICBitmapEncoderNoCache  EQU 2
GMEM_MOVEABLE            EQU 2
STATFLAG_NONAME          EQU 0
CF_DIB                   EQU 8
CF_DIBV5                 EQU 17
BI_BITFIELDS             EQU 3
LCS_sRGB                 EQU 73524742h    ; 'sRGB', a linear/sRGB colour space tag
COLOR_BTNFACE_1          EQU 16            ; (COLOR_BTNFACE + 1), a pseudo-HBRUSH for FillRect
MAX_PATH                 EQU 260
OFN_OVERWRITEPROMPT      EQU 2
OFN_PATHMUSTEXIST        EQU 800h
OFN_EXPLORER             EQU 80000h

; --- ticket 06: GDI+ annotation constants ----------------------------------
SmoothingModeAntiAlias   EQU 4            ; GDI+ antialiased rasterisation
UnitPixel                EQU 2            ; a pen width is in device pixels
LineCapRound             EQU 2            ; round caps, so a stroke has soft ends
LineJoinRound            EQU 2            ; round joins, so joints don't spike

; --- ticket 08: window capture ---------------------------------------------
PW_RENDERFULLCONTENT    EQU 2            ; render DirectComposition content (undocumented, in the SDK header)
PW_CLIENTONLY           EQU 1            ; we want the whole window, so this is NOT used
GWL_EXSTYLE             EQU -20          ; Get/SetWindowLongW index
DWMWA_EXTENDED_FRAME_BOUNDS EQU 9        ; the visible frame, excluding the invisible resize border
WAIT_OBJECT_0           EQU 0            ; WaitForSingleObject: the thread signalled
WAIT_TIMEOUT            EQU 258          ; WaitForSingleObject: the wait elapsed
CAP_TIMEOUT_MS          EQU 2000         ; how long the UI thread waits on a PrintWindow worker

; --- ticket 07: GDI+ path and pixel-format constants -----------------------
FillModeWinding          EQU 1            ; nonzero fill: a self-crossing loop fills
FlushIntentionSync       EQU 1            ; GdipFlush: drain batched rendering now
PixelFormat32bppARGB     EQU 0026200Ah    ; straight alpha, GDI+ canonical
InterpolationModeHighQualityBicubic EQU 6 ; the downscale filter for a fitted Snip

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

RECT STRUCT
    left     SDWORD ?
    top      SDWORD ?
    right    SDWORD ?
    bottom   SDWORD ?
RECT ENDS                              ; sizeof == 16

SIZEW STRUCT
    _cx      SDWORD ?                   ; `cx` is a register name; MASM rejects it
    _cy      SDWORD ?
SIZEW ENDS                             ; sizeof == 8

BLENDFUNCTION STRUCT
    BlendOp             BYTE ?
    BlendFlags          BYTE ?
    SourceConstantAlpha BYTE ?
    AlphaFormat         BYTE ?
BLENDFUNCTION ENDS                     ; sizeof == 4

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

PAINTSTRUCT STRUCT
    hdc         DWORD ?
    fErase      DWORD ?
    rcPaint     RECT <>
    fRestore    DWORD ?
    fIncUpdate  DWORD ?
    rgbReserved BYTE 32 DUP(?)
PAINTSTRUCT ENDS                       ; sizeof == 64

MONITORINFO STRUCT
    cbSize      DWORD ?
    rcMonitor   RECT <>
    rcWork      RECT <>
    dwFlags     DWORD ?
MONITORINFO ENDS                       ; sizeof == 40

; MINMAXINFO (winuser.h): five POINTs, no padding on x86. WM_GETMINMAXINFO's
; lParam points at one; the Editor sets ptMinTrackSize so it cannot be dragged
; below the toolbar.
MINMAXINFO STRUCT
    ptReserved     POINT <>
    ptMaxSize      POINT <>
    ptMaxPosition  POINT <>
    ptMinTrackSize POINT <>
    ptMaxTrackSize POINT <>
MINMAXINFO ENDS                        ; sizeof == 40

; --- ticket 05: COM/WIC, clipboard, and Save As layouts --------------------
; GUID (guiddef.h): DWORD, WORD, WORD, BYTE[8]. MASM's default structure packing
; is 1, and every field is naturally aligned here, so sizeof == 16.
GUID STRUCT
    Data1   DWORD ?
    Data2   WORD ?
    Data3   WORD ?
    Data4   BYTE 8 DUP(?)
GUID ENDS                              ; sizeof == 16

; STATSTG (objidl.h) on x86: 10 DWORDs, then the CLSID, then 2 DWORDs == 72.
; cbSize is a ULARGE_INTEGER; only its low half is read (a PNG is < 4 GB).
STATSTG STRUCT
    pwcsName          DWORD ?
    dwType            DWORD ?
    cbSizeLow         DWORD ?
    cbSizeHigh        DWORD ?
    mtimeLow          DWORD ?
    mtimeHigh         DWORD ?
    ctimeLow          DWORD ?
    ctimeHigh         DWORD ?
    atimeLow          DWORD ?
    atimeHigh         DWORD ?
    grfMode           DWORD ?
    grfLocksSupported DWORD ?
    clsid             GUID <>
    grfStateBits      DWORD ?
    reserved          DWORD ?
STATSTG ENDS                           ; sizeof == 72

; BITMAPV5HEADER (wingdi.h): 124 bytes. bV5Endpoints is a CIEXYZTRIPLE (3 x 3
; FIXED == 36 bytes); it is kept as raw bytes because it is always left zero.
BITMAPV5HEADER STRUCT
    bV5Size          DWORD ?
    bV5Width         SDWORD ?
    bV5Height        SDWORD ?
    bV5Planes        WORD ?
    bV5BitCount      WORD ?
    bV5Compression   DWORD ?
    bV5SizeImage     DWORD ?
    bV5XPelsPerMeter SDWORD ?
    bV5YPelsPerMeter SDWORD ?
    bV5ClrUsed       DWORD ?
    bV5ClrImportant  DWORD ?
    bV5RedMask       DWORD ?
    bV5GreenMask     DWORD ?
    bV5BlueMask      DWORD ?
    bV5AlphaMask     DWORD ?
    bV5CSType        DWORD ?
    bV5Endpoints     BYTE 36 DUP(?)
    bV5GammaRed      DWORD ?
    bV5GammaGreen    DWORD ?
    bV5GammaBlue     DWORD ?
    bV5Intent        DWORD ?
    bV5ProfileData   DWORD ?
    bV5ProfileSize   DWORD ?
    bV5Reserved      DWORD ?
BITMAPV5HEADER ENDS                    ; sizeof == 124

; OPENFILENAMEW (commdlg.h) on x86: 14 DWORDs, 2 WORDs, 7 DWORDs == 88.
OPENFILENAMEW STRUCT
    lStructSize       DWORD ?
    hwndOwner         DWORD ?
    hInstance         DWORD ?
    lpstrFilter       DWORD ?
    lpstrCustomFilter DWORD ?
    nMaxCustFilter    DWORD ?
    nFilterIndex      DWORD ?
    lpstrFile         DWORD ?
    nMaxFile          DWORD ?
    lpstrFileTitle    DWORD ?
    nMaxFileTitle     DWORD ?
    lpstrInitialDir   DWORD ?
    lpstrTitle        DWORD ?
    Flags             DWORD ?
    nFileOffset       WORD ?
    nFileExtension    WORD ?
    lpstrDefExt       DWORD ?
    lCustData         DWORD ?
    lpfnHook          DWORD ?
    lpTemplateName    DWORD ?
    pvReserved        DWORD ?
    dwReserved        DWORD ?
    FlagsEx           DWORD ?
OPENFILENAMEW ENDS                     ; sizeof == 88

; GdiplusStartupInput (gdiplusinit.h) on x86: 4 DWORDs. GdiplusVersion must be
; 1; the other three are left zero.
GdiplusStartupInput STRUCT
    GdiplusVersion           DWORD ?
    DebugEventCallback       DWORD ?
    SuppressBackgroundThread DWORD ?
    SuppressExternalCodecs   DWORD ?
GdiplusStartupInput ENDS               ; sizeof == 16

ENDIF
