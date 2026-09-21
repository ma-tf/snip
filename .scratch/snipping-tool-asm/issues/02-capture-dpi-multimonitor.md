# Screen capture, DPI awareness, and multi-monitor on Windows 11

Label: wayfinder:research
Type: research
Status: resolved
Blocked by: none

## Question

What actually happens when a pure Win32 program captures the screen on Windows 11, and what does that force on the design?

Establish: the difference between `BitBlt` from the `CreateDC("DISPLAY")` DC and `PrintWindow` with `PW_RENDERFULLCONTENT` — which one sees DWM-composited, hardware-accelerated, or layered windows (the snipping overlay itself included); how virtual-screen coordinates work (`SM_XVIRTUALSCREEN` and friends) and how they interact with per-monitor DPI; what `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` changes about those coordinates; whether capturing across monitors with different scale factors needs a per-monitor blit; and the known failure modes (black frames, protected content, HDR).

Deliverable: facts written to `docs/research/capture-dpi-multimonitor.md`, with a recommendation for the v1 capture path.

## Answer

Findings: [`docs/research/capture-dpi-multimonitor.md`](../../../docs/research/capture-dpi-multimonitor.md).

**Recommended v1 capture path.** One screen DC (`CreateDC("DISPLAY",NULL,NULL,NULL)` or
`GetDC(NULL)`), one `CreateDIBSection` sized from `SM_CXVIRTUALSCREEN` ×
`SM_CYVIRTUALSCREEN`, and **one** `BitBlt(dst, 0, 0, cx, cy, src, SM_XVIRTUALSCREEN,
SM_YVIRTUALSCREEN, SRCCOPY | CAPTUREBLT)`. That single image serves rectangular,
free-form and full-screen modes (free-form is a mask over it; full-screen mode is it
cropped to a monitor). Window mode adds `PrintWindow(hwnd, memDC, PW_RENDERFULLCONTENT)`
(`0x00000002`) for the chosen top-level HWND, with a screen-blit fallback. The overlay is
a top-level window spanning the virtual screen with
`SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` set so it never lands in the
snip. Mark the process `PerMonitorV2` in the manifest on day one. Deliberately leave DXGI
Desktop Duplication, Windows.Graphics.Capture and Magnification out of v1.

**Biggest DPI/multi-monitor trap.** The screen DC's coordinate space is the *primary
monitor's physical pixels*, not the virtual screen: measured `GetDCOrgEx = (0,0)` and
`GetDeviceCaps(HORZRES) = 3440` (primary width) while `SM_CXVIRTUALSCREEN = 5360`. Sizing
the bitmap from `GetDeviceCaps`/`SM_CXSCREEN` or blitting from source `(0,0)` captures
only the primary monitor and clips or misplaces the rest. Compounding it, a DPI-unaware
process gets its screen metrics virtualised to 96 DPI while the screen DC is still raw
physical pixels, producing a partial, wrongly-sized capture — so PMv2 is a capture
requirement, not just a UI nicety. Rule: **be PMv2, size from `SM_C*VIRTUALSCREEN`, blit
from `SM_X/YVIRTUALSCREEN` (which may be negative; `BitBlt` accepts negative source
coordinates, verified).**

Other facts that shape the design, each with sources in the research file:

- `BitBlt` from the screen DC sees the DWM post-composition desktop, so it includes
  hardware-accelerated and layered windows; `PrintWindow` without `PW_RENDERFULLCONTENT`
  returns black for DirectComposition windows (measured across WinUI, Chromium and
  ApplicationFrameWindow). `PW_RENDERFULLCONTENT` is defined in `winuser.h` for Windows
  8.1+ but is **undocumented** on the PrintWindow reference page.
- `GetWindowRect(GetDesktopWindow())` returns the primary monitor, not the virtual screen.
- Mixed scale factors do **not** require per-monitor blits — the virtual screen is one
  physical-pixel space. Per-monitor work is needed only for monitor metadata, differing
  colour formats, per-output APIs, and overlay UI layout/`WM_DPICHANGED`.
- Black-frame failure modes: exclusive-fullscreen / DirectFlip / MPO surfaces that never
  enter DWM composition, and `DXGI_ERROR_ACCESS_LOST` on such transitions.
- Protected content: `WDA_EXCLUDEFROMCAPTURE` lets any app hide itself, and DRM video is
  blacked out by the OS before it reaches any capture surface.
- HDR: GDI capture is 8-bit SDR with no colour management; only pixel-format-aware APIs
  (Windows.Graphics.Capture, `IDXGIOutputDuplication::DuplicateOutput1`) preserve HDR/WCG.

