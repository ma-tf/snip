# Screen capture, DPI awareness, and multi-monitor on Windows 11

Label: wayfinder:research
Type: research
Status: open
Blocked by: none

## Question

What actually happens when a pure Win32 program captures the screen on Windows 11, and what does that force on the design?

Establish: the difference between `BitBlt` from the `CreateDC("DISPLAY")` DC and `PrintWindow` with `PW_RENDERFULLCONTENT` — which one sees DWM-composited, hardware-accelerated, or layered windows (the snipping overlay itself included); how virtual-screen coordinates work (`SM_XVIRTUALSCREEN` and friends) and how they interact with per-monitor DPI; what `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` changes about those coordinates; whether capturing across monitors with different scale factors needs a per-monitor blit; and the known failure modes (black frames, protected content, HDR).

Deliverable: facts written to `docs/research/capture-dpi-multimonitor.md`, with a recommendation for the v1 capture path.
