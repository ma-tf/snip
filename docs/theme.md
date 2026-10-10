# The theme

How the app follows the system light/dark theme, and how far that reaches. Follows the
template in [`docs/architecture.md`](architecture.md).

## What it is

One module that reads the system light/dark theme at startup — and again whenever it changes —
and uses the answer in two ways: it hands the window classes and the paint paths a small palette,
and it asks DWM to round the top-level frames and set a title bar that matches the theme. The app
follows the system theme without any user setting of its own.

The reach is deliberately partial. Only the parts the app draws itself — the client background,
the Editor's toolbar strip, and the Shell's hint text — and the window frame change with the
theme. The stock controls (`Button`, `ComboBoxEx`, `Static`) do not; they need comctl32 v6, which
the build cannot ship. See [ADR-0003](adr/0003-theme-chrome-only.md) for why.

## Where it lives

`src/theme.asm`. It owns the theme flag, the palette, and the two runtime-resolved entry points.
`src/snip.inc` is the seam: `theme_init` runs once from `snip.asm`; `theme_refresh` re-reads the
theme on a change and returns the new flag; `theme_apply` dresses a top-level window;
`theme_bg_brush` / `theme_face_brush` / `theme_hint_color` hand back the palette. `src/win32.inc`
holds the DWM attribute constants, the uxtheme ordinal, and the `GCLP_HBRBACKGROUND` / `RDW_*`
constants the live path uses.

The callers are `shell.asm` and `editor.asm`: each calls `theme_apply` in its create path, takes
its class background from `theme_bg_brush`, and — in the Editor's paint — fills the toolbar strip
from `theme_face_brush` and the image backdrop from `theme_bg_brush`. Each also handles
`WM_SETTINGCHANGE`: it calls `theme_refresh`, and if the flag changed, re-dresses the frame, swaps
its class background with `SetClassLongW`, and repaints.

## How it works

**The theme is one call.** `theme_init` resolves uxtheme's `ShouldSystemUseDarkMode` (ordinal 138,
no arguments) and calls it; a nonzero result sets `theme_dark`. It reports whether the system is
using its dark theme. Its sibling `ShouldAppsUseDarkMode` (132) is the more obvious "app mode"
query, but it returns `0` in the app's bare Win32 process, so the dark palette was never selected;
reading `AppsUseLightTheme` from the registry instead returns `ERROR_NOACCESS` from this image. See
[ADR-0003](adr/0003-theme-chrome-only.md).

**The palette follows the flag.** Light is exactly what the Shell and Editor used before theming:
the `COLOR_WINDOW_1` / `COLOR_BTNFACE_1` pseudo-HBRUSHes and the `#808080` hint. Dark is Fluent's
base and alt-surface greys (`#202020`, `#2B2B2B`) as real `CreateSolidBrush` brushes, with
`#C5C5C5` secondary text. The class background accepts either a real brush or the pseudo value, so
the light path is unchanged and a failure leaves the pre-theming look. `theme_refresh` rebuilds
both sets only when the flag actually flips.

**DWM supplies the chrome.** `theme_apply` sets `DWMWA_USE_IMMERSIVE_DARK_MODE` to the flag (so the
title bar is dark on a dark system and light on a light one) and `DWMWA_WINDOW_CORNER_PREFERENCE`
to `DWMWCP_ROUND` for Win11 rounded corners. Both attributes are Win11-only; older systems ignore
the calls and keep square, plain chrome.

**Everything is best-effort.** The two entry points come from `LoadLibraryA` + `GetProcAddress`,
the same Crinkler-safe pattern `capture.asm` uses for `DwmGetWindowAttribute`, so the build gains
no import library. If either DLL or export is missing, the affected step is skipped and the light
palette stands.

**A theme change restyles live.** Windows broadcasts `WM_SETTINGCHANGE` (whose `lParam` names
`ImmersiveColorSet`) when the theme flips. Each window's handler calls `theme_refresh`, which
re-reads ordinal 138; a window that was drawing the old flag then re-runs `theme_apply`, swaps its
class background with `SetClassLongW(hwnd, GCLP_HBRBACKGROUND, ...)`, and `RedrawWindow`s itself
and its children (`RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN`), so the frame, client, hint, and
Editor strip all follow without a relaunch. `lParam` itself is not inspected: on a broadcast that
pointer is not reliably readable across processes, and re-reading the value is the robust test.

## Gotchas

- **The stock controls stay light on a dark system.** This is the manifest ceiling, not a bug
  (ADR-0003). Do not add `SetWindowTheme`/`SetPreferredAppMode` "fixes": without comctl32 v6 they
  do nothing, and with it the process would need a manifest the `size` build cannot carry.
- **The light palette is the fallback, so failures are invisible.** A missing uxtheme or a
  `ShouldSystemUseDarkMode` that returns false both leave a working light window; there is nothing to
  assert on. The only observable is the rendered colours.
- **A `WM_SETTINGCHANGE` whose value did not change is ignored.** The handler compares the re-read
  flag against the one the window last drew, so unrelated `WM_SETTINGCHANGE`s (fonts, locale) do
  not repaint a large Editor image. `lParam` is never inspected.
- **Detect the theme through ordinal 138, not 132 and not the registry.** `ShouldAppsUseDarkMode`
  (132) reads like the purpose-built app-mode query but returns `0` in the app, and the
  `AppsUseLightTheme` registry read returns `ERROR_NOACCESS` (`998`) from this image even though the
  identical call works from a standalone probe. `ShouldSystemUseDarkMode` (138) is the ordinal that
  reports the user's setting here. Covered by [ADR-0003](adr/0003-theme-chrome-only.md).
- **The dark brushes are created and never deleted.** They live for the life of the process, like
  the window classes that reference them; there is no `WM_DESTROY` for a class background. A live
  flip builds a fresh pair and **leaks the old one on purpose**: the Shell's and the Editor's
  classes share the handle, so freeing it while either still references it would be a
  use-after-free.
- **`DWMWA_USE_IMMERSIVE_DARK_MODE` is set to the flag explicitly.** On a light system that means
  forcing a light title bar, which is what the rest of the light window expects; leaving it unset
  would let the frame follow the app default instead.

## See also

- [ADR-0003](adr/0003-theme-chrome-only.md) — why the chrome and the palette, but not the controls.
- [`docs/shell.md`](shell.md) — the Shell, its class background, and the hint's colours.
- [`docs/editor.md`](editor.md) — the Editor's toolbar strip and image backdrop.
- [`docs/build.md`](build.md) — the build loop and the two variants' sizes.
- [Ticket 19](../.scratch/asm-snip-build/issues/19-system-theme-chrome.md) — the change that added it.
