# Snip representation and clipboard formats

Label: wayfinder:grilling
Type: grilling
Status: resolved
Blocked by: 02

## Question

What *is* a snip, in memory, and what gets published to the clipboard?

Decide the pixel representation (32bpp top-down `CreateDIBSection` DIB vs something else); the stride, alpha, and premultiplication rules; how the pristine post-capture image is retained so the Eraser can restore from it; how the bitmap flows capture → editor → clipboard → encoder without needless copies; and which clipboard format(s) to publish (`CF_DIB`, `CF_DIBV5`, `CF_BITMAP`, or a PNG stream in a registered `CF_PNG`).

## Answer

A Snip is an **owned, eagerly-cropped, straight-BGRA 32bpp DIB with a Pristine twin**. Recorded as [ADR-0001](../../../docs/adr/0001-snip-representation.md).

- **Pixel format** — 32bpp, straight (non-premultiplied) alpha, BGRA byte order. The screen DC supplies no alpha, so it is synthesised: 255 inside the Selection, 0 outside. That is exactly `GUID_WICPixelFormat32bppBGRA`, so the Working bitmap feeds WIC with no conversion pass.
- **Lifetime** — capture the virtual screen once, crop to the Selection immediately (applying the free-form mask if there is one), then free the full-screen buffer. One owner, one snip-sized allocation, no re-crop — matching the reference tool.
- **Copies** — two snip-sized DIBs: a **Pristine** bitmap never drawn on, and a **Working** bitmap annotations rasterise into. The Eraser restores from Pristine. Whether Undo/Redo keeps its own history stays with [Annotation editor and undo model](08-annotation-editor-undo.md).
- **Ownership** — the Snip owns its DIB outright; nothing aliases it. Copies then land only where unavoidable: zero capture→editor, zero editor→encoder (WIC reads Working in place), and exactly one editor→clipboard, because the clipboard genuinely owns its memory once handed over.
- **Clipboard** — publish `CF_DIBV5` (alpha preserved), then the registered `PNG` format (OLE stream bytes into a `GMEM_MOVEABLE` handle, per the encoding research), then `CF_DIB` as an opaque fallback. No `CF_BITMAP`: it would add GDI handle-lifetime rules for receivers that already take `CF_DIB`.

Unblocks [Annotation editor and undo model](08-annotation-editor-undo.md) and [Free-form mask and clipping](09-freeform-mask-clipping.md).
