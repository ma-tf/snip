# The Snip and the capture path

How a Selection becomes a Snip, and how the Editor shows it. Follows the template
in [`docs/architecture.md`](architecture.md).

## What it is

The path from "the user let go of the mouse" to "the Editor is on screen showing
the pixels they outlined". Three things happen in order: the Selection's region is
blitted off the screen, it is wrapped as a **Snip** — an owned bitmap with a
Pristine twin — and the Editor is sized to it and painted.

The Snip is the unit the rest of the app is about. The Editor annotates it
(ticket 06), Copy and Save As publish it (ticket 05), and free-form mode will cut
its alpha (ticket 07). None of them re-capture; they all read the Snip.

## Where it lives

| File | Owns |
| --- | --- |
| `src/capture.asm` | `capture_region` — the screen blit. No state between calls. |
| `src/dib.asm` | The Snip: allocation, the crop, alpha synthesis, the Pristine twin. |
| `src/editor.asm` | The Editor window: create-once, fit-to-Snip, the paint path. |
| `src/select.asm` | `select_finish` — the order of operations that drives all three. |

`Snip` is declared in `src/snip.inc`; `dib.asm` owns the one live instance and
`editor.asm` reads it through `dib_snip`. The crop maths stays in `geometry.asm`,
which remains Win32-free — `dib.asm` is only the impure DIB plumbing around it.

## How it works

**The Selection is blitted straight into the Snip.** There is no full-screen
capture and no crop pass. `capture_screen` reads the Selection's screen
coordinates and does one `BitBlt(dst, 0, 0, w, h, screen, sel.left, sel.top,
SRCCOPY | CAPTUREBLT)` into the Snip's own bitmap. Virtual-screen pixels *are*
screen-DC coordinates — negative origins included — so the two line up with no
arithmetic, and the ~30 MB intermediate a blit-then-crop would hold never exists.
That is a refinement of ADR-0001, not a reversal: a Snip still owns its pixels
outright.

**The width is inclusive.** A drag from (100,100) to (500,400) is a 401×301
snip, not 400×300. `geo_width`/`geo_height` return the span, and `dib_crop` adds
the 1 for the crop — the `+1` the `geometry.asm` comment reserves for this module.
Getting this the other way loses the Selection's last row and column.

**Alpha is synthesised in the same pass as the twin.** The screen DC has no alpha
channel, so GDI leaves the alpha byte as it found it, usually 0. `dib_alloc`
walks the pixels once, ORs `0FF000000h` into each, and writes the result to
*both* Working and Pristine. So a fresh Snip is straight (non-premultiplied) BGRA
with alpha 255 everywhere, and the two bitmaps start byte-identical — which is
what WIC wants (ticket 05) and what free-form and the Eraser will rely on
(tickets 06/07).

**The crop is atomic.** `dib_crop` builds the new Snip in a stack local and only
frees the previous one once the new one exists. A failed capture therefore leaves
the Editor pointing at the Snip it already had, rather than a freed bitmap — the
"Editor stays open and retryable" requirement ticket 11 will surface with a
message.

**The Editor is created once and reused.** `editor_open` reuses
`App.hwndEditor` if it exists, so the second snip onward only resizes and
repaints — no window churn. Closing the Editor (`WM_CLOSE`) hides it rather than
destroying it, for the same reason; quitting is the Shell's job.

**The Editor hides during a session.** The topmost Overlay covers it, so the user
never sees it — but the Editor is not excluded from capture, and a Selection
dragged over it would otherwise capture the Editor's own pixels. `select_begin`
hides both windows and `sel_restore` brings both back, with the capture happening
in between while they are still hidden.

**A Snip bigger than the work area is capped, not scaled.** With no zoom yet
(ticket 17), the Editor sizes its client to the Snip but clamps it into the
monitor work area under `MonitorFromRect`; the paint `BitBlt` clips, so the
top-left corner shows. Scaling would misrepresent what Copy will publish.

## Gotchas

- **`w` and `h`, not `width` and `height`.** `width` is a MASM operator, so a
  struct field spelled `width` is a syntax error (A2008). `Snip` uses `w`/`h`,
  the same escape `SIZEW` needed for `cx`.
- **`ch` is a register.** A local named `ch` assembles as the high byte register
  and takes the whole PROC down with `invalid instruction operands`. The
  Editor's locals are `winW`/`winH`/`srcW`/`srcH` for exactly this reason.
- **The Editor's minimum width is the OS's, not yours.** Windows will not make a
  captioned window narrower than the system minimum (~120 px client here), so a
  tiny Snip produces a slightly wider window than the Snip's width. Harmless —
  the paint clips — but it makes a naive "client == Snip size" check fail.
- **`INVOKE` does not tolerate an undefined local in an argument.** An `if` that
  skips setting a local does not skip its mention in a later `INVOKE`; MASM
  fails with A2070. Initialise locals, or use two call sites.
- **Off-desktop captures are black, not an error.** `BitBlt` accepts source
  coordinates outside the desktop and the off-desktop part reads back black. A
  Selection at a virtual-screen edge is therefore a valid, if partly black, snip.
- **The Overlay is not in the snip only because it excludes itself.** If that
  `SetWindowDisplayAffinity` call is ever removed, the dim appears in every snip.
  See [`docs/overlay.md`](overlay.md).

## See also

- [`CONTEXT.md`](../CONTEXT.md) — *Snip*, *Pristine bitmap*, *Working bitmap*,
  *Snipping session*.
- [`docs/adr/0001-snip-representation.md`](adr/0001-snip-representation.md) — why
  straight BGRA, and where the direct region blit refines it.
- [`docs/research/capture-dpi-multimonitor.md`](research/capture-dpi-multimonitor.md)
  — the capture and DPI research this path follows.
- [`docs/select.md`](select.md) — the session lifecycle that calls in here.
- [Ticket 03](../.scratch/asm-snip-build/issues/03-snip-crop-editor-window.md).
