# DPI and multi-monitor

How `snip.exe` copes with a desktop that is bigger than one monitor and whose
monitors do not all scale the same. Follows the template in
[`docs/architecture.md`](architecture.md).

## What it is

The rules that keep a Snip the pixels the user saw when the desktop is not a
single 96-DPI monitor at (0,0): which coordinate space a Selection is in, when
the virtual screen is re-read, what happens if the desktop changes mid-snip, and
how the Overlay's chrome follows the effective DPI.

The capture itself is indifferent to scale. The virtual screen is one physical
pixel space, so a single region blit returns each monitor at its native
resolution; mixed scale factors are a UI problem, not a capture problem.

## Where it lives

| Module | Concern |
| --- | --- |
| `src/select.asm` | The virtual origin is read at session start and applied once at the handoff; `WM_DISPLAYCHANGE` aborts a live session; `WM_DPICHANGED` re-lays-out the chrome. |
| `src/overlay.asm` | The `SM_*VIRTUALSCREEN` window and DIB, re-read every show; DPI-scaled readout chrome. |
| `src/capture.asm` | The region blit, in screen pixels. |
| `src/editor.asm` | Places the Editor on the Snip's monitor and clamps it to that monitor's work area. |

Process-wide, `snip.asm` declares per-monitor DPI awareness v2 before any window
exists, so everything downstream inherits it.

## How it works

**Two coordinate spaces, converted once.** *Screen* pixels are the desktop's own
space: primary monitor top-left is (0,0), and a monitor to the left of or above
the primary gives negative coordinates. *Virtual-relative* pixels have their
origin at `SM_X/YVIRTUALSCREEN` — which is exactly the Overlay's client origin,
because the Overlay window is positioned there. The drag arrives as client
coordinates, so a Selection is virtual-relative, and that is what the
`Rect` convention means and what the Overlay draws against. Only the
session→Snip boundary converts: `select_finish` adds the virtual origin to the
rectangle, once, before `dib_crop`. Capture, the Snip's origin, and the Editor
are then all in screen pixels. The research calls this "convert once, at the
boundary".

**Geometry is read, never cached.** `overlay_show` reads
`SM_X/Y/CXVIRTUALSCREEN/CYVIRTUALSCREEN` on every session, and sizes and positions
the window from them. The presentation DIB is rebuilt lazily when the size no
longer matches (`ovl_ensure_dib`). Nothing reads the desktop once at startup and
trusts it forever.

**A topology change aborts a live session.** `WM_DISPLAYCHANGE` reaches the
Overlay mid-drag, and `sel_wndproc` cancels: the Overlay hides, the Shell
returns, and no Snip is recorded. A Selection made against the old virtual
screen would otherwise be cropped from the wrong place or clipped. The research's
safe responses are abort or re-capture; aborting costs the user one drag and
cannot produce a wrong Snip.

**The Overlay's chrome follows the effective DPI.** The Overlay spans the whole
virtual screen, so it has one effective DPI at a time — that of the monitor it is
mainly on. `overlay_show` reads it with `GetDpiForWindow`; `WM_DPICHANGED` pushes
a new value through `overlay_set_dpi`. The readout plate's corner offset, box
size, text insets, and font are all scaled by `MulDiv(x, dpi, 96)`
(`CreateFontW` at 9 pt scaled). The suggested window rectangle in
`WM_DPICHANGED`'s `lParam` is deliberately ignored: the Overlay must keep
spanning the virtual screen, not shrink to one monitor. The Selection outline
stays exactly one physical pixel — it marks a pixel boundary, so scaling it
would be a lie.

**Negative origins are normal.** `capture_region` passes the Selection's screen
coordinates straight to `BitBlt`, which accepts negative source coordinates; the
part off the desktop reads back black. The `Editor` is placed with
`MonitorFromRect` on the Snip's screen rectangle, so it opens on the right
monitor even when that monitor's origin is negative.

## Gotchas

- **The screen DC is anchored on the primary monitor.** `GetDeviceCaps(HORZRES)`
  and `GetWindowRect(GetDesktopWindow())` report the primary monitor, not the
  virtual screen. Size and position from `SM_*VIRTUALSCREEN` only.
- **Client coordinates are not screen coordinates.** This was the ticket 04 bug:
  the Overlay's client origin is the virtual-screen origin, so on a monitor left
  of the primary every drag was blitted from the wrong place. `select_finish`
  is the single conversion point.
- **Do not apply `WM_DPICHANGED`'s suggested rect to the Overlay.** It is a
  normal-window suggestion; taking it would collapse the Overlay onto one monitor.
- **`GetSystemMetrics` is not DPI aware — but be PMv2 anyway.** From a PMv2 thread
  the virtual-screen metrics are the true physical bounding box. A DPI-unaware
  process would get virtualised 96-DPI numbers while the screen DC still returns
  physical pixels, producing a clipped capture.
- **16-bit coordinates.** Window messages carry coordinates in 16 bits, which is
  why the desktop bounds are constrained to signed 16-bit range; nothing here
  needs more.

## See also

- [`docs/capture.md`](capture.md) — the region blit and the Snip.
- [`docs/select.md`](select.md) — the session and the handoff.
- [`docs/overlay.md`](overlay.md) — the surface and its chrome.
- [`docs/research/capture-dpi-multimonitor.md`](research/capture-dpi-multimonitor.md)
  — the measurements this follows.
- [`docs/adr/0002-x86-for-crinkler.md`](adr/0002-x86-for-crinkler.md) — the target.
- [Ticket 04](../.scratch/asm-snip-build/issues/04-multimonitor-dpi-hardening.md).
