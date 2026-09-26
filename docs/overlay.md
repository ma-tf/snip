# The Overlay

How the dimmed full-screen surface a Selection is marked on is put together.
Follows the template in [`docs/architecture.md`](architecture.md).

## What it is

One top-level window spanning the virtual screen, presented from a
premultiplied 32bpp DIB through `UpdateLayeredWindow`. It owns three things and
nothing else: the dim, the punched hole where the Selection is, and the chrome
that names the hole — an opaque readout plate. It does **not** own the
Selection and does **not** interpret the mouse; `select.asm` does both, and
calls `overlay_repaint` with the Selection to draw.

That split is the module's whole point. The Overlay is a *surface*: give it a
rectangle and a frame appears. The behaviour that decides what the rectangle is
belongs next door.

## Where it lives

`src/overlay.asm`. It owns the window class, the presentation DIB, the layered
present, and the chrome. Strings and the format string live in `.const`; window,
DIB, and geometry state live in `.data?`. The WndProc it registers is
`sel_wndproc`, declared in `src/select.asm` and prototyped in `src/snip.inc` —
the class is the Overlay's, the messages are the Selection's.

## How it works

**One DIB, written directly.** `UpdateLayeredWindow` takes a per-pixel-alpha
source, so the Overlay owns a 32bpp top-down DIB section and writes its pixels
through the `bits` pointer. No GDI paint path, no window DC, no `WM_PAINT`.

**Premultiplied, because DWM says so.** `BLENDFUNCTION{ AC_SRC_OVER, 0, 255,
AC_SRC_ALPHA }` makes DWM multiply colour by alpha before compositing, so the
DIB must already be premultiplied. Black is black at any alpha, which is why the
dim is a raw `0x80000000` fill (`ovl_fill_dim`) with no blend step.

**Three writes, one present.** Each frame: fill every pixel with the dim, zero
the Selection's pixels so the desktop shows through undimmed, stroke the hole's
outline, and stamp the readout plate. Then present once. DWM never sees a
half-drawn frame — present-once is what stops the flicker a naive
paint-to-the-window would show.

**The readout is why this module uses `UpdateLayeredWindow` at all.** With
`SetLayeredWindowAttributes(LWA_ALPHA)` alpha is a property of the *window*: a
plate drawn over the dim composites to grey and its text washes out. The
ticket 07 prototype measured exactly that failure. Per-pixel alpha lets the dim
sit at 128 while the plate and its text sit at 255, so the plate is genuinely
opaque. It is drawn into a small scratch DIB by ordinary GDI (real font
rasterisation) and stamped in by `ovl_blit_opaque`.

**Geometry is the virtual screen, re-read every show.** `SM_*VIRTUALSCREEN`
returns the bounding box of every monitor and *can be negative* — a monitor left
of the primary gives a negative `x`. That origin is used both as the window
position and as the DIB's origin, so a Selection's screen coordinates are also
its DIB coordinates.

**Self-exclusion is set once.** `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`
after creation keeps the dim and chrome out of every capture, including our own
— which is what stops the dim appearing in the snip. It is a property of the
window, not of a frame, so it is set once and never touched again.

## Gotchas

- **Batched GDI needs `GdiFlush` before a CPU read of a DIB.** `DrawTextW` into
  a DIB section queues the glyphs; reading `bits` straight afterwards can see the
  black background and no text. `GdiFlush` is what orders the two. This cost a
  debugging session — the plate drew, the text did not.
- **`wsprintfW` is `PROTO C` and clobbers argument registers.** Passing live
  registers as the values produced `300 x 300` for a 400×300 drag — both
  arguments had collapsed onto one. Read the values into locals first, then
  pass the locals.
- **GDI does not manage alpha in a DIB.** Text drawn into a 32bpp DIB leaves the
  glyph pixels' alpha at whatever was there, usually 0, so a premultiplying copy
  would erase the text. The plate is opaque chrome by design, so
  `ovl_blit_opaque` forces alpha 255 on every copied pixel rather than
  multiplying.
- **`SIZE` and `cx` are not usable as MASM names.** `SIZE` is an operator and
  `cx` is a register; the `SIZEW` struct in `win32.inc` uses `_cx`/`_cy`, the
  same convention `CREATESTRUCTW` needed.
- **A layered window is invisible to screen capture, by design.** You cannot
  screenshot the Overlay to check it. Temporarily drop the
  `SetWindowDisplayAffinity` line into a throwaway copy of the exe, or read the
  DIB with the debugger; both were used while building this.
- **The colour key is gone.** The prototype punched its hole with a magenta
  `LWA_COLORKEY`, which also punched any pixel that merely resembled magenta.
  Zeroing alpha has no such fringe.

## See also

- [`docs/select.md`](select.md) — the Selection state machine that drives it.
- [`docs/research/overlay-selection-hit-testing.md`](research/overlay-selection-hit-testing.md)
  — the research this render path comes from.
- [`docs/adr/0001-snip-representation.md`](adr/0001-snip-representation.md) —
  straight versus premultiplied alpha.
- [Ticket 02](../.scratch/asm-snip-build/issues/02-overlay-rectangular-selection.md).
