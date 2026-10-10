# Owner-draw our own controls for a Fluent look instead of shipping a manifest

The Shell's New button and two drop-downs and the Editor's seven toolbar buttons are painted by
a new `ui.asm` module using **owner-draw** (`BS_OWNERDRAW` for buttons; `ComboBox` with
`CBS_OWNERDRAWFIXED | CBS_DROPDOWNLIST` for the drop-downs), so they carry the Windows 11
Fluent look and go dark on a dark system. The alternative — a comctl32 v6 visual-styles theme —
still needs a startup manifest, which the single-exe Crinkler build cannot carry
([ADR-0003](0003-theme-chrome-only.md)). Owner-draw uses only the v5 controls and GDI+, both
already linked, so the artifact stays a single compressed `.exe` with no new dependency. This is
the route ADR-0003 named and deferred; here it is chosen and its consequences recorded.

## Context

ADR-0003 left the stock common controls unthemed because a *dark visual-styled* control needs
comctl32 v6, and v6 needs the `Microsoft.Windows.Common-Controls` dependency in a startup
application manifest. The project ships one Crinkler-compressed `snip.exe` with no `.rsrc` and no
resource compiler, and Crinkler 3.0b has no manifest input, so the manifest is out of reach for
the artifact that actually ships. ADR-0003 recorded owner-draw as "the only way to a genuinely
dark control look under the no-manifest constraint … Deferred, not rejected on principle." This
ADR un-defers it.

The Fluent UI *libraries* (WinUI 3 / Windows App SDK, Fluent UI React) are not the subject: they
are XAML/JS runtimes with large DLL dependencies and contradict the single-executable,
no-runtime-dependency promise. This is about reproducing Fluent's *appearance*, not adopting its
framework.

## Considered Options

- **Owner-draw our own controls with GDI+** — rounded 4px surfaces, an accent-filled primary,
  hover/pressed/focus states, Segoe UI Variable and Segoe Fluent Icons, and a real dark state.
  Uses only comctl32 v5 and the GDI+ already linked; no manifest, no `.rsrc`, no new library. The
  cost is hand-rolled control painting and mouse tracking, and it re-implements the drop-down row
  drawing. **Chosen.**
- **A startup manifest + comctl32 v6 + `SetWindowTheme` / `SetPreferredAppMode`** — far less
  code, but only the `debug` build could carry the manifest, so the shipped `size` build would
  stay classic and the look would never reach users. Rejected by ADR-0003; still rejected.
- **A sidecar `snip.exe.manifest`** — breaks "a single `.exe` with no runtime dependencies."
  Rejected.
- **Adopt WinUI 3 / Fluent UI React** — runtime and packaging dependencies the project exists to
  avoid. Rejected.
- **Leave the controls classic** — the documented status quo; the one place the replica visibly
  diverges from the Windows 11 app it imitates. Rejected as the thing to fix.
- **A custom `WS_POPUP` drop-down flyout** (rounded flyout, DWM shadow) instead of owner-drawing
  the real `ComboBox` — full open-list fidelity, but re-implements Escape, arrow navigation,
  outside-click dismissal, and Tab traversal that `IsDialogMessageW` currently supplies for free.
  Deferred: only worth it if the popup's classic border proves objectionable.

## Consequences

- **The controls go dark on a dark system.** `docs/theme.md`, `docs/shell.md`, and ADR-0003 all
  state the controls stay light; after this effort that sentence becomes historical, and those
  docs are updated so a future reader does not "fix" the skin back to stock controls.
- **The drop-downs get simpler.** `ComboBoxEx32` is replaced by a plain `ComboBox`, which deletes
  `shell_make_icons`, the magenta `ICON_COLORKEY` transparency trick, the shared image list, and
  the `CBEM_*` item insertion — a net reduction in `shell.asm`. The drop-down glyphs are drawn
  by the skin instead of loaded through an image list.
- **The open drop-down list is not skinned.** Its list box border and scrollbar remain the classic
  common-control chrome; only the rows inside it are Fluent. This is the accepted cost of keeping
  the real control and its keyboard behaviour.
- **The Editor's tool icons are real font glyphs, with a vector fallback.** Save, Copy, Pen,
  Highlighter, Eraser, and Undo are icon buttons: each carries a Segoe Fluent Icons codepoint as
  its window text, and `ui.asm` draws the **font's glyph** (`GdipDrawString`), falling back to a
  hand-drawn vector polyline when the font is unavailable. The face is read from
  `%WINDIR%\Fonts\SegoeIcons.ttf` (else `segmdl2.ttf`) through a GDI+ **private font collection**
  and taken from that collection's family list, because on this image a native process's GDI+
  cannot resolve the Segoe faces by name (`GdipCreateFontFamilyFromName` returns
  `FontFamilyNotFound` for every Segoe family, and the installed collection omits them, even though
  GDI enumerates them and a .NET probe resolves them). The file itself is readable and the private
  collection renders the glyph, so the fix adds no shipped resource and no new library — only the
  already-linked `gdiplus`. See the ticket 02 follow-up for the full diagnosis.
- **`ui.asm` is a small widget kit, not a framework.** It knows four things: a button, a primary
  button, a combo face, and a combo row. It is deliberately not generalised.
- **The keyboard path is preserved but one detail needs re-verification.** `shell_focus_combo`'s
  SendInput Alt+Down was tuned against `ComboBoxEx32` and must be retested against `ComboBox`.
- **The size build grows by an estimate of 1.5–3 KB**, well under the 64 KB per-part ceiling, and
  adds no import library.
