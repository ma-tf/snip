# Screen capture, DPI awareness, and multi-monitor on Windows 11

Research for ticket [02](../.scratch/snipping-tool-asm/issues/02-capture-dpi-multimonitor.md)
(`.scratch/snipping-tool-asm/issues/02-capture-dpi-multimonitor.md`).

Scope: what a pure Win32 (MASM64) program can rely on when it captures the screen on
Windows 11 build 26200 / AMD64, and what that forces on the design of the four snip
modes, the virtual-screen overlay, and per-monitor DPI awareness v2.

Claims below are backed either by Microsoft documentation (linked) or by measurements
run on the dev machine; measurements are labelled **[measured]** and the method and raw
results are in [Measurement](#measurement-what-was-run-on-the-dev-machine).

---

## TL;DR

- **v1 capture path**: one `CreateDC("DISPLAY", NULL, NULL, NULL)` (or `GetDC(NULL)`),
  one `CreateCompatibleDC`/`CreateCompatibleBitmap` (better: `CreateDIBSection`) sized
  `SM_CXVIRTUALSCREEN` × `SM_CYVIRTUALSCREEN`, and **one** `BitBlt` from source
  `(SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN)` with `SRCCOPY | CAPTUREBLT`. That is the whole
  rectangular / free-form / full-screen path. Window mode adds
  `PrintWindow(hwnd, memDC, PW_RENDERFULLCONTENT)`.
- **The screen DC is not the virtual screen.** Its origin is the primary monitor's
  top-left `(0,0)` and `GetDeviceCaps(HORZRES/VERTRES)` on it reports the *primary
  monitor* size, not the virtual screen. Size from `SM_C*VIRTUALSCREEN` and offset the
  source by `SM_X/YVIRTUALSCREEN` (which can be negative). **[measured]**
- **PMv2 is load-bearing for capture, not just for UI.** A DPI-unaware process gets
  virtualised screen metrics (as if 96 DPI) while the screen DC is still raw physical
  pixels, producing a clipped, wrongly-sized capture. Set
  `PerMonitorV2` in the manifest (and/or `SetProcessDpiAwarenessContext` before any HWND).
- **Mixed scale factors do not need per-monitor blits.** The virtual screen is one
  physical-pixel space, so a single blit returns every monitor at native resolution.
  Mixed DPI is a UI/hit-testing problem (overlay layout), not a capture problem.
- **`PW_RENDERFULLCONTENT` (`0x00000002`) is mandatory for window mode** on any
  DWM/DirectComposition window; without it `PrintWindow` returns black. It is defined in
  `winuser.h` (Windows 8.1+) but is **undocumented** on the PrintWindow reference page.
- Known black-frame cases: exclusive-fullscreen / independent-flip / MPO surfaces that
  never enter DWM composition, DRM-protected video, and any app that set
  `WDA_EXCLUDEFROMCAPTURE`. HDR displays yield an 8-bit SDR image through GDI.

---

## 1. The two capture paths

### 1.1 `BitBlt` from the screen DC

The documented GDI capture recipe is `CreateCompatibleDC` → `CreateCompatibleBitmap` →
`SelectObject` → `BitBlt`
([Capturing an Image](https://learn.microsoft.com/en-us/windows/win32/gdi/capturing-an-image)).
The source DC is obtained either with

- `GetDC(NULL)` — "If this value is **NULL**, **GetDC** retrieves the DC for the entire
  screen" ([GetDC](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdc)), or
- `CreateDC(TEXT("DISPLAY"), NULL, NULL, NULL)` — "If there are multiple monitors on the
  system, calling `CreateDC(TEXT("DISPLAY"),NULL,NULL,NULL)` will create a DC covering
  all the monitors"
  ([CreateDCA](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createdca)).

Both forms work and both are equivalent for capture. **[measured]** On the dev machine
`CreateDC("DISPLAY",…)` + `BitBlt(…, SRCCOPY | CAPTUREBLT)` over the virtual screen
returned `TRUE` and produced real content (70.1 % non-black pixels).

`CAPTUREBLT` is documented as:

> Includes any windows that are layered on top of your window in the resulting image.
> By default, the image only contains your window.
> — [BitBlt](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-bitblt)

The "by default the image only contains your window" clause is about blitting from a
*window* DC. For the screen DC the whole composited desktop is the source anyway, so
`CAPTUREBLT` is mostly belt-and-braces — but it is the conventional flag for screen
capture, it costs nothing, and it keeps one code path working if the DC is ever a window
DC. Use `SRCCOPY | CAPTUREBLT`.

Two properties of `BitBlt` matter here:

- "**BitBlt** returns an error if the source and destination device contexts represent
  different devices" — the destination must be compatible with the screen DC.
- "**ICM:** No color management is performed when blits occur" — no ICC handling
  (relevant to HDR/WCG, §4.3).

### 1.2 `PrintWindow` with `PW_RENDERFULLCONTENT`

[`PrintWindow`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-printwindow)
"copies a visual window into the specified device context", asking the owning
application to render via `WM_PRINT` / `WM_PRINTCLIENT`:

> The application that owns the window referenced by hWnd processes the **PrintWindow**
> call and renders the image in the device context that is referenced by *hdcBlt*.

It is documented as blocking/synchronous, so it must not run on the UI thread that is
also servicing the overlay.

The reference page lists only `PW_CLIENTONLY`. `PW_RENDERFULLCONTENT` is **not
documented**, but it is declared in the Windows SDK header. From the installed SDK
(`C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um\winuser.h`, lines
4605–4610):

```c
#define  PW_CLIENTONLY          0x00000001
#if(_WIN32_WINNT >= 0x0603)
#define  PW_RENDERFULLCONTENT   0x00000002
#endif /* _WIN32_WINNT >= 0x0603 */
```

So it exists on Windows 8.1+ and is a plain `#define`, callable from asm without any
import. Its practical effect is to make the captured window include content that is drawn
through the compositor (DirectComposition / DWM), which plain `WM_PRINT` does not paint.

### 1.3 What each path actually sees

**DWM composes everything.** "When desktop composition is enabled, individual windows no
longer draw directly to the screen … their drawing is redirected to off-screen surfaces
in video memory, which are then rendered into a desktop image and presented on the
display. Desktop composition is performed by the Desktop Window Manager (DWM)"
([Desktop Window Manager](https://learn.microsoft.com/en-us/windows/win32/dwm/dwm-overview)).
The screen DC is a handle onto that post-composition desktop image, so a screen-DC
`BitBlt` sees **every normally-composited window, including hardware-accelerated ones
and layered windows**, because DWM has already composited them into the image.

The exceptions are surfaces that never enter DWM's composition tree (§4.1).

**`PrintWindow` is per-window.** It gets whatever the target application renders in
response to `WM_PRINT`. That makes it the only way to capture a window that is occluded
or off-screen — a screen blit reads pixels, not windows, so it cannot. But plain
`WM_PRINT`/`DefWindowProc` does not render DirectComposition content, which is exactly
what `PW_RENDERFULLCONTENT` fixes. Measured, on three different composition stacks:

| window | class | `PrintWindow` flags=0 | flags=`PW_RENDERFULLCONTENT` | screen-DC `BitBlt` |
|---|---|---|---|---|
| "Command Palette" (WinUI 3) | `WinUIDesktopWin32WindowClass` | 0.7 % non-black | 89.4 % | 100 % |
| "Home / X" (Chromium) | `Chrome_WidgetWin_1` | 0.0 % | 23.9 % | 22.0 % |
| "Settings" | `ApplicationFrameWindow` | 0.0 % | 97.9 % | 99.8 % |
| "Adobe Illustrator 2026" | `illustrator` | 100.0 % | 98.4 % | 98.9 % |
| "Program Manager" | `Progman` | 0.0 % | 91.0 % | 70.1 % |

**[measured]** flags=0 is all-black for every DirectComposition-backed window; adding
`PW_RENDERFULLCONTENT` recovers the content. The classic-GDI-ish Illustrator window works
either way, which is why the flag looks optional until it is not.

**Consequence for the design**: use the screen-DC blit as the primary capture for
rectangular / free-form / full-screen snips, and `PrintWindow(PW_RENDERFULLCONTENT)` for
window mode. Fall back to a screen blit of the window's `GetWindowRect` if `PrintWindow`
returns an all-black bitmap (some apps genuinely do not handle `WM_PRINT`).

### 1.4 The overlay window itself

The overlay is a top-level window spanning the virtual screen. If it is on screen when
the capture happens, it lands in the capture — the whole point is that it must not.

`SetWindowDisplayAffinity` gives a documented, compositor-level opt-out
([SetWindowDisplayAffinity](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)):

> **WDA_EXCLUDEFROMCAPTURE** 0x00000011 — The window is displayed only on a monitor.
> Everywhere else, the window does not appear at all. One use for this affinity is for
> windows that show video recording controls, so that the controls are not included in
> the capture.

It requires DWM composition, was introduced in Windows 10 version 2004 (the target is
Windows 11, so that is fine), and is not a security/DRM feature. Calling it once after
creating the overlay makes the overlay invisible to the capture while still visible to
the user — no hide/show dance, no flicker. The older, universally compatible alternative
is to `ShowWindow(SW_HIDE)` the overlay, capture, then show it again, but that flickers
and can change what is under the cursor.

---

## 2. Virtual-screen coordinates

### 2.1 The metrics

`GetSystemMetrics` exposes the virtual screen as four values
([GetSystemMetrics](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics)):

| constant | value | meaning |
|---|---|---|
| `SM_XVIRTUALSCREEN` | 76 | left coordinate of the virtual screen |
| `SM_YVIRTUALSCREEN` | 77 | top coordinate of the virtual screen |
| `SM_CXVIRTUALSCREEN` | 78 | width of the virtual screen, in pixels |
| `SM_CYVIRTUALSCREEN` | 79 | height of the virtual screen, in pixels |
| `SM_CMONITORS` | 80 | number of visible display monitors |
| `SM_SAMEDISPLAYFORMAT` | 81 | nonzero if all monitors share a colour format |

The virtual screen is "the bounding rectangle of all the monitors"
([The Virtual Screen](https://learn.microsoft.com/en-us/windows/win32/gdi/the-virtual-screen)).
The primary monitor contains `(0,0)`, but need not be in the top-left:

> When the primary monitor is not in the upper left of the virtual screen, parts of the
> virtual screen have negative coordinates. Because the arrangement of monitors is set by
> the user, all applications should be designed to work with negative coordinates.

The bounds are constrained to signed 16-bit range because many window messages carry
16-bit coordinates. `GetSystemMetrics` otherwise reports **primary-monitor** values;
`SM_CXMAXTRACK`/`SM_CYMAXTRACK` are the exceptions that refer to the entire desktop
([Multiple Monitor System Metrics](https://learn.microsoft.com/en-us/windows/win32/gdi/multiple-monitor-system-metrics)).
`GetWindowRect(GetDesktopWindow())` returns the primary monitor rectangle, not the
virtual screen — do not use it to size a capture.

### 2.2 The screen DC's own coordinate space (the important part)

The screen DC and the virtual screen are **two different rectangles**, and the screen DC
is anchored on the *primary monitor*, not on the virtual-screen bounding box.
**[measured]** on the dev machine:

```
CreateDC("DISPLAY") GetDCOrgEx          = (0, 0)
CreateDC("DISPLAY") GetDeviceCaps HORZRES = 3440     <- primary monitor width
CreateDC("DISPLAY") GetDeviceCaps VERTRES = 1440     <- primary monitor height
SM_CXVIRTUALSCREEN / SM_XVIRTUALSCREEN    = 5360 / 0  <- whole desktop
GetDC(NULL)        GetDCOrgEx             = (0, 0)
GetDC(NULL)        HORZRES / VERTRES      = 3440 / 1440
```

`GetDCOrgEx` "retrieves the final translation origin for a specified device context",
"relative to the physical origin of the screen"
([GetDCOrgEx](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getdcorgex)).
The origin is `(0,0)` and `GetDeviceCaps(HORZRES)` is the primary monitor's width even
though the DC can reach the whole virtual screen. Therefore:

- **Size the bitmap from `SM_CXVIRTUALSCREEN` × `SM_CYVIRTUALSCREEN`, never from
  `GetDeviceCaps`, `SM_CXSCREEN`, or `GetWindowRect(GetDesktopWindow())`.** Otherwise you
  capture only the primary monitor.
- **Blit from source `(SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN)`,** not from `(0,0)`, or the
  output is shifted and clipped whenever the primary monitor is not at the virtual-screen
  top-left.

### 2.3 Negative origins

When the primary monitor is not top-left, `SM_XVIRTUALSCREEN`/`SM_YVIRTUALSCREEN` are
negative, and the natural source coordinates for the blit are negative too. **BitBlt
accepts this.** **[measured]** `BitBlt(src=(-200,-200))` returned `TRUE`; the part of the
source rectangle that lies off the desktop read back as black, and the on-desktop part
read back as real content (50.0 % non-black for an 800×600 grab at `(-200,-200)`, exactly
the fraction of that rectangle that lies inside the desktop).

If negative logical coordinates are awkward (or a helper rejects them), the equivalent
and equally valid form is to shift the source DC's window origin:

```c
SetWindowOrgEx(hdcScreen, -SM_XVIRTUALSCREEN, -SM_YVIRTUALSCREEN, NULL);
BitBlt(hdcDst, 0, 0, cx, cy, hdcScreen, 0, 0, SRCCOPY | CAPTUREBLT);
```

**[measured]** this is byte-identical to the direct form: `SetWindowOrgEx(src,-100,-100)`
then source `(0,0)` produced **0 differing bytes out of 1,920,000** versus the default
origin with source `(100,100)`. `SetWindowOrgEx` "specifies which window point maps to the
viewport origin (0,0)"
([SetWindowOrgEx](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setwindoworgex)).

Do not confuse the two: the *snip's* public coordinates are virtual-screen coordinates
(origin at `SM_X/YVIRTUALSCREEN`, possibly negative); the *DIB's* coordinates are
`0..cx-1, 0..cy-1`. Convert once, at the boundary.

---

## 3. DPI awareness

### 3.1 What `PER_MONITOR_AWARE_V2` changes

`DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` is `((DPI_AWARENESS_CONTEXT)-4)`
([DPI_AWARENESS_CONTEXT](https://learn.microsoft.com/en-us/windows/win32/hidpi/dpi-awareness-context)).
Registering as PMv2 results in
([High DPI Desktop Application Development on Windows](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows)):

1. notification when the DPI changes, for the whole window tree;
2. **the application seeing the raw pixels of each display**;
3. **the application never being bitmap scaled by Windows**;
4. automatic non-client area scaling;
5. Win32 dialogs automatically DPI scaled;
6. theme-drawn bitmap assets rendered at the right scale.

Points 2 and 3 are the ones that matter for capture. Before the OS virtualises anything,
a PMv2 thread sees physical pixels, and the OS does not stretch the process's own windows.

Per-monitor-aware windows also receive `WM_DPICHANGED` when the effective DPI changes
(window moved between monitors, or a monitor's scale changed), carrying the new DPI and a
suggested window rectangle that should be applied with `SetWindowPos`
([WM_DPICHANGED](https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged)).

### 3.2 The DPI-virtualisation trap

Microsoft's own documentation warns about this in the "Common Pitfalls (Win32)" section:

> When an HWND or process is running as either DPI unaware or system DPI aware, it can be
> bitmap stretched by Windows. When this happens, Windows scales and converts
> DPI-sensitive information from some APIs to the coordinate space of the calling thread.
> For example, if a DPI-unaware thread queries the screen size while running on a high-DPI
> display, Windows will virtualize the answer given to the application as if the screen
> were in 96 DPI units.

That virtualisation applies to the system-metrics calls but **not** to the screen DC's
bitmap. The result is a capture that is the wrong size and contains only part of the
desktop: the app thinks the screen is `SM_CXSCREEN` wide in 96-DPI units, allocates a
bitmap that size, and blits raw physical pixels into it. This is the documented
"virtualization" hazard and the reason a capture program must be DPI aware rather than
letting Windows stretch it.

`GetSystemMetrics` is itself documented as "not DPI aware, and should not be used if the
calling thread is per-monitor DPI aware" — with `GetSystemMetricsForDpi` as the
DPI-aware variant ([GetSystemMetricsForDpi](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetricsfordpi)).
For the *virtual-screen* metrics this caveat is about which thread context you query
from, not about the values being per-monitor: from a PMv2 thread the virtual screen is
its true physical-pixel bounding box. The practical rule is simply: **be PMv2, then query
the metrics.** (Reports of `GetSystemMetrics(SM_CXVIRTUALSCREEN)` returning a too-small
virtual desktop, and of `GetSystemMetricsForDpi` returning the same value until the
thread is switched to PMv2, are consistent with this.)

### 3.3 How to set it

Two ways, both documented
([Setting the default DPI awareness for a process](https://learn.microsoft.com/en-us/windows/win32/hidpi/setting-the-default-dpi-awareness-for-a-process)):

- **Manifest (recommended)**:

  ```xml
  <asmv3:windowsSettings>
    <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
    <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
  </asmv3:windowsSettings>
  ```

  `<dpiAwareness>` is the Windows 10 1607+ element; `<dpiAware>` is the Vista-era
  fallback. Note `PerMonitorV2` is only expressible via `<dpiAwareness>`.

- **API**: `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`
  ([SetProcessDpiAwarenessContext](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setprocessdpiawarenesscontext)).
  It "must be called before you call any APIs that depend on the DPI awareness (including
  before creating any UI in your process). Once API awareness is set for an app, any
  future calls to this API will fail" with `ERROR_ACCESS_DENIED`. If never set, the
  default is `DPI_AWARENESS_CONTEXT_UNAWARE`.

For a pure-asm program the manifest is the low-friction route, but a
`SetProcessDpiAwarenessContext` call at the top of `WinMain` (before any window) is a
correct and self-contained fallback. Per-thread overrides via
`SetThreadDpiAwarenessContext` exist but are not needed here except as a debugging aid.

### 3.4 Do mixed scale factors need per-monitor blits?

**No, not for pixel correctness.** The virtual screen is a single coordinate space in
physical pixels, and DWM presents each monitor at its native resolution; one
virtual-screen blit therefore returns each monitor's real pixels. Scale factor changes
logical size and font metrics, not the captured pixel grid.

A per-monitor blit is only needed when:

- monitors differ in **colour format** — the documented reason to use
  `EnumDisplayMonitors`: "You want to draw optimally into a device context that spans
  several display monitors, and the monitors have different color formats" and "To
  determine whether all the display monitors in a system share the same color format,
  call `GetSystemMetrics` (`SM_SAMEDISPLAYFORMAT`)"
  ([EnumDisplayMonitors](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaymonitors)).
  Note the same page says this only makes things "look better"; painting as if the whole
  screen had the primary monitor's properties is acceptable;
- you need per-monitor **metadata** (DPI, work area, device name) — `EnumDisplayMonitors`
  + `GetMonitorInfo` + `GetDpiForMonitor`;
- you are using a **per-output** API (Desktop Duplication has one duplication per output;
  Windows.Graphics.Capture has `CreateForMonitor`).

**What mixed DPI does force** is per-monitor work in the *overlay UI*: choosing fonts and
handle sizes per monitor, and handling `WM_DPICHANGED`. The overlay is one top-level
window spanning the virtual screen, so it has a single DPI context at a time — the DPI of
the monitor it is "primarily located on". Any chrome drawn on top of the dim layer must be
laid out with that DPI in mind, and re-laid-out on `WM_DPICHANGED`. The captured *image*
is unaffected.

---

## 4. Known failure modes

### 4.1 Black frames

1. **`PrintWindow` without `PW_RENDERFULLCONTENT`.** Confirmed above: DirectComposition
   windows come back all-black. This is the single most likely "black window" bug in
   window mode.
2. **Surfaces that bypass DWM composition.** A swapchain can be "DirectFlipped" so that
   "the application swapchain is used" instead of the DWM swapchain, and "once your
   swapchain has been 'DirectFlipped', then the DWM can go to sleep … Your app frames are
   sent directly to the screen, independently, with the same efficiency as fullscreen
   exclusive"
   ([For best performance, use DXGI flip model](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/for-best-performance--use-dxgi-flip-model)).
   With multi-plane overlay (MPO) the content is scanned out from a dedicated hardware
   plane. Content that never enters the post-composition surface cannot appear in a
   screen-DC blit; the classic symptom is a black or stale frame where a fullscreen game
   is. Corroborated from the duplication side: `AcquireNextFrame` returns
   `DXGI_ERROR_ACCESS_LOST` on "Switch from DWM on, DWM off, or other full-screen
   application"
   ([AcquireNextFrame](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutputduplication-acquirenextframe)).
   Note that modern fullscreen *optimisations* deliberately route most "exclusive
   fullscreen" games back through DWM, so this is the exception, not the rule.
3. **DPI virtualisation** (§3.2) — not black, but a partial capture that looks like a
   rendering bug.
4. **Capturing before the overlay is hidden/excluded** — the dim layer appears in the
   snip.
5. **Reading an uninitialised bitmap.** `CreateCompatibleBitmap` returns an
   uninitialised surface; size mismatches or a failed `BitBlt` silently leave black.
   Check the `BitBlt` return value, and prefer `CreateDIBSection` so the layout and
   initialisation are explicit.

### 4.2 Protected content / DRM

- **Any app can exclude itself.** `WDA_EXCLUDEFROMCAPTURE` makes a window "not appear at
  all" outside the monitor, i.e. in capture surfaces, while the user still sees it. It is
  documented as *not* a security or DRM guarantee, but it is the documented mechanism, and
  it works against the screen-DC blit. A snipping tool cannot defeat it (and should not
  try).
- **DRM video is blacked out by the OS.** The Desktop Duplication API "provides
  protection against accessing protected video content"
  ([Desktop Duplication — Windows drivers](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/desktop-duplication-api)),
  and the frame metadata exposes `ProtectedContentMaskedOut`: "TRUE if protected content
  was already blacked out in the desktop image"
  ([DXGI_OUTDUPL_FRAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/ns-dxgi1_2-dxgi_outdupl_frame_info)).
  GDI reads the same post-composition surface, so it inherits the same blacked-out
  regions. Expect a black rectangle where protected video plays; there is no API on this
  path to recover it.

### 4.3 HDR / advanced colour

- **GDI capture is SDR, 8-bit.** The Advanced Color documentation names the APIs that can
  preserve HDR/WCG: "APIs that support specifying pixel formats, such as those in the
  **Windows.Graphics.Capture** namespace, and the **IDXGIOutput5::DuplicateOutput1**
  method, provide the capability to capture HDR and WCG content without losing pixel
  information"
  ([Use DirectX with Advanced Color](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range)).
  GDI has no such pixel-format argument, and `BitBlt` performs no colour management.
- The WinRT guidance confirms the symptom on HDR systems: "To avoid pixel overclipping
  (i.e. the captured content looks washed out) when capturing HDR content, consider using
  `DXGI_FORMAT_R16G16B16A16_FLOAT`"
  ([Screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)).
  With GDI, the content is clamped to 8-bit sRGB, so highlights can clip and wide-gamut
  colours narrow.
- Under Advanced Color, Windows auto-colour-manages content to the display; 8-bit content
  is treated as sRGB. GDI pixels therefore come back "as sRGB", which is acceptable for a
  v1 snip but not colour-accurate for HDR sources.
- This matches the behaviour users see from the built-in tool on HDR panels, but that is
  a second-hand observation; treat it as consistent, not proven.

### 4.4 Other

- **The mouse cursor is not in the desktop bitmap.** GDI screen capture does not include
  the cursor; DXGI exposes it separately (`GetFramePointerShape`, `PointerPosition`). If
  the spec wants the cursor in the snip, read `GetCursorInfo`/`GetIconInfo` and draw it
  into the DIB at the right position.
- **Layered-window alpha is lost.** `BitBlt` copies colour data; per-pixel alpha of a
  layered window is not meaningful in the resulting opaque bitmap. Fine for a screenshot
  (the screen has no alpha either), but do not expect transparency.
- **Topology changes mid-snip.** `WM_DISPLAYCHANGE` / `WM_DPICHANGED` mean the virtual
  screen metrics changed; re-query them rather than caching them at startup. A capture
  started before a change may be clipped or stale; the safe response is to abort the
  session or re-capture.
- **Memory.** A virtual-screen 32-bpp DIB is tens of MB — 5360×1440×4 ≈ 30.9 MB on this
  machine, and multi-4K setups scale linearly. Allocate once per snip session.
- **`PrintWindow` is blocking** and runs the target app's code; a hung target can hang the
  capture. Call it off the UI thread with a timeout/retry, and fall back to a screen blit
  of `GetWindowRect`.

---

## 5. Recommendation for the v1 capture path

**DPI + manifest**

1. Mark the executable `PerMonitorV2` in the manifest (with a `<dpiAware>` fallback), and
   call `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` before
   creating any window if the manifest is not convenient. Do this on day one: capture
   correctness depends on it, not just UI crispness.

**Capture geometry**

2. On session start, read `SM_XVIRTUALSCREEN`, `SM_YVIRTUALSCREEN`,
   `SM_CXVIRTUALSCREEN`, `SM_CYVIRTUALSCREEN`. These define the DIB and the public
   coordinate space for the whole session.
3. Prefer `CreateDIBSection` (top-down 32-bpp `BI_RGB`) over `CreateCompatibleBitmap` +
   `GetDIBits`: it gives a fixed BGRA layout, a directly readable buffer, and no second
   copy.

**Capture**

4. Rectangular / free-form / full-screen: one screen DC
   (`CreateDC("DISPLAY",NULL,NULL,NULL)` or `GetDC(NULL)`), one
   `BitBlt(dst, 0, 0, cx, cy, src, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SRCCOPY | CAPTUREBLT)`
   into a DIB sized `cx × cy`. Free-form is a clip/mask over this same image. Full-screen
   mode is the same image cropped to the monitor under the cursor
   (`MonitorFromPoint`/`GetMonitorInfo`).
5. Window mode: `PrintWindow(hwnd, memDC, PW_RENDERFULLCONTENT)` into a DIB sized to
   `GetWindowRect` (`| PW_CLIENTONLY` if the snip should exclude the frame), run off the
   UI thread. If the result is all-black, retry without the flag, then fall back to a
   screen-DC blit of that rectangle.
6. Overlay: a top-level window covering the virtual screen, plus
   `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` immediately after creation so
   it is never in the snip. Keep the hide/capture/show dance as a fallback only.

**Deliberately not in v1**

7. DXGI Desktop Duplication (D3D device + per-output duplication, mode-change recovery),
   `Windows.Graphics.Capture` (WinRT + D3D + a mandatory system yellow border around the
   captured item), and the Magnification API (magnifier-host plumbing) are all heavier than
   a screenshot needs. Revisit for v2 only if HDR fidelity or exclusive-fullscreen
   capture becomes a requirement.

**Resolution/DPI bookkeeping**

8. Store each snip as physical pixels plus the virtual-screen origin. Convert to/from an
   individual monitor's logical coordinates only for UI and hit-testing, using the
   monitor's DPI from `GetDpiForWindow` / `WM_DPICHANGED`. Never assume 96 DPI and never
   assume `(0,0)` is the top-left of the desktop.
9. Force a full re-read of monitor geometry on `WM_DISPLAYCHANGE` and treat
   `WM_DPICHANGED` as a signal to re-lay-out the overlay chrome.

---

## Measurement: what was run on the dev machine

Host: Windows 11 build 26200, AMD64. PowerShell 7 host, P/Invoke to
`user32`/`gdi32`/`shcore`. Scripts are throwaway scratch files under
`%TEMP%\opencode\*.ps1` (not part of the repo).

Monitor topology:

```
\\.\DISPLAY1  rect=(0,0)-(3440,1440)      dpi=96
\\.\DISPLAY2  rect=(3440,349)-(5360,1429) dpi=96
SM_CMONITORS = 2
virtual screen: origin=(0,0)  size=5360x1440
```

1. **Screen-DC blit.** `CreateDC("DISPLAY",NULL,NULL,NULL)` →
   `CreateCompatibleDC`/`CreateCompatibleBitmap(5360,1440)` →
   `BitBlt(0,0,5360,1440, src, 0,0, SRCCOPY|CAPTUREBLT)` → `TRUE`;
   `GetDIBits` returned 1440 lines; 70.1 % of pixels non-black. A real capture of both
   monitors, produced with no per-monitor logic.
2. **DC origin and capabilities.** `GetDCOrgEx = (0,0)`;
   `GetDeviceCaps(HORZRES,VERTRES) = (3440,1440)` = primary monitor only, while
   `SM_CXVIRTUALSCREEN = 5360`. Confirms the screen DC is anchored on the primary monitor.
3. **Negative source coordinates.** `BitBlt(src=(-200,-200), 800x600)` → `TRUE`; 50.0 %
   non-black, exactly the fraction of that rectangle inside the desktop, with the
   off-desktop part black. Negative source coordinates are accepted.
4. **`SetWindowOrgEx` equivalence.** `SetWindowOrgEx(src,-100,-100)` + source `(0,0)`
   versus default origin + source `(100,100)`: **0 of 1,920,000 bytes differ**.
5. **Per-window comparison.** For each of five live windows:
   `PrintWindow(hwnd, dc, 0)`, `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)`, and a
   screen-DC blit of the window rectangle; non-black pixel fraction reported (table in
   §1.3). DirectComposition windows are black without the flag.
6. **DPI context.** `GetSystemMetrics(76..80)` and `GetDpiForSystem` were read before and
   after `SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`; the
   values were identical because both monitors on this machine are at 100 % and the
   PowerShell host is already PMv2-aware. This machine **cannot** demonstrate the
   virtualisation trap; that part rests on the documentation in §3.2, not on measurement.

Not verified here (documentation only): a topology with a negative virtual-screen origin;
mixed DPI across monitors; HDR; DRM-protected video; exclusive-fullscreen/independent-flip
surfaces; the overlay's own `WDA_EXCLUDEFROMCAPTURE` behaviour. These are flagged in place
above.

---

## Sources

Microsoft Learn (all fetched 2026-09-21):

- [BitBlt function](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-bitblt)
- [Capturing an Image](https://learn.microsoft.com/en-us/windows/win32/gdi/capturing-an-image)
- [CreateDCA function](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createdca)
- [GetDC function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdc)
- [GetDCOrgEx function](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getdcorgex)
- [SetWindowOrgEx function](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setwindoworgex)
- [PrintWindow function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-printwindow)
- [GetSystemMetrics function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics)
- [GetSystemMetricsForDpi function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetricsfordpi)
- [The Virtual Screen](https://learn.microsoft.com/en-us/windows/win32/gdi/the-virtual-screen)
- [Multiple Monitor System Metrics](https://learn.microsoft.com/en-us/windows/win32/gdi/multiple-monitor-system-metrics)
- [Multiple Monitor Considerations for Older Programs](https://learn.microsoft.com/en-us/windows/win32/gdi/multiple-monitor-considerations-for-older-programs)
- [EnumDisplayMonitors function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaymonitors)
- [High DPI Desktop Application Development on Windows](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows)
- [Setting the default DPI awareness for a process](https://learn.microsoft.com/en-us/windows/win32/hidpi/setting-the-default-dpi-awareness-for-a-process)
- [DPI_AWARENESS_CONTEXT handle](https://learn.microsoft.com/en-us/windows/win32/hidpi/dpi-awareness-context)
- [SetProcessDpiAwarenessContext function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setprocessdpiawarenesscontext)
- [SetThreadDpiAwarenessContext function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext)
- [Mixed-Mode DPI Scaling and DPI-aware APIs](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-improvements-for-desktop-applications)
- [WM_DPICHANGED message](https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged)
- [Desktop Window Manager](https://learn.microsoft.com/en-us/windows/win32/dwm/dwm-overview)
- [Performance Considerations and Best Practices (DWM)](https://learn.microsoft.com/en-us/windows/win32/dwm/bestpractices-ovw)
- [SetWindowDisplayAffinity function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)
- [Desktop Duplication API](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api)
- [Desktop Duplication (Windows drivers)](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/desktop-duplication-api)
- [IDXGIOutputDuplication::AcquireNextFrame](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutputduplication-acquirenextframe)
- [DXGI_OUTDUPL_FRAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/ns-dxgi1_2-dxgi_outdupl_frame_info)
- [For best performance, use DXGI flip model](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/for-best-performance--use-dxgi-flip-model)
- [Use DirectX with Advanced Color on high/standard dynamic range displays](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range)
- [Screen capture (Windows.Graphics.Capture)](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)

Local primary source: Windows SDK header
`C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um\winuser.h`
(`PW_CLIENTONLY`, `PW_RENDERFULLCONTENT`, `PrintWindow` declaration).

Secondary, used only where marked: Stack Overflow / Microsoft Q&A threads on
`SM_CXVIRTUALSCREEN` under mixed DPI and on `GetDC`/`BitBlt` in DPI-unaware processes.
