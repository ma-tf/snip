# The Editor view

How the Editor window is sized and how the Snip is placed inside it. Follows the
template in [`docs/architecture.md`](architecture.md).

## What it is

The window that shows a Snip and hosts the annotation tools, and the one mapping
between two coordinate spaces: **client pixels** (the window) and **Snip pixels**
(the image). The window is resizable, and a Snip larger than its image area is
**fitted** — scaled down so the whole image is visible — rather than clipped to a
top-left corner. A Snip that fits is drawn 1:1 and never upscaled.

The fit is a **view**, not a change to the Snip. Copy and Save As always publish
the Snip's own pixels at full resolution; the scale only affects what is on screen
and where a mouse maps to.

## Where it lives

| File | Owns |
| --- | --- |
| `src/editor.asm` | The window, the toolbar, the **fit** (`editor_view`), and the client→Snip mapping (`editor_map`). |
| `src/ink.asm` | The annotation log. Its strokes are in Snip pixels; only its live **preview** is scaled into the view. |
| `src/dib.asm` | The Snip bitmap the Editor draws; `editor.asm` reads it through `dib_snip`. |
| `src/win32.inc` | The window styles and messages, and `GdipDrawImageRectI`. |
| `src/snip.inc` | The `ink_preview` seam, which carries the view. |

`editor_view` is the single home for the fit maths, so paint, input, and the
preview cannot disagree about where the image is.

## How it works

**One scale, capped at 100%, centred.** `editor_view` reads the client size and the
Snip, and computes the smaller of the two axis ratios, capped at 1 so a Snip that
fits is never upscaled. The image is centred in the image area (the client less the
32-pixel toolbar), and the result is cached in `ed_vx/vy/vw/vh` with the Snip's own
size in `ed_sw/sh`. It is recomputed on demand rather than cached across events: the
view depends on both the client size and the live Snip, and both change without a
single event to hook — a new Snip arrives through `editor_fit`, a resize through
`WM_SIZE`.

**An oversized Snip is drawn into the view rect.** `editor_do_paint` uses
`GdipDrawImageRectI(gfx, bmp, ed_vx, ed_vy, ed_vw, ed_vh)` and sets a high-quality
bicubic filter when it is scaling down. This keeps GDI+'s alpha handling, so a
free-form cut still shows its shape. The letterbox around a small image is the
existing backdrop fill.

**The window is resizable, with a floor.** `ED_STYLE` carries
`WS_THICKFRAME | WS_MAXIMIZEBOX`; `WM_GETMINMAXINFO` asks `DefWindowProc` for the
normal limits and then raises the minimum to the toolbar width plus a strip of
image, so the window cannot be dragged into a state where the toolbar clips.

**The user's size wins.** The first Snip still sizes the window to the image,
capped to the work area (ticket 03). Once the user has dragged the window,
`ed_userSized` latches and `editor_fit` becomes a no-op: a later Snip — larger or
smaller — changes only the image, which the fit rescales. `editor_fit`'s own
`MoveWindow` is guarded by `ed_fitting`, and create-time sizing by `ed_fitted`, so
neither is mistaken for a user resize.

**The mouse maps through the same fit.** `editor_map` turns a client point into
Snip pixels with `MulDiv` against `ed_vx/vy/vw/vh` and `ed_sw/sh`, and clamps to the
image. It returns whether the point was actually inside: a press in the letterbox
is ignored, while a drag that leaves the image still extends to its edge. The ink
layer is unchanged — it still receives Snip pixels.

**The live preview is scaled too.** While a stroke is in progress, `ink_preview`
draws it onto the paint DC at the same scale, scaling the copied points *and* the
pen width. Without the width scale, a translucent Highlighter would look too thick
while drawing and then thin once committed.

## Gotchas

- **The whole client is double-buffered, and the toolbar children are clipped
  out.** A stroke drag invalidates the whole client on every mouse move, so
  `editor_do_paint` draws into a cached client-sized backbuffer (`editor_buffer`)
  and presents it with one `BitBlt`. Painting the toolbar, backdrop, image, and
  live preview straight to the window would show intermediate frames — the
  flicker the Overlay's present-once discipline already avoids. `WS_CLIPCHILDREN`
  keeps the parent off the seven toolbar buttons, which would otherwise flash as
  the toolbar strip is refilled each frame. The buffer is rebuilt only when the
  client size changes; if it cannot be built, paint falls back to the window DC
  directly so ink still works.
- **`ch` is a register.** A local named `ch` is a syntax error; the client height
  local is not spelled that way for exactly this reason (the same trap `docs/capture.md`
  records for the toolbar maths).
- **`editor_map`'s return is the inside/outside bit, not success.** Both the
  clamped coordinate and the flag come out; `ew_down` rejects on 0, `ew_move`
  ignores it so a drag off the image clamps to the edge.
- **Never upscale.** A small Snip in a large window stays 1:1 and centred; the
  extra space is letterbox. Upscaling would misrepresent the pixels Copy publishes.
- **Copy and Save read the Snip, not the view.** The scale is display-only, so a
  fitted 50% view still writes the full-resolution PNG.
- **There is no pan.** Fit-to-window is the only scale until wheel zoom lands
  (ticket 17's deferred half), so an image is either whole-and-scaled or, once
  zoomed, centred with the edges out of reach. That is the spec's bargain.
- **The minimum width is the toolbar's, not a taste call.** The seven buttons do
  not reflow; `ED_TOOLBAR_MINW` is what `WM_GETMINMAXINFO` enforces.

## See also

- [`docs/capture.md`](capture.md) — the Snip, its Pristine twin, and the Editor's creation.
- [`docs/ink.md`](ink.md) — the annotation model the mouse feeds.
- [`docs/keyboard.md`](keyboard.md) — Tab traversal and the Copy, Save, and Undo shortcuts.
- [`docs/multimonitor.md`](multimonitor.md) — the work-area clamp and DPI.
- [`CONTEXT.md`](../CONTEXT.md) — Snip, Working bitmap, Annotation.
- [Ticket 17](../.scratch/asm-snip-build/issues/17-editor-zoom.md) — resize, fit, and the deferred zoom.
