# Free-form snips

How a hand-traced Trace becomes a cut-out Snip with an antialiased edge.
Follows the template in [`docs/architecture.md`](architecture.md).

## What it is

The fourth snip mode. The user draws a lasso on the Overlay; on release the path
is simplified, and the resulting Mask cuts the captured region so that the Snip
keeps only what the loop enclosed, with a soft edge. It is the one mode whose
Snip is not a plain rectangle of opaque pixels.

Two halves, split by purity:

- **The Trace** — the path geometry. Sampling, simplification, the bounding box,
  and the degenerate test. No Win32, no GDI+, no pixels.
- **The Mask** — the per-pixel alpha that cuts the Snip. GDI+ `GraphicsPath` +
  `FillPath`, applied to the Snip's alpha by the module that owns its pixels.

## Where it lives

| File | Owns |
| --- | --- |
| `src/mask.asm` | The Trace: one fixed point buffer and its pure geometry. |
| `src/dib.asm` | `dib_crop_free` and `dib_coverage` — the Mask and the Snip's alpha. |
| `src/select.asm` | The free-form drag and the session handoff. |
| `src/overlay.asm` | The live antialiased Trace preview. |
| `src/editor.asm` | Alpha-aware painting, so the cut shows its shape. |

`mask.asm` includes only `snip.inc`; it can be reasoned about — and diffed —
without Win32 in the way. The point buffer is 8192 `Pt` in `.data?`: a fixed
buffer, no allocation, no file bytes.

## How it works

**Sampling accepts a point only after real movement.** `mask_add` compares the
pointer to the last accepted point and rejects anything nearer than ~3px,
DPI-scaled, so a slow hand does not fill the buffer with near-collinear points.
The first point is always accepted and seeds the bbox. When the buffer fills, the
Trace stops accepting rather than dropping or overwriting, so the path stays
valid.

**RDP simplifies after release, in place.** `mask_simplify` runs
Ramer–Douglas–Peucker at ε = 1px over the accepted points and compacts the kept
ones to the front of the same buffer. It is iterative, with an explicit index
stack: a hand trace can be thousands of points deep and recursion is not worth
the risk. The perpendicular-distance test uses a 64-bit cross product, because
the endpoints of a range can span the whole virtual screen.

**The bbox is inclusive and comes from the raw points.** It is tracked during
the drag, so it is there for the live readout and it always contains the
simplified path — no vertex can be clipped, and no epsilon or antialias padding
is needed. `right-left+1` is the pixel width.

**A degenerate Trace makes no Snip.** Fewer than 3 simplified points, or a bbox
under 2×2px, leaves the Overlay up; `dib_crop_free` is never reached.

**The Mask is coverage, filled with winding.** `dib_coverage` builds a
`GraphicsPath` from the simplified, bbox-local points and fills it with
`SmoothingModeAntiAlias` onto a zeroed scratch bitmap. The scratch's alpha
channel *is* the coverage, and is copied into the Snip's alpha; the captured
colour is untouched. `FillModeWinding` (not even-odd) means a rough loop that
crosses itself fills the overlap instead of punching a transparent pocket.

**The scratch comes from `GdipCreateBitmapFromScan0`, not an HDC.** GDI+ leaves
the alpha channel of a DIB surface unusable when drawing through a device
context (see [`docs/ink.md`](ink.md)); here the alpha is the entire output. A
`GdipBitmap` wrapped in `PixelFormat32bppARGB` over the DIB's own memory is what
makes the coverage reliable.

**The Overlay previews the cut.** The live Trace is stroked antialiased into a
small transparent scratch — a dark halo under a light core, so it reads on any
wallpaper — and composited into the Overlay's premultiplied DIB with source-over.
The same scratch bitmap route is used, for the same reason: the preview then
matches the edge the cut will have.

**The Editor paints with alpha.** `editor_do_paint` fills the area below the
toolbar with a backdrop and draws the Snip through `GdipDrawImageI`, whose image
path honours alpha. A `BitBlt` would paint a free-form cut as a full rectangle.
A rectangular Snip is opaque, so its draw is unchanged.

**Annotations preserve the Mask.** `ink_alpha` repairs Working's alpha after
GDI+ drawing by copying it from Pristine rather than forcing 255. Pristine
carries the Snip's true alpha — opaque for a rectangle, the coverage mask for a
free-form cut — so a Pen stroke no longer erases the cut.

**Order at the handoff.** `sel_lup` simplifies, takes the bbox, and tests for
degenerate. `select_finish` translates the Trace and bbox to screen pixels,
`dib_crop_free` builds the Snip over the bbox, captures the region, fills the
Mask, and mirrors Working into Pristine. The scratch is freed immediately; no
pooling.

## Gotchas

- **The path is consumed in place.** `dib_coverage` subtracts the bbox origin
  from the mask's points so GDI+ fills in the scratch's own space. The mask is
  the last consumer of that buffer, so mutating it is safe — but do not call
  `mask_points` after `dib_crop_free` and expect screen coordinates.
- **`Pt` and `GpPoint` are the same 8 bytes.** Two signed 32-bit ints. The mask
  buffer is handed straight to `GdipAddPathPolygonI`; that is a coupling worth
  keeping in mind if `Pt` ever grows.
- **`GdipAddPathPolygonI` closes the figure.** The trace is an open polyline
  from press to release; the polygon call closes it back to the start, which is
  what makes the lasso a loop.
- **The cut is a subset, never an overdraft.** RDP only removes points, and a
  full simplification stack drops a sub-range through its endpoints. Both keep
  the path inside the raw bbox, which is why no padding is needed.
- **A capture buffer is still just the bbox.** Unlike a rectangular snip, only
  the region the loop enclosed is ever copied out of the screen; the Snip is
  bbox-sized, not full-screen.
- **The Overlay is invisible to screen capture.** You cannot screenshot the
  Trace preview to check it; run the app, or read the DIB under the debugger.

## See also

- [`docs/overlay.md`](overlay.md) — the surface the Trace is drawn on.
- [`docs/select.md`](select.md) — the session and the drag state machine.
- [`docs/capture.md`](capture.md) — the Snip and its alpha synthesis.
- [`docs/ink.md`](ink.md) — why GDI+ alpha needs restoring, and where.
- [`docs/adr/0001-snip-representation.md`](adr/0001-snip-representation.md) —
  straight BGRA and the coverage refinement.
- [Ticket 07](../.scratch/asm-snip-build/issues/07-freeform-snip.md).
