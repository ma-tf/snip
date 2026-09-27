# The Shell

How the Shell window — the app's home and the one place a snip starts — is put together.
Follows the template in [`docs/architecture.md`](architecture.md).

## What it is

One small top-level window titled *Snipping Tool* holding three stock controls: a New button
and two drop-downs (the snip mode and the delay). Each drop-down row carries a 16×16 icon.
Either drop-down records its choice in `App`; the button does nothing yet. The Shell is a
singleton, so its window class and its one piece of chrome state live in the module.

## Where it lives

`src/shell.asm`. It owns the Shell window class, its `WndProc`, the controls, and the icon
image list. Strings and glyph geometry sit in `.const`; the image-list handle sits in `.data?`.
The control IDs come from `src/snip.inc`; every Win32 binding it uses is in `src/win32.inc`.

## How it works

**Stock controls, one exception.** The New button is a plain `BUTTON`; the two drop-downs are
`ComboBoxEx32` (a common control) rather than `ComboBox`, because ComboBoxEx can show an image
beside each item. The class is registered at process init in `snip.asm` with
`InitCommonControlsEx(ICC_USEREX_CLASSES)`.

**Icons are drawn, not loaded.** There is no `.rsrc` section and no resource compiler.
`shell_make_icons` builds one 16×16, 24-bit masked `HIMAGELIST` and draws the five glyphs —
rectangle, window, full-screen brackets, freeform squiggle, clock — with GDI into a scratch
32-bpp DIB section. `shell_combo_item` inserts each row with `CBEM_INSERTITEM` and an image
index. Both drop-downs share the one list, destroyed in `WM_DESTROY`.

**State.** `CBN_SELCHANGE` arrives as `WM_COMMAND`; the index is read with `CB_GETCURSEL` and
stored in `App.mode` or `App.delay`.

## Gotchas

- **A bitmap lives in one DC at a time.** The scratch DIB is selected into a memory DC while
  it is drawn. `ImageList_AddMasked` selects it into its own DC, so the DIB must be taken back
  out first — `smi_publish` is bracketed by `SelectObject`s for exactly this reason. Leave it
  in and `ImageList_AddMasked` copies black.
- **ComboBoxEx draws its image list opaquely.** A 32-bpp list's alpha channel is ignored, so
  transparency comes from a *masked* list (`ILC_COLOR24 | ILC_MASK`) with the background drawn
  in a colour key (`ICON_COLORKEY`, magenta) that never appears in a glyph.
- **Order matters.** `CBEM_SETIMAGELIST` must run before the items are inserted, and the
  image-list handle must outlive the controls (destroy it in `WM_DESTROY`, not before).
- **`fMask`, not `mask`.** `MASK` is a MASM operator, so the `COMBOBOXEXITEMW` field is renamed.
- **Colour values.** GDI takes `COLORREF` (`0x00BBGGRR`) and the DIB memory is little-endian
  BGRA. Magenta is symmetric, so the key is `0x00FF00FF` either way.

## See also

- [`docs/architecture.md`](architecture.md) — the explainer template and module layout.
- [`docs/build.md`](build.md) — the build loop and why `comctl32.lib` is linked.
- [`docs/keyboard.md`](keyboard.md) — `Alt+N`, `Alt+M`, and `Alt+D` and how they reach the controls.
- `.scratch/asm-snip-build/issues/15-shell-dropdown-icons.md` — the change that added icons.
