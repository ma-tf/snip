; snip.asm
; Snipping Tool replica in x64 MASM - walking skeleton.
; No C runtime, no CRT startup.
;
; Build: build.cmd   (assembles to build\snip.obj, links to build\snip.exe)
; Run:   build\snip.exe   - opens a window and exits cleanly on close.
;
; This is deliberately just the window + message pump. Capture, the overlay,
; the editor, and the encoder land on top of it in later tickets.

option casemap:none

; ---------------------------------------------------------------------------
; Win32 imports (resolved from the import libraries named on the link line)
; ---------------------------------------------------------------------------
EXTERN GetModuleHandleW:PROC
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
EXTERN ExitProcess:PROC

; Entry point must be visible to the linker for /entry:.
PUBLIC WinMainASM

; ---------------------------------------------------------------------------
; Win32 constants (numeric values from the SDK headers)
; ---------------------------------------------------------------------------
WS_OVERLAPPEDWINDOW EQU 000CF0000h
CW_USEDEFAULT       EQU 80000000h
SW_SHOWDEFAULT      EQU 10
CS_HREDRAW          EQU 0002h
CS_VREDRAW          EQU 0001h
IDC_ARROW           EQU 7F00h
WM_DESTROY          EQU 0002h
COLOR_WINDOW_1      EQU 6          ; (COLOR_WINDOW + 1) system brush ordinal

; ---------------------------------------------------------------------------
; Structures (exact x64 layouts from winuser.h)
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

POINT STRUCT 4
    x DWORD ?
    y DWORD ?
POINT ENDS

MSG STRUCT 8
    hwnd     QWORD ?
    message  DWORD ?
    _pad0    DWORD ?
    wParam   QWORD ?
    lParam   QWORD ?
    time     DWORD ?
    pt       POINT <>
    lPrivate DWORD ?
MSG ENDS                               ; sizeof == 48

; ---------------------------------------------------------------------------
; Mutable data
; ---------------------------------------------------------------------------
.data
class_name   DW 'S','n','i','p','T','o','o','l','C','l','a','s','s',0
window_name  DW 'S','n','i','p','p','i','n','g',' ','T','o','o','l',' ','(','a','s','m',')',0
wc           WNDCLASSEXW <>
msg          MSG <>
hinst        QWORD ?
hwnd         QWORD ?

; ---------------------------------------------------------------------------
.code

; ---------------------------------------------------------------------------
; WndProc(hwnd, msg, wParam, lParam)
; Non-leaf functions need FRAME + unwind directives so a crash is debuggable.
; ---------------------------------------------------------------------------
WndProc PROC FRAME
    sub  rsp, 28h            ; 8 bytes align + 32 bytes shadow space
    .allocstack 28h
    .endprolog

    cmp  edx, WM_DESTROY
    je   wm_destroy

    call DefWindowProcW       ; rcx/rdx/r8/r9 already hold the 4 arguments
    add  rsp, 28h
    ret

wm_destroy:
    xor  ecx, ecx
    call PostQuitMessage
    xor  eax, eax
    add  rsp, 28h
    ret
WndProc ENDP

; ---------------------------------------------------------------------------
; Entry point. The OS calls it with RSP == 8 (mod 16); there is no CRT to set
; anything up, so we allocate shadow space and keep the stack aligned ourselves.
; ---------------------------------------------------------------------------
WinMainASM PROC FRAME
    sub  rsp, 88h            ; 0x20 shadow + 0x60 (8 stack args for CreateWindowExW)
    .allocstack 88h
    .endprolog

    ; hinst = GetModuleHandleW(NULL)
    xor  ecx, ecx
    call GetModuleHandleW
    mov  hinst, rax
    mov  wc.hInstance, rax

    ; wc = { ... }
    mov  wc.cbSize, SIZEOF WNDCLASSEXW
    mov  wc.style, CS_HREDRAW OR CS_VREDRAW
    lea  rax, WndProc
    mov  wc.lpfnWndProc, rax
    mov  wc.cbClsExtra, 0
    mov  wc.cbWndExtra, 0
    mov  wc.hbrBackground, COLOR_WINDOW_1

    ; wc.hCursor = LoadCursorW(NULL, IDC_ARROW)
    xor  ecx, ecx
    mov  edx, IDC_ARROW
    call LoadCursorW
    mov  wc.hCursor, rax

    lea  rdx, class_name
    mov  wc.lpszClassName, rdx

    ; RegisterClassExW(&wc)
    lea  rcx, wc
    call RegisterClassExW
    test eax, eax
    jz   done

    ; CreateWindowExW(exStyle, class, title, style, x, y, w, h,
    ;                 parent, menu, hinst, param)
    ; 5th..12th arguments live on the stack, starting at [rsp+20h].
    mov  qword ptr [rsp+20h], CW_USEDEFAULT       ; x
    mov  qword ptr [rsp+28h], CW_USEDEFAULT       ; y
    mov  qword ptr [rsp+30h], CW_USEDEFAULT       ; nWidth
    mov  qword ptr [rsp+38h], CW_USEDEFAULT       ; nHeight
    mov  qword ptr [rsp+40h], 0                   ; hWndParent
    mov  qword ptr [rsp+48h], 0                   ; hMenu
    mov  rax, hinst
    mov  qword ptr [rsp+50h], rax                 ; hInstance
    mov  qword ptr [rsp+58h], 0                   ; lpParam
    xor  ecx, ecx                                 ; exStyle
    lea  rdx, class_name
    lea  r8, window_name
    mov  r9d, WS_OVERLAPPEDWINDOW
    call CreateWindowExW
    mov  hwnd, rax
    test rax, rax
    jz   done

    ; ShowWindow(hwnd, SW_SHOWDEFAULT); UpdateWindow(hwnd)
    mov  rcx, hwnd
    mov  edx, SW_SHOWDEFAULT
    call ShowWindow
    mov  rcx, hwnd
    call UpdateWindow

    ; Message pump
msg_loop:
    lea  rcx, msg
    xor  edx, edx
    xor  r8d, r8d
    xor  r9d, r9d
    call GetMessageW
    test eax, eax
    jle  done                  ; 0 == WM_QUIT, -1 == error
    lea  rcx, msg
    call TranslateMessage
    lea  rcx, msg
    call DispatchMessageW
    jmp  msg_loop

done:
    xor  ecx, ecx
    call ExitProcess
WinMainASM ENDP

END
