# Snips are owned, eagerly-cropped, straight-BGRA DIBs with a pristine twin

A capture yields the whole virtual screen, but a Snip is cropped to the Selection immediately and the full-screen buffer freed, so a Snip owns its bitmap outright with no aliasing. Pixels are 32bpp straight (non-premultiplied) BGRA with a meaningful alpha channel — the screen DC supplies none, so alpha is synthesised 255 inside the Selection and 0 outside — because free-form transparency and the Eraser both depend on it, and WIC's `GUID_WICPixelFormat32bppBGRA` accepts it with no conversion. Each Snip also retains a Pristine bitmap alongside its Working bitmap so the Eraser has a truthful source.

## Considered Options

- **Premultiplied alpha** (`32bppPBGRA`) — what GPU compositors prefer, but it imposes a multiplication rule on every blend and hand-off, and nothing here composites on a GPU.
- **Opaque BGR with the alpha byte reserved** — simpler, but free-form snips could not carry transparent surroundings and the Eraser could not punch holes.
- **Keeping the full-screen buffer alive and treating a Snip as a view into it** — would allow re-cropping, which the reference tool does not offer, at the cost of holding roughly 30 MB per session.

## Consequences

The Editor's Working bitmap is byte-identical in format to what WIC wants, so Save As and Copy need no pixel conversion pass. Any future GPU compositing would have to premultiply on the way in, or supersede this ADR.
