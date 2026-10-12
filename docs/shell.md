# The Shell

How the Shell window — the app's home and the one place a snip starts — is put together.
Follows the template in [`docs/architecture.md`](architecture.md).

## What it is

One small top-level window titled *Snipping Tool* holding three controls: a New button and two
drop-downs (the snip mode and the delay). The drop-downs are owner-drawn: the closed face is
icon-only — the current selection's 16×16 glyph and a chevron — while each open row shows its
glyph beside its label. Either drop-down records its choice in `App`; New starts a Snipping
session. The window is resizable — the controls stay fixed at the top and the space below them
carries a centred hint advertising `Alt+N`. The Shell is a singleton, so its window class and its
one piece of chrome state live in the module.

## Where it lives

`src/shell.asm`. It owns the Shell window class, its `WndProc`, and the controls. Strings and
glyph ids sit in `.const`; the hint's handle and the last-drawn theme flag sit in `.data?`.
The control IDs come from `src/snip.inc`; every Win32 binding it uses is in `src/win32.inc`, and
the controls' look is painted by `src/ui.asm` (see
[ADR-0004](adr/0004-owner-draw-fluent-controls.md)).

## How it works

**Owner-drawn controls.** The New button is a plain `BUTTON` with `BS_OWNERDRAW`; the two
drop-downs are a plain `ComboBox` with `CBS_OWNERDRAWFIXED | CBS_DROPDOWNLIST`. `shell_on_create`
attaches each to the skin with `ui_attach`, and the parent's `WM_DRAWITEM` routes to
`ui_draw_item` in `src/ui.asm`, which paints the Windows 11 Fluent look. This is what lets the
controls go dark on a dark system without a comctl32 v6 manifest; see
[ADR-0004](adr/0004-owner-draw-fluent-controls.md).

**The window and its controls follow the system theme.** `shell_on_create` calls `theme_apply`
for the rounded frame and the themed title bar, and the class background and the hint colour come
from `theme.asm`'s palette (`theme_bg_brush`, `theme_hint_color`). The controls are painted by
`ui.asm`, which reads `theme_is_dark` at draw time, so they go dark with the rest of the window.
See [`docs/theme.md`](theme.md).

**The face is icon-only; the rows are not.** The closed face (the selection field) carries the
current selection's 16×16 glyph and a chevron and no label, matching the Win11 Snipping Tool;
each open row carries its glyph and its label. The face is narrower (`COMBO_FACE_W`, 52px) than
the open list (`COMBO_DROP_W`, 150px): `CB_SETDROPPEDWIDTH` widens the pop-up so the labels
still fit. `shell_combo_add` tags each row with a `UI_GLYPH_*` id through `CB_SETITEMDATA`, and
`ui.asm` draws the glyphs as vector paths — there is no `.rsrc` section and no resource compiler.

**State.** `CBN_SELCHANGE` arrives as `WM_COMMAND`; the index is read with `CB_GETCURSEL` and
stored in `App.mode` or `App.delay`.

**Resizable, with a hint.** The style carries `WS_THICKFRAME | WS_MAXIMIZEBOX`, and
`WM_GETMINMAXINFO` raises the floor so the window cannot be dragged below the control row and a
line of hint (a client of 404×120). The controls are fixed; only the hint moves. `shell_layout`
spans it across the space below the row — called from `WM_SIZE`, and once at create-time — and
the static's `SS_CENTER | SS_CENTERIMAGE` centres the text in both axes. `WM_CTLCOLORSTATIC`
returns `NULL_BRUSH` with `TRANSPARENT` text mode, so the hint shows the window background rather
than a grey box; its colour is `theme_hint_color` (grey on light, lighter grey on dark). The hint
is an addition beyond the Win11 reference — it advertises the `Alt+N` accelerator from `keys.asm`.

## Gotchas

- **The face is painted by the skin, not the ComboBox.** The base control draws a classic 3-D
  border and a drop-down arrow button that owner-draw's `rcItem` never covers. `ui_paint_combo`
  (in `ui.asm`) takes the whole `WM_PAINT` for a combo, so the control never draws its face;
  `WM_NCPAINT` is suppressed for the same reason.
- **A narrower closed face needs a wider pop-up.** `CB_SETDROPPEDWIDTH` (`0x0160`) widens only
  the open list. Without it the list would be as narrow as the face and clip the labels.
- **A plain `ComboBox` needs `CBS_HASSTRINGS`.** With `CBS_OWNERDRAWFIXED` and no
  `CBS_HASSTRINGS`, `CB_ADDSTRING`'s pointer becomes the item *data* and `CB_GETLBTEXT` returns
  nothing, so the rows would draw their glyph but no text.
- **A Static paints its own background.** A `Static` control fills its client from the brush its
  parent returns to `WM_CTLCOLORSTATIC`, and the default is the button face — which would draw a
  grey block over the window. Returning `NULL_BRUSH` with `TRANSPARENT` text mode lets the
  Shell's background show through. Do **not** add `WS_CLIPCHILDREN` to the Shell without changing
  this: it would stop the parent painting under the static, leaving the hint's area unpainted.
- **The controls go dark because the skin paints them, not because a theme is set.** They are
  ordinary comctl32 v5 controls; a dark *stock* control would need v6 and a startup manifest the
  build cannot ship, so `ui.asm` draws the pixels instead. See
  [ADR-0004](adr/0004-owner-draw-fluent-controls.md).

## See also

- [`docs/architecture.md`](architecture.md) — the explainer template and module layout.
- [`docs/theme.md`](theme.md) — the system light/dark theme and the window chrome.
- [`docs/build.md`](build.md) — the build loop and why `comctl32.lib` is linked.
- [`docs/keyboard.md`](keyboard.md) — `Alt+N`, `Alt+M`, and `Alt+D` and how they reach the controls.
- `.scratch/asm-snip-build/issues/15-shell-dropdown-icons.md` — the change that added icons.
- `.scratch/fluent-controls/issues/07-icon-only-combo-face.md` — the change that made the closed
  face icon-only and narrowed it.
- `.scratch/asm-snip-build/issues/18-shell-resize-hint.md` — the change that made the Shell
  resizable and added the hint.
- `.scratch/asm-snip-build/issues/19-system-theme-chrome.md` — the change that added the theme.
