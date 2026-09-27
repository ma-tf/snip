# Ink: the annotation model and the command log

How the Editor's Pen, Highlighter, Eraser, and Undo work. Follows the template in
[`docs/architecture.md`](architecture.md).

## What it is

The annotation engine behind the Editor's four ink tools. A **Stroke** is one
press-to-release mark made with the Pen or the Highlighter; the **Eraser** removes
whole strokes; **Undo** reverses the last operation, about ten deep, and stops at
the pristine Snip. There is **no Redo** and **no annotation layer the user can
move** — this is markup, not object editing.

The model is a **command log**, not baked pixels. Nothing is ever drawn on the
Pristine bitmap; the log is replayed onto the Working bitmap to rebuild what the
Editor shows. That is what lets the Eraser remove a stroke without touching the
captured pixels and Undo walk back to the pristine image. The vocabulary is
[`CONTEXT.md`](../CONTEXT.md)'s: Annotation, Stroke, Pristine bitmap, Working
bitmap.

## Where it lives

| File | Owns |
| --- | --- |
| `src/ink.asm` | The command log, the strokes, the GDI+ drawing, the Eraser hit-test, and Undo. Impure by nature; owns no window. |
| `src/editor.asm` | The Editor window, the toolbar, the mouse, and the mapping from client pixels to Snip pixels. |
| `src/win32.inc` | The gdiplus bindings, the `GdiplusStartupInput` layout, and the GDI+ enum constants. |
| `src/snip.inc` | The `ink_*` interface and the tool constants (`INK_PEN`, `INK_HILITE`, `INK_ERASER`). |
| `src/dib.asm` | The Pristine and Working bitmaps the log replays onto; `ink.asm` reads them through `dib_snip`. |

`ink.asm` is the deep module: `editor.asm` knows about mouse messages and button
IDs, `ink.asm` knows about strokes and pixels, and the seam between them is nine
functions and three constants. Replay is the single definition of what the Snip
looks like now.

## How it works

**A stroke is points, not pixels.** `ink_start(tool, x, y, dpi)` opens a stroke in
a fixed arena; `ink_extend` appends the pointer once it has moved a few pixels
(DPI-scaled, so a slow drag does not hoard a point per pixel); `ink_end` commits.
Points are stored in the Snip's own pixel space — the Editor client less the
toolbar — so a stroke replays identically and never needs re-converting.

**Drawing is GDI+.** A stroke becomes one `GdipDrawLinesI` call with a round-capped,
round-joined pen. GDI+ is the only antialiasing GDI cannot provide, which is why it
is in the build at all. Colours and widths are fixed presets, and widths scale with
the Editor's DPI:

| Tool | Colour | Width at 96 DPI |
| --- | --- | --- |
| Pen | opaque blue, RGB(0,90,200) | 3 px |
| Highlighter | yellow RGB(255,242,0) at alpha 0x66 | 16 px |

The Highlighter is *translucent*: GDI+ source-over blends it with the pixels
beneath, so what is highlighted still reads through. The Eraser is not drawn with
at all — it tests the pointer against the log.

**The log is a list of operations, not a bitmap stack.**

```
Stroke { tool, color, width, first, n, state }   ; state 0 == live
Op     { kind, idx, id }                         ; kind: OP_STROKE or OP_ERASE
```

Every stroke has a unique creating op id. An Eraser pass tags each stroke it
removes with *its* op id, so removing several strokes in one drag is one Undo step.
Undo pops the last op: undoing a stroke tags it as removed; undoing an Eraser pass
clears every stroke carrying that op's id. LIFO order keeps the tags coherent, so
there is never ambiguity about who removed what — and because ids are monotonic,
an old tag can never collide with a new operation. The stack holds ten ops; the
oldest falls off, so Undo depth is bounded and eventually reaches the pristine
Snip and stops.

**Replay is the one path.** `ink_replay` copies Pristine into Working, draws every
live stroke with GDI+, and repairs the alpha channel. Undo and Erase are both
"change the log, then replay". `ink_end` is the one shortcut: a freshly committed
stroke is drawn straight into Working, because everything else is already there.

**The in-progress stroke is a preview, not Working.** While the mouse is down,
Working still holds only committed ink and `ink_preview` draws the live stroke onto
the paint DC after the Editor's `BitBlt`. Redrawing the whole stroke each frame is
what keeps a translucent Highlighter from double-blending at its own overlaps; if
it were drawn into Working incrementally, every frame would darken the last.

## Gotchas

- **GDI+ ruins the alpha channel of a DIB surface.** Drawing through an HDC leaves
  the destination's alpha unusable. A rectangular Snip is fully opaque, so after
  every drawing pass `ink_alpha` forces the alpha byte back to 255 — the invariant
  WIC relies on. A free-form Snip (ticket 07) has real coverage alpha and will need
  a scratch ink layer instead of drawing into Working directly.
- **`GdiplusShutdown` never runs.** `WinMainASM` ends in `ExitProcess`, so the
  process reclaims GDI+ without an explicit teardown. Harmless, and noted so it is
  not mistaken for a leak.
- **A REAL pen width is a float.** `GdipCreatePen1` takes the width as a `REAL`, so
  `ink_wbits` is the one place an integer pixel width becomes its 32-bit float
  pattern (`fild` / `fstp`); the binding declares that argument as a `DWORD` for
  exactly this reason.
- **`width` is a MASM keyword.** The `Stroke` field is `w`. Writing `width` in a
  structure is a syntax error.
- **A click is a dot.** A one-point stroke is doubled before `GdipDrawLinesI`, so the
  round cap paints a dot rather than nothing.
- **The arena is fixed and append-only.** 256 strokes and 65,536 points across a
  session, with 4,096 points to a stroke; when it fills, ink simply stops being
  accepted. The same fixed-buffer bargain the free-form Trace makes (ticket 07).
- **The buttons show the active tool, they do not gate it.** The three tool buttons
  are stock push buttons; `BM_SETSTATE` gives the chosen one its pressed look. There
  is no owner-draw chrome.

## See also

- [`docs/architecture.md`](architecture.md) — the explainer template, the module layout, and the segment conventions.
- [`docs/capture.md`](capture.md) — the Snip, its Pristine twin, and the Working bitmap.
- [`docs/encode.md`](encode.md) — Copy and Save, which publish the annotated Working bitmap unchanged.
- [`CONTEXT.md`](../CONTEXT.md) — Annotation, Stroke, Pristine bitmap, Working bitmap.
- [`docs/research/classic-snipping-tool-editor.md`](research/classic-snipping-tool-editor.md) — what the reference editor's tools do.
- [Ticket 06](../.scratch/asm-snip-build/issues/06-pen-highlighter-eraser-undo.md).
