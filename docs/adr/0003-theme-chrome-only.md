# Theme only the window chrome and our own surfaces, and follow the system theme

The app follows the system light/dark theme for the parts it draws itself and for its window
frame, and leaves the stock common controls alone. Concretely: `theme.asm` asks uxtheme's
`ShouldSystemUseDarkMode` (ordinal 138) at startup — and again on `WM_SETTINGCHANGE` — picks one
of two hardcoded palettes from the answer, and uses DWM (`DwmSetWindowAttribute`) to round the
top-level frames and set a title bar that matches the theme. The client background, the Editor's
toolbar strip, and the Shell's hint text change with the theme, live; the `Button`, `ComboBoxEx`,
and `Static` controls do not.

The reason the controls are left out is structural, not a shortcut. A **dark common control needs
comctl32 v6**, and v6 is only loaded for a process that declares the `Microsoft.Windows.Common-
Controls` dependency in a **startup application manifest**. Without that manifest the process binds
comctl32 v5, where `SetWindowTheme`/`SetPreferredAppMode` and the whole visual-styles layer do not
exist — verified: the running process loads `..._5.82...` comctl32, and the buttons render classic.
The project ships a single Crinkler-compressed `snip.exe` with **no `.rsrc` and no resource
compiler**, and Crinkler 3.0b has no manifest or resource input, so the size build cannot carry a
manifest. An embedded manifest would only reach the `debug` build (which is not the shipping
artifact), and an external `snip.exe.manifest` sidecar contradicts the spec's single-exe, no-
runtime-dependency promise. Dark common controls are therefore out of reach without a resource
story the project has deliberately refused.

## Considered Options

- **Owner-draw every control** (rounded GDI+ rectangles, hover states, Segoe Fluent Icons) — the
  only way to a genuinely dark control look under the no-manifest constraint, but a large amount of
  hand-rolled control code for a styling win. Deferred, not rejected on principle.
- **Embed a manifest in the `debug` build only** — rejected: the shipped artifact is the Crinkler
  `size` build, so the two builds would diverge visually and the feature would not ship.
- **Ship a sidecar `snip.exe.manifest`** — rejected: it breaks "a single `.exe` with no runtime
  dependencies" and would have to survive the `size` build's whole reason for existing.
- **Read `AppsUseLightTheme` from the registry directly** — the obvious route, and what the WinUI
  reference effectively does; it is literally the setting. But from this image `RegGetValueW`
  returns `ERROR_NOACCESS` (`998`) for a valid subkey, even though the identical call from a
  standalone 32-bit probe succeeds (the subkey bytes are present and readable at the runtime
  address, and relocations are applied). Rejected — the call fails in-process.
- **uxtheme's `ShouldAppsUseDarkMode` (ordinal 132)** — the "app mode" query, and the first fix
  tried. It returns `0` in the app's bare Win32 process whatever the setting (a bare probe read
  `AppsUseLightTheme = 0` and still got `0`), so the dark palette was never chosen and the app
  stayed light on a dark desktop. Rejected.
- **uxtheme's `ShouldSystemUseDarkMode` (ordinal 138)** — reports the user's system theme. Verified
  to return the right value in the app where 132 does not. **Chosen.**
- **Read the theme only at startup, with no `WM_SETTINGCHANGE` handler** — rejected: the app would
  keep a stale palette until relaunched, unlike the Win11 reference, which restyles live.
- **Do nothing** — the app would stay light on a dark desktop, unlike the Win11 reference.

## Consequences

- **The two builds diverge from the reference in the same way.** On a dark system the window
  frame, title bar, client background, toolbar strip, and hint go dark; the buttons and drop-downs
  stay light. This is recorded in `docs/shell.md` and `docs/theme.md` so it is not mistaken for a
  bug.
- **The palette is two fixed sets, not a theme engine.** Light reuses the pseudo-HBRUSHes
  (`COLOR_WINDOW_1`, `COLOR_BTNFACE_1`) and grey the Shell already had, so an unreadable theme
  leaves the pre-theming look byte-for-byte. Dark is Fluent's `#202020`/`#2B2B2B` with `#C5C5C5`
  secondary text. There is no per-accent or per-user-color support.
- **The theme follows the system live.** Each window handles `WM_SETTINGCHANGE`: `theme_refresh`
  re-reads ordinal 138, and on a flip the window re-dresses its frame, swaps its class background
  with `SetClassLongW(GCLP_HBRBACKGROUND, ...)`, and `RedrawWindow`s itself and its children. A
  `WM_SETTINGCHANGE` whose flag did not change is ignored, so an unrelated setting change costs only
  a re-read. `lParam` (the `ImmersiveColorSet` name) is deliberately not inspected — the pointer is
  not reliably readable across processes. The pre-flip brushes are leaked on purpose, because the
  Shell's and the Editor's classes share the handle.
- **The chrome is best-effort.** `DwmSetWindowAttribute` attribute indices and the uxtheme ordinal
  are either Win11-only or undocumented; every call is guarded and a failure leaves the light
  palette, so the module degrades rather than breaks. The size build cost of the whole module is
  **+236 bytes** (8,906 → 9,142).
