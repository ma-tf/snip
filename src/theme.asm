; theme.asm
; Fluent window chrome and the system light/dark palette.
;
; The app follows the system light/dark theme. theme_init is called once from snip.asm
; before any window exists: it asks uxtheme whether the system uses the dark
; theme and caches the palette. theme_apply dresses a top-level window with a
; rounded frame and a title bar that matches the theme, through DWM.
;
; Only the window chrome and our own drawn surfaces are themed, so only the
; client background, the toolbar strip, and the hint text change with the theme.
; The stock controls (Button, ComboBoxEx, Static) stay light: a dark common
; control needs comctl32 v6, and v6 needs an application manifest, which neither
; the linked nor the Crinkler size build can ship (no .rsrc, no manifest input).
; See ADR-0003.
;
; The two entry points - uxtheme's ShouldSystemUseDarkMode (ordinal 138) and
; DWM's DwmSetWindowAttribute - are resolved at runtime with GetProcAddress, the
; same Crinkler-safe pattern capture.asm uses for DwmGetWindowAttribute: the
; build gains no import library. A failure at any step leaves the plain light
; look, so the module degrades rather than breaks.
;
; See docs/theme.md and ADR-0003.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC theme_init
PUBLIC theme_refresh
PUBLIC theme_apply
PUBLIC theme_bg_brush
PUBLIC theme_face_brush
PUBLIC theme_hint_color
PUBLIC theme_is_dark

; ---------------------------------------------------------------------------
; Statics. The Shell and the Editor are singletons, so the palette lives here.
; ---------------------------------------------------------------------------
.const
; Library and entry-point names, resolved with LoadLibraryA/GetProcAddress.
uxtheme_dll    DB 'uxtheme.dll',0
dwmapi_dll     DB 'dwmapi.dll',0
fn_DwmSetWindowAttribute DB 'DwmSetWindowAttribute',0

; The palette. The light values are exactly the pseudo-HBRUSHes and the grey the
; Shell already used, so the default look is unchanged when the theme cannot be
; read. The dark values are Fluent's base/alt-surface greys and a light
; secondary text.
HINT_LIGHT      EQU 00808080h   ; grey, read on the light window
HINT_DARK       EQU 00C5C5C5h   ; light grey, read on the dark window
DARK_BG         EQU 00202020h   ; the dark client background (#202020)
DARK_FACE       EQU 002B2B2Bh   ; the dark toolbar / surface (#2B2B2B)

.data?
theme_dark     DWORD ?          ; 1 once uxtheme reports the system theme dark
theme_bg       DWORD ?          ; HBRUSH for the client background
theme_face     DWORD ?          ; HBRUSH for the toolbar strip / surface
theme_hint     DWORD ?          ; COLORREF for secondary text
theme_attr     DWORD ?          ; scratch for a DWM attribute value

pfn_DwmSetWindowAttribute DWORD ?
pfn_ShouldSystemUseDarkMode DWORD ?   ; resolved once, reused by every theme_refresh

.code

; ---------------------------------------------------------------------------
; theme_probe() -> eax = 1 if the system is in its dark theme, else 0.
;
; Calls uxtheme's ShouldSystemUseDarkMode (ordinal 138), resolving it once and
; caching the pointer. Any failure - no uxtheme, no export - reports light. It
; touches no palette state, so both theme_init and theme_refresh build on it. It
; reads the live theme, so a re-call after WM_SETTINGCHANGE returns the new value.
; ---------------------------------------------------------------------------
theme_probe PROC
    mov  eax, pfn_ShouldSystemUseDarkMode
    test eax, eax
    jnz  tp_call                 ; already resolved

    INVOKE LoadLibraryA, OFFSET uxtheme_dll
    test eax, eax
    jz   tp_light
    INVOKE GetProcAddress, eax, UXTHEME_ORD_SHOULD_SYSTEM_USE_DARK_MODE
    mov  pfn_ShouldSystemUseDarkMode, eax
    test eax, eax
    jz   tp_light
tp_call:
    call eax
    test eax, eax
    jz   tp_light
    mov  eax, 1
    ret
tp_light:
    xor  eax, eax
    ret
theme_probe ENDP

; ---------------------------------------------------------------------------
; theme_init() -> void. Called once from snip.asm before any window exists.
;
; Seeds the light palette, then best-effort: uxtheme reports the system theme
; and dwmapi supplies the window-chrome entry point. Each step that fails
; leaves what the earlier steps set, so the module always has a usable palette
; and never aborts startup.
; ---------------------------------------------------------------------------
theme_init PROC
    ; --- defaults: the light palette, unchanged from before theming ---
    mov  theme_bg, COLOR_WINDOW_1
    mov  theme_face, COLOR_BTNFACE_1
    mov  theme_hint, HINT_LIGHT

    ; --- uxtheme.dll: does the system use the dark theme? ---
    ; ShouldSystemUseDarkMode is undocumented and exported by ordinal 138, and
    ; takes no arguments, so there is nothing to marshal. Its sibling
    ; ShouldAppsUseDarkMode (132) looks like the "app mode" query but returns 0
    ; in the app's bare Win32 process, so the dark palette was never selected;
    ; reading HKCU's AppsUseLightTheme instead returns ERROR_NOACCESS from this
    ; image. 138 is the ordinal that reports the user's setting here. See
    ; docs/theme.md and ADR-0003.
    INVOKE theme_probe
    mov  theme_dark, eax

ti_dwm:
    ; --- dwmapi.dll: the window chrome, resolved whatever the theme ---
    INVOKE LoadLibraryA, OFFSET dwmapi_dll
    test eax, eax
    jz   ti_palette
    INVOKE GetProcAddress, eax, OFFSET fn_DwmSetWindowAttribute
    mov  pfn_DwmSetWindowAttribute, eax

ti_palette:
    cmp  theme_dark, 0
    je   ti_done
    INVOKE CreateSolidBrush, DARK_BG
    mov  theme_bg, eax
    INVOKE CreateSolidBrush, DARK_FACE
    mov  theme_face, eax
    mov  theme_hint, HINT_DARK
ti_done:
    ret
theme_init ENDP

; ---------------------------------------------------------------------------
; theme_refresh() -> eax = the current theme flag (1 dark, 0 light), after
; re-reading the system. Called from each window's WM_SETTINGCHANGE handler.
;
; Rebuilds theme_bg / theme_face / theme_hint only when the value flipped, so a
; caller can compare the return against the value it last drew to decide whether
; to repaint. The previous brushes are not deleted: the Shell's and the Editor's
; window classes were both registered with the same handle, so freeing it while
; either still references it would be a use-after-free, and the Editor's paint
; reads the same handle. A toggle therefore leaks one pair of brushes, exactly
; as the module already leaked the startup pair. See docs/theme.md.
; ---------------------------------------------------------------------------
theme_refresh PROC USES ebx
    INVOKE theme_probe
    mov  ebx, eax
    cmp  ebx, theme_dark
    je   tr_done                 ; unchanged: leave the palette alone

    mov  theme_dark, ebx
    test ebx, ebx
    jz   tr_light

    INVOKE CreateSolidBrush, DARK_BG
    mov  theme_bg, eax
    INVOKE CreateSolidBrush, DARK_FACE
    mov  theme_face, eax
    mov  theme_hint, HINT_DARK
    jmp  tr_done

tr_light:
    mov  theme_bg, COLOR_WINDOW_1
    mov  theme_face, COLOR_BTNFACE_1
    mov  theme_hint, HINT_LIGHT

tr_done:
    mov  eax, theme_dark
    ret
theme_refresh ENDP

; ---------------------------------------------------------------------------
; theme_apply(HWND hwnd) -> void. Dress one top-level window with a rounded
; frame and a title bar matching the theme. Called from each window's create
; path. A no-op if DWM could not be resolved.
; ---------------------------------------------------------------------------
theme_apply PROC USES ebx hwnd:DWORD
    mov  ebx, hwnd

    mov  eax, pfn_DwmSetWindowAttribute
    test eax, eax
    jz   ta_done

    ; DWMWA_USE_IMMERSIVE_DARK_MODE <- theme_dark (1 dark, 0 light).
    mov  eax, theme_dark
    mov  theme_attr, eax
    mov  eax, pfn_DwmSetWindowAttribute
    push 4
    push OFFSET theme_attr
    push DWMWA_USE_IMMERSIVE_DARK_MODE
    push ebx
    call eax

    ; DWMWA_WINDOW_CORNER_PREFERENCE <- DWMWCP_ROUND.
    mov  theme_attr, DWMWCP_ROUND
    mov  eax, pfn_DwmSetWindowAttribute
    push 4
    push OFFSET theme_attr
    push DWMWA_WINDOW_CORNER_PREFERENCE
    push ebx
    call eax

ta_done:
    xor  eax, eax
    ret
theme_apply ENDP

; ---------------------------------------------------------------------------
; The palette accessors. The class background takes either a real HBRUSH or the
; (COLOR_*+1) pseudo value, so the light palette can hand back the same pseudo
; values the window classes used before theming.
; ---------------------------------------------------------------------------
theme_bg_brush PROC
    mov  eax, theme_bg
    ret
theme_bg_brush ENDP

theme_face_brush PROC
    mov  eax, theme_face
    ret
theme_face_brush ENDP

theme_hint_color PROC
    mov  eax, theme_hint
    ret
theme_hint_color ENDP

; ---------------------------------------------------------------------------
; theme_is_dark() -> eax = the current theme flag (1 dark, 0 light). The skin
; (ui.asm) keys its control palette off this, the way the window classes key
; their backgrounds off theme_bg_brush. Read-only: it never re-probes, so a
; caller that needs the live value calls theme_refresh first.
; ---------------------------------------------------------------------------
theme_is_dark PROC
    mov  eax, theme_dark
    ret
theme_is_dark ENDP

END
