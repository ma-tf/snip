# Snips are owned, eagerly-cropped, straight-BGRA DIBs with a pristine twin

A capture yields the whole virtual screen, but a Snip is cropped to the Selection immediately and the full-screen buffer freed, so a Snip owns its bitmap outright with no aliasing. Pixels are 32bpp straight (non-premultiplied) BGRA with a meaningful alpha channel — the screen DC supplies none, so alpha is synthesised 255 inside the Selection and 0 outside — because free-form transparency and the Eraser both depend on it, and WIC's `GUID_WICPixelFormat32bppBGRA` accepts it with no conversion. Each Snip also retains a Pristine bitmap alongside its Working bitmap so the Eraser has a truthful source.

## Considered Options

- **Premultiplied alpha** (`32bppPBGRA`) — what GPU compositors prefer, but it imposes a multiplication rule on every blend and hand-off, and nothing here composites on a GPU.
- **Opaque BGR with the alpha byte reserved** — simpler, but free-form snips could not carry transparent surroundings and the Eraser could not punch holes.
- **Keeping the full-screen buffer alive and treating a Snip as a view into it** — would allow re-cropping, which the reference tool does not offer, at the cost of holding roughly 30 MB per session.

## Consequences

The Editor's Working bitmap is byte-identical in format to what WIC wants, so Save As and Copy need no pixel conversion pass. Any future GPU compositing would have to premultiply on the way in, or supersede this ADR.

## Amendment — the crop is a direct region blit

Ticket 03 refined "a capture yields the whole virtual screen, but a Snip is cropped to the Selection immediately". No full-screen buffer is ever allocated: `capture.asm` blits the Selection's region **straight into the Snip's bitmap** with one `BitBlt` from the screen DC, because a Selection's screen coordinates are already valid source coordinates (negative origin included, off-desktop parts reading black). The Snip still owns its pixels outright and is still eagerly cropped; the ~30 MB intermediate and a second full-frame pass are simply gone. Window mode (ticket 08) will still `PrintWindow` into the Snip's bitmap rather than capture-then-crop.

## Amendment — free-form cuts

For free-form snips, "alpha 255 inside the Selection, 0 outside" is refined to per-pixel **coverage**: fully opaque inside the Trace, absent outside, partially transparent along the cut, which is filled antialiased with GDI+ (`GraphicsPath` + `FillPath`). Rectangular, window and full-screen snips stay binary. The straight-BGRA rule is unchanged — only the alpha values differ.
