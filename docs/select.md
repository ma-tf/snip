# The Selection

How a Snipping session runs: what raises the Overlay, what tracks the drag, and
what puts the Shell back. Follows the template in
[`docs/architecture.md`](architecture.md).

## What it is

The state machine behind the Overlay's behaviour. It owns the session lifecycle
— from a New click to the Selection being completed or cancelled — and the drag
that produces a rectangular Selection. It is the only module that knows a
session is in flight.

Ticket 02 landed the rectangular Selection; ticket 07 adds free-form, which
traces a path instead of a box and hands the Overlay a different kind of frame.
Ticket 08 added the window gesture and ticket 09 the full-screen one: both
highlight what is under the pointer and capture it on a click, with no drag.

## Where it lives

`src/select.asm`. The live session state (`sel_live`, `sel_down`, the origin and
current points, the Selection so far) is module-private in `.data?`: a session is
a singleton, exactly like the Shell. `sel_wndproc` is the Overlay window's
WndProc — it lives here rather than in `overlay.asm` because the Overlay is a
surface and this is the behaviour that runs on it.

## How it works

**A session is a small state machine.** `select_begin` (New) hides the Shell and the Editor,
waits out the Delay, then raises the Overlay through `overlay_show`. `sel_ldown` anchors the
drag and calls `SetCapture`, so tracking survives the pointer leaving the window. `sel_mmove`
re-normalises the rectangle and repaints. `sel_lup` finishes the session or ignores a stray
click. `select_cancel` ends it with nothing recorded. `select_finish` ends it by cropping the
Selection into a Snip and opening the Editor.

**The Delay is a Sleep between the hide and the raise.** `App.delay` is the Delay drop-down's
index; `select_begin` maps it through a table (No delay / 3 / 5 / 10 seconds) and calls `Sleep`
before `overlay_show`. The wait sits after the hide, so the desktop is clear for the user to
open a menu or arrange hover state, and before the mode dispatch, so it applies to all four
modes. It is a plain `Sleep`, blocking the UI thread: the only windows that thread would serve
are already hidden. See [`docs/delay.md`](delay.md).

**Capture, not hover.** `SetCapture` on mouse-down and `ReleaseCapture` on
release is what makes a drag that runs off the Overlay still track. Without it a
fast drag out of the window would freeze the Selection at the edge.

**The Selection is a rectangle, normalised.** A drag runs in any direction, so
`geo_normalise` writes the bounding box with `left <= right` and `top <= bottom`
regardless of which way the pointer went. That maths is `geometry.asm`'s, which
is Win32-free on purpose — the trickiest part of the module reads on its own.
The rectangle is inclusive: `rcMonitor` is exclusive on `right`/`bottom`, so
full-screen mode subtracts the one there and the crop adds it back.

**One pixel is a Selection; zero is not.** `sel_lup` measures the rectangle and
ignores anything with a width or height of zero or less, so a click that never
drags leaves the Overlay up instead of producing an empty snip. Free-form is the
same bargain with different geometry: the Trace is simplified, and a path that is
too short or too small (`mask_degenerate`) leaves the Overlay up.

**Free-form is a second gesture.** The mode comes from `App.mode`, and each mode
gets its own branch rather than falling through to the rectangle handler.
`sel_ldown` starts the Trace, `sel_mmove` accepts points and repaints the preview,
and `sel_lup` simplifies and crops. `sel_repaint` dispatches: a rectangle goes to
`overlay_repaint`, a Trace to `overlay_repaint_free`.

**Window and full-screen are highlight gestures.** Both capture what is under the
pointer with no drag, so they highlight as the pointer moves and act on a click —
there is no `sel_down` and no `SetCapture`. `sel_hover` resolves the top-level
window under the cursor; `sel_hover_full` resolves the monitor. The highlight is
the Overlay's existing hole-punch: the highlighted rect *is* the Selection, so no
Overlay code was needed for either. Each remembers what it resolved (`sel_hwnd`,
`sel_mon`) and repaints only when that changes, so moving inside one window or
monitor does not re-present the layered frame every message. `sel_ldown` resolves
once more at the click point — the pointer may not have moved since New — then
finishes the session, so these branches return before `SetCapture`.

**Cancellation restores, it does not remember.** `select_cancel` clears the drag
and restores the Shell, and deliberately does *not* record the Selection, so
nothing downstream can pick up a cancelled session. Escape and right-click both
route here.

**The Shell hides for the session and returns with it.** User story 5: our own
window must never sit under the dim or inside the snip. `select_begin` hides the
Shell — and the Editor with it — before raising the Overlay; `sel_restore` shows
both again and gives the Shell focus. The Editor is hidden for a subtler reason
than the Shell: the topmost Overlay covers it, so the user never sees it, but it
is not excluded from capture, so a Selection dragged over it would otherwise
land the Editor's own pixels in the Snip. Between the hide and the restore,
`select_finish` runs the capture, so both our windows are guaranteed absent.

**The dependency runs one way.** `select` calls `overlay_show`,
`overlay_repaint`, and `overlay_hide`. The Overlay never calls back into
`select` except through the WndProc it registered, and never reads `sel_*`.

## Gotchas

- **Read `lParam` into memory before any call.** On x86 `INVOKE` pushes it, so
  the x64 volatile-register trap does not exist here — but parsing the point
  first is the habit that keeps both targets' handlers identical, and it is
  what the ticket 07 prototype got wrong on x64.
- **A per-mode mouse-down path must not fall through to the drag handler.**
  The prototype's bug 2 was exactly this: a click in window mode ran the
  rectangular update and collapsed the snip to `0 x 0`. Each mode gets its own
  branch; all four now do, and the shape is the same for the next one.
- **`sel_live` makes begin and cancel idempotent.** Calling `select_begin` on a
  live session is a no-op, not an error — the Overlay is already up.
- **A failed `overlay_show` restores the Shell.** A session that cannot raise
  the Overlay should cost the user nothing, not leave them with no window at all.
- **`dib_crop` runs before `sel_restore`, never after.** The capture must happen
  while the Shell and Editor are hidden. `dib_crop` is atomic, so a failed
  capture leaves the previous Snip (and the Editor showing it) intact, and
  `select_finish` reports it once the Shell is back (see [`docs/errors.md`](errors.md)).
- **The Selection is virtual-relative until the handoff.** Pointer messages carry
  the Overlay's client coordinates, whose origin is the virtual-screen origin, not
  the desktop's. `select_finish` adds the virtual origin exactly once, so capture
  and the Editor are in screen pixels. See [`docs/multimonitor.md`](multimonitor.md).
- **`WM_DISPLAYCHANGE` aborts a live session.** A monitor added, removed, or
  re-scaled invalidates the rectangle the user is dragging; the session is
  cancelled rather than cropped against a stale virtual screen.
- **`WM_DPICHANGED` is chrome, not geometry.** The Overlay keeps spanning the
  virtual screen; the suggested `lParam` rectangle is ignored. The new DPI is
  recorded and the frame repainted with rescaled chrome.

## See also

- [`docs/overlay.md`](overlay.md) — the surface this drives.
- [`docs/delay.md`](delay.md) — the wait between New and the Overlay.
- [`docs/freeform.md`](freeform.md) — the Trace gesture and the coverage Mask.
- [`docs/multimonitor.md`](multimonitor.md) — coordinate spaces and the topology/DPI rules.
- [`docs/capture.md`](capture.md) — what `select_finish` hands the Selection to.
- [`CONTEXT.md`](../CONTEXT.md) — *Selection*, *Snipping session*, *Overlay*.
- [Ticket 02](../.scratch/asm-snip-build/issues/02-overlay-rectangular-selection.md).
