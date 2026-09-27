# The Snip and the capture path

How a Selection becomes a Snip, and how the Editor shows it. Follows the template
in [`docs/architecture.md`](architecture.md).

## What it is

The path from "the user let go of the mouse" to "the Editor is on screen showing
the pixels they outlined". Three things happen in order: the Selection's region is
blitted off the screen, it is wrapped as a **Snip** — an owned bitmap with a
Pristine twin — and the Editor is sized to it and painted.

The Snip is the unit the rest of the app is about. The Editor annotates it
(ticket 06), Copy and Save As publish it ([`docs/encode.md`](encode.md)), and
free-form mode cuts its alpha (ticket 07). None of them re-capture; they all
read the Snip.

## Where it lives

| File | Owns |
| --- | --- |
| `src/capture.asm` | `capture_region` — the screen blit — plus `capture_window` and `window_frame` — the `PrintWindow` render and the window frame. |
| `src/dib.asm` | The Snip: allocation, the crop, alpha synthesis, the Pristine twin. |
| `src/editor.asm` | The Editor window: create-once, fit-to-Snip, the paint path. |
| `src/select.asm` | `select_finish` — the order of operations that drives all three, plus the window-mode hover and the full-screen monitor hover. |

`Snip` is declared in `src/snip.inc`; `dib.asm` owns the one live instance and
`editor.asm` reads it through `dib_snip`. The crop maths stays in `geometry.asm`,
which remains Win32-free — `dib.asm` is only the impure DIB plumbing around it.

## How it works

**The Selection is blitted straight into the Snip.** There is no full-screen
capture and no crop pass. `capture_region` reads the Selection's screen
coordinates and does one `BitBlt(dst, 0, 0, w, h, screen, sel.left, sel.top,
SRCCOPY | CAPTUREBLT)` into the Snip's own bitmap. The Rect arrives already in
screen pixels — `select_finish` added the virtual-screen origin once, at the
boundary (see [`docs/multimonitor.md`](multimonitor.md)) — and negative source
coordinates are accepted, so the source rectangle lines up with no arithmetic and
the ~30 MB intermediate a blit-then-crop would hold never exists. That is a
refinement of ADR-0001, not a reversal: a Snip still owns its pixels outright.

**Window mode is a different fill, not a different Snip.** A window snip is the
same owned, opaque, Pristine-twinned Snip as a rectangular one; only the way
Working is filled changes. `capture_window` tries three paths, in order:

1. `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)` — renders the whole top-level
   window, including DirectComposition content. Without the flag a composited
   window comes back as an all-black rectangle.
2. `PrintWindow(hwnd, hdc, 0)` — for the occasional app that answers a plain
   `WM_PRINT` but not the full-content path.
3. A screen blit of the frame rectangle (`capture_region`) — the guaranteed path,
   accepted **even if it is black**.

A `PrintWindow` result counts only if `cap_content` finds a non-zero colour byte;
an all-black bitmap advances to the next path. The final blit is *not* tested: a
black-but-successful capture is a documented limitation, not a detected error. If
every path fails, `capture_window` returns 0 and `dib_build` leaves the previous
Snip intact (ticket 11 surfaces the message).

**`PrintWindow` runs off the UI thread.** It is documented as blocking and runs
the target app's code, so one attempt runs on a `CreateThread` worker that the UI
thread `WaitForSingleObject`s with a 2-second timeout. On a timeout the worker is
`TerminateThread`'d, then waited on until its handle signals — so it is provably
no longer writing the DC — and closed; the second `PrintWindow` variant is *not*
tried, because a target that hangs one hangs both, and the chain goes straight to
the screen blit. That bounds a frozen Overlay at about two seconds.

**The frame excludes the invisible Win11 resize border.** `window_frame` prefers
`DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` and falls back to
`GetWindowRect` for the windows DWM refuses (some popups and layered windows).
`DwmGetWindowAttribute` is resolved from `dwmapi.dll` at runtime, the same
Crinkler-safe pattern `encode.asm` uses for COM, so no import library is added.

**Window and full-screen modes highlight as they move; a click captures.**
`sel_hover` runs on every `WM_MOUSEMOVE`, resolves the top-level window with
`WindowFromPoint` + `GetAncestor(GA_ROOT)`, and reuses the Overlay's existing
hole-punch so the hovered window is the undimmed region — no new Overlay code.
`sel_hover_full` does the same for the monitor under the cursor with
`MonitorFromPoint`. Each repaints only when the resolved window or monitor
changes. The Overlay is flipped `WS_EX_TRANSPARENT` around the window hit-test so
`WindowFromPoint` does not return the Overlay itself. The desktop, the shell
window, the wallpaper host, the taskbars, and minimised windows are rejected, so
the dim holds over them.

**Full-screen mode captures one monitor, never the virtual screen.** The monitor
under the pointer is resolved with `MonitorFromPoint`, and its `rcMonitor`
becomes the Selection. `rcMonitor` is exclusive on `right`/`bottom` while a
`Rect` here is inclusive, so `sel_hover_full` subtracts the one; the crop adds it
back and the Snip is exactly that monitor's physical pixels. A monitor left of
the primary carries a negative origin in `rcMonitor`, so the region blit reads
from the right place — the same "convert once, at the boundary" rule as every
other Selection. A click on a second monitor captures that monitor, not the
5360-pixel-wide desktop.

**The width is inclusive.** A drag from (100,100) to (500,400) is a 401×301
snip, not 400×300. `geo_width`/`geo_height` return the span, and `dib_crop` adds
the 1 for the crop — the `+1` the `geometry.asm` comment reserves for this module.
Getting this the other way loses the Selection's last row and column.

**Alpha is synthesised at build time, then mirrored to the twin.** The screen DC
has no alpha channel, so GDI leaves the alpha byte as it found it, usually 0.
`dib_build` allocates and captures but does not touch alpha; the crop then
synthesises it. A rectangular, window, or full-screen Snip is opaque, so
`dib_fill_opaque` ORs `0FF000000h` into each pixel. A free-form Snip takes
per-pixel **coverage** from `dib_coverage` (ticket 07). Either way `dib_mirror`
then copies Working into Pristine, so the two start byte-identical and Pristine
carries the Snip's true alpha — which is what WIC wants (ticket 05) and what the
Eraser and Undo rely on (ticket 06).

**The crop is atomic.** `dib_crop` builds the new Snip in a stack local and only
frees the previous one once the new one exists. A failed capture therefore leaves
the Editor pointing at the Snip it already had, rather than a freed bitmap — the
"Editor stays open and retryable" requirement ticket 11 will surface with a
message.

**The Editor is created once and reused.** `editor_open` reuses
`App.hwndEditor` if it exists, so the second snip onward only repaints — and
resizes the window to the image, unless the user has resized it by hand (ticket
17). Closing the Editor (`WM_CLOSE`) hides it rather than
destroying it, for the same reason; quitting is the Shell's job.

**The Editor hides during a session.** The topmost Overlay covers it, so the user
never sees it — but the Editor is not excluded from capture, and a Selection
dragged over it would otherwise capture the Editor's own pixels. `select_begin`
hides both windows and `sel_restore` brings both back, with the capture happening
in between while they are still hidden.

**An oversized Snip is fitted, and the Editor is resizable.** Ticket 03 sized the
client to the Snip and clamped it into the monitor work area under
`MonitorFromRect`, which left a Snip bigger than the work area showing only its
top-left corner. Ticket 17 makes the window resizable and draws the Snip scaled
down to fit — whole, never upscaled past 100% — via `GdipDrawImageRectI`. The fit
is a view only: Copy and Save still publish the Snip's own pixels. See
[`docs/editor.md`](editor.md).

**The Editor's size, once the user sets it, is theirs.** The first Snip sizes the
window to the image (capped to the work area); after the user drags the window, a
new Snip changes only the image and leaves the size and position alone.

## Gotchas

- **`w` and `h`, not `width` and `height`.** `width` is a MASM operator, so a
  struct field spelled `width` is a syntax error (A2008). `Snip` uses `w`/`h`,
  the same escape `SIZEW` needed for `cx`.
- **`ch` is a register.** A local named `ch` assembles as the high byte register
  and takes the whole PROC down with `invalid instruction operands`. The
  Editor's locals are `winW`/`winH`/`srcW`/`srcH` for exactly this reason.
- **The Editor's minimum width is the toolbar's, not the OS's.** Ticket 17 makes
  the window resizable and sets `WM_GETMINMAXINFO`'s minimum to
  `ED_TOOLBAR_MINW` plus a strip of image, so the seven buttons never clip. A tiny
  Snip still opens in that wider window with the image centred 1:1.
- **`INVOKE` does not tolerate an undefined local in an argument.** An `if` that
  skips setting a local does not skip its mention in a later `INVOKE`; MASM
  fails with A2070. Initialise locals, or use two call sites.
- **Off-desktop captures are black, not an error.** `BitBlt` accepts source
  coordinates outside the desktop and the off-desktop part reads back black. A
  Selection at a virtual-screen edge is therefore a valid, if partly black, snip.
- **`PrintWindow` can return real, non-black pixels that are still not what is on
  screen.** A WinForms window, for instance, prints as its default face colour
  rather than the colour it shows. The all-black test only rejects a composited
  window's black rectangle; it cannot detect "rendered, but wrong". The screen
  blit stays as the fallback for exactly this reason.
- **`window_frame` returns screen pixels; the Overlay works in client pixels.**
  `select_finish` adds the virtual-screen origin once, the same as for a
  rectangular Selection, so a window snip on a monitor left of the primary lands
  in the right place.
- **`MonitorFromPoint` takes its `POINT` by value.** Declared as two `SDWORD`s,
  exactly like `WindowFromPoint`, so `INVOKE MonitorFromPoint, x, y,
  MONITOR_DEFAULTTONEAREST` pushes the 8 bytes MASM would not otherwise marshal
  from a `POINT` name.
- **`rcMonitor` is exclusive; a `Rect` here is inclusive.** `GetMonitorInfoW`
  reports a monitor's bounds the way `RECT` does — width is `right - left`, not
  the pixel count. `dib_crop` adds the one, so `sel_hover_full` subtracts it
  first. Without the `-1`, a full-screen Snip is a pixel wider and taller than
  the monitor. The same exclusive-vs-inclusive seam exists in `window_frame`
  (ticket 08), where `GetWindowRect`/DWM bounds are used directly; window snips
  are therefore one pixel oversized. Left as a documented follow-up.
- **`window_frame`'s parameter cannot be called `out`.** `out` is a MASM
  instruction (`A2008`), so the parameter is `frame`.
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
- [`docs/editor.md`](editor.md) — the Editor window, its fit, and the mapping.
- [`docs/multimonitor.md`](multimonitor.md) — the coordinate spaces and DPI rules.
- [Ticket 03](../.scratch/asm-snip-build/issues/03-snip-crop-editor-window.md).
