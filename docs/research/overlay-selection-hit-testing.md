# Overlay selection: hit-testing, chrome rendering, and window rects on Windows 11

Research for ticket [07](../../.scratch/snipping-tool-asm/issues/07-overlay-selection-ux.md)
(`.scratch/snipping-tool-asm/issues/07-overlay-selection-ux.md`), prototyped in the
throwaway `prototypes/overlay/` (not committed; the findings below are the deliverable).

Scope: the Win32 surface a full-screen snipping overlay needs beyond the capture path in
[capture-dpi-multimonitor.md](capture-dpi-multimonitor.md) — how to name the window under
the cursor, how to draw chrome that is *opaque* while the dim layer stays translucent, and
how to get a window's true visible rectangle. Facts are marked **[measured]** where a
throwaway script on the dev machine confirmed them; the method is in
[Measurement](#measurement-what-was-run-on-the-dev-machine).

---

## TL;DR

- **The window under the cursor is `WindowFromPoint` + `GetAncestor(GA_ROOT)`, not
  `EnumWindows` + `PtInRect`.** `EnumWindows` enumerates in Z-order top-to-bottom, so it
  *can* be made to work, but `PtInRect` on each window's rect counts **invisible,
  click-through and cloaked** windows that the mouse can never hit — on the dev machine 40+
  full-screen phantom windows contained any given point. `WindowFromPoint` asks the same
  question the mouse does and is Z-order-correct. **[measured]**
- **`WindowFromPoint` returns the tool's own overlay, because it is topmost.** The fix is
  to set `WS_EX_TRANSPARENT` for the duration of the call and restore it immediately: the
  overlay becomes invisible to hit-testing, and because no message pump runs in between,
  the change is never rendered. **[measured]** A hide/show or
  `SetWindowDisplayAffinity` dance is not needed.
- **`EnumWindows` supplies no Z-order API on the window it hands you**, so an
  `EnumWindows`-based picker must assume enumeration order is Z-order (it is, documented
  and measured) or use `GetTopWindow`/`GetWindow(GW_HWNDNEXT)`, which is the same order.
- **Chrome cannot be opaque inside a uniformly-alpha'd layered window.** With
  `SetLayeredWindowAttributes(LWA_ALPHA)`, alpha is per-window: a "black" readout plate
  composites to grey and its white text is halved in opacity — unreadable, and not fixable
  with brushes or fonts. The lever is `UpdateLayeredWindow` with a **32bpp premultiplied
  DIB**, which gives per-pixel alpha (opaque plate and outline, translucent dim) and drops
  the magenta colour key. **[measured]** the failure, reasoned the fix.
- **`GetWindowRect` includes the invisible resize border** (~7 px per side on Win11).
  `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` returns the visible frame. Neither
  the capture research nor the prototype had this; a window snip sized from `GetWindowRect`
  carries a sliver of desktop. *(Documented; not measured here — see
  [Not measured](#not-measured-on-this-machine).)*
- **`GetMonitorInfo` requires `MONITORINFO.cbSize`.** Omitting it makes every call fail and
  full-screen mode silently produce no selection — the single easiest bug to hit in a
  monitor-picking code path. **[measured]**

---

## 1. Naming the window under the cursor

### 1.1 The two candidates

Window mode asks: *which top-level window is the user pointing at, with the frontmost one
winning?* Two primitives answer it.

`EnumWindows` enumerates top-level windows, documented as this order:

> **EnumWindows** enumerates all top-level windows on the screen by passing the handle to
> each window, in turn, to an application-defined callback function. **EnumWindows**
> continues until the last top-level window is enumerated or the callback function returns
> FALSE.
> — [EnumWindows](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumwindows)

The Z-order guarantee is on `GetTopWindow`:

> **GetTopWindow** examines the child windows associated with the specified parent window
> and returns a handle to the child window at the top of the **Z-order**.
> — [GetTopWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-gettopwindow)

and `GetWindow(GW_HWNDNEXT)` walks that same order. Empirically `EnumWindows` supplies
windows in that same top-to-bottom order, so a first-match-wins `EnumWindows` loop is a
Z-order-correct picker *as long as the predicate is correct*. **[measured]**: with a small
window overlapping a large one, `EnumWindows` returned the small (front) window before the
large one.

`WindowFromPoint` asks the mouse:

> **WindowFromPoint** retrieves a handle to the window that contains the specified point.
> — [WindowFromPoint](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-windowfrompoint)

It "does not retrieve a handle to a hidden or disabled window, even if the point is within
the window" ([WindowFromPoint](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-windowfrompoint)),
and it honours `WS_EX_TRANSPARENT`. It returns a possibly-*child* window, so resolve to the
top-level owner with `GetAncestor(hwnd, GA_ROOT)`:

> **GA_ROOT** — Retrieves the root window by walking the chain of parent windows.
> — [GetAncestor](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getancestor)

### 1.2 Why `EnumWindows` + `PtInRect` picks wrong

The predicate is the problem. A rectangle test cannot see:

- **invisible windows** — `IsWindowVisible` is necessary, and one layer of filtering is not
  enough: `GetWindowRect` still reports the phantom windows' rects, which are frequently
  the whole virtual screen;
- **click-through windows** — `WS_EX_TRANSPARENT`, which `IsWindowVisible` does not exclude;
- **DWM-cloaked windows** — windows on another virtual desktop, or UWP ghosts. Excluded
  only via `DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, ...)`; the DWM docs describe the
  cloaked state as "the window is not visible to the user"
  ([DWMWA_CLOAKED](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute)).

**[measured]** enumerating on the dev machine and testing a single point against
`IsWindowVisible(hwnd) && PtInRect(rect, point)` returned 40+ containers for one point,
including `vis=False` `WinUIDesktopWin32WindowClass`, `SDL_app` and `Chrome_WidgetWin_0`
ghosts whose rects covered the point. The first one in enumeration order that is also
visible then wins — which is why a naive picker can land on the taskbar
(`Shell_TrayWnd`) or the desktop (`Progman`/`WorkerW`, whose rect is the whole virtual
screen), and why the accompanying prototype bug *looked like* "the dim disappears between
windows": the "selection" had become the entire desktop.

Result: leave the **desktop and the taskbar unselectable** so the dim stays put where there
is no window, and never let a rect which *is* the virtual screen win.

### 1.3 `WindowFromPoint` hits the overlay itself

The overlay is `WS_EX_TOPMOST` and covers the virtual screen, so `WindowFromPoint` returns
the overlay. **[measured]**, and the fix that works:

| overlay state | `WindowFromPoint` at the overlap point |
|---|---|
| topmost, normal | `OVER` (the overlay) |
| `WS_EX_TRANSPARENT` added | `SMALL` (correct) |
| restored | `OVER` again |

The toggle is set and restored around the single `WindowFromPoint` call. No message pump
runs between the two `SetWindowLong` calls, so DWM never composites the transparent state;
there is no flicker and no visible change. This is cheaper and more robust than
`ShowWindow(SW_HIDE)` → hit-test → `SW_SHOW` (which flickers and can change what is under
the cursor) and does not interfere with `WDA_EXCLUDEFROMCAPTURE`, which is about capture
surfaces, not hit-testing.

### 1.4 Choosing

Use `WindowFromPoint` + `GetAncestor(GA_ROOT)` + `WS_EX_TRANSPARENT` toggled around the
call, **and** keep the shell-class and `DWMWA_CLOAKED` guards (§1.2) because the desktop and
taskbar are legitimately hit-testable by the mouse and must still be refused:

- desktop / shell classes: `Progman`, `WorkerW`, `Shell_TrayWnd`,
  `Shell_SecondaryTrayWnd`, `SysShadow`;
- `DWMWA_CLOAKED != 0`;
- a window that fails `IsWindowVisible`.

`EnumWindows` remains the right tool when the *list* is wanted (e.g. a future "choose a
window" picker); it is the wrong tool for a cursor hit-test.

---

## 2. Chrome that reads: uniform alpha versus per-pixel alpha

### 2.1 The failure

`SetLayeredWindowAttributes(hwnd, KEY_COLOR, 128, LWA_ALPHA | LWA_COLORKEY)` gives the
overlay a **uniform** alpha and a colour key. Two consequences:

- the colour key punches holes wherever the key colour is painted — this is how a
  selection is "revealed": paint it magenta and it disappears, showing the undimmed
  desktop. It works, but it is a chroma trick: any pixel that merely *resembles* the key
  (antialiased edges, a magenta UI) is also punched;
- **every other pixel** — the readout plate, the outline, the label text — is at the same
  50 %. A `hbr_black` plate over a dimmed desktop composites to mid-grey, and white text at
  alpha 128 is washed out. This is not a brush, font or colour choice: alpha is a property
  of the *window*, applied after painting. **[measured]** in the prototype: the plate
  rendered as a flat grey box and the `W x H` label was illegible, while the end-of-session
  message box (an ordinary opaque window) read fine.

### 2.2 The lever

`UpdateLayeredWindow` replaces `SetLayeredWindowAttributes` and takes a **per-pixel alpha**
source:

> **UpdateLayeredWindow** updates the position, size, shape, content, and
> translucency of a layered window. … The window is updated using the source bitmap and
> the blend function, and `hdcDst` supplies the destination.
> — [UpdateLayeredWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-updatelayeredwindow)

The source is a 32bpp DIB with **premultiplied** alpha, via
`CreateDIBSection` + `BLENDFUNCTION{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA }`. Implications for
this program:

- the dim layer is written at alpha 128 per pixel — same look as `LWA_ALPHA`;
- the plate, outline and text are written at alpha 255 — **fully opaque**, so the readout is
  legible against any background;
- the colour key disappears entirely, removing the chroma-fringe class of artefacts;
- cost: the overlay owns its DIB and blits it per frame instead of blitting GDI output into
  a window DC. It is a render-path rewrite, not a patch, and it *changes the look* — the
  handoff already flagged this as deliberately deferred.

**Does it collide with `WDA_EXCLUDEFROMCAPTURE`?** No. Display affinity controls whether the
window appears in capture surfaces; layered presentation controls how it composites on
screen. They are independent, and `UpdateLayeredWindow` is the normal way to draw a layered
window at all. Keep `SetWindowDisplayAffinity` set once after creation.

**Premultiplication is exact here.** Because the snip is straight-BGRA in memory but the
*overlay* DIB is composited by DWM, the overlay DIB must be premultiplied
(`c * a / 255`) — the same rule ADR-0001 records for straight vs premultiplied alpha, applied
to the overlay instead of the Snip itself. A `BitBlt`/`FillRect`-based paint path cannot
produce premultiplied output; the overlay would need `AlphaBlend` or manual writes.

### 2.3 Alternatives considered

- **Two windows**: a translucent dim window plus an opaque chrome window on top. Works with
  plain GDI, but doubles the window count, needs the chrome window kept in sync with the
  dim window's position, and the chrome window must **not** be excluded from capture while
  the dim window is (or both must be). Rejected: more moving parts than one
  `UpdateLayeredWindow`.
- **`SetLayeredWindowAttributes` with per-pixel alpha** — not a thing; the two alpha modes
  are exclusive, and `LWA_ALPHA` is uniform by definition.
- **Draw the readout into a normal child window** — a child of a layered window inherits
  the layered presentation, so this does not escape the uniform alpha either.

### 2.4 A marquee outline without a hard-coded pen

An outline drawn with a fixed white `CreatePen` vanishes on light content. Two cheap GDI
mechanisms make it always visible:

- `SetROP2(DSTINVERT)` + `PatBlt`/`Rectangle` — draws by inverting the destination, so the
  outline is the complement of whatever is beneath it
  ([SetROP2](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setrop2),
  `R2_NOT`);
- `DrawFocusRect`, which is documented as "a rectangle in the style used to indicate
  focus" and, like `R2_NOT`, is drawn inverting on each call
  ([DrawFocusRect](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-drawfocusrect)).

Either gives high contrast on any background for free. True "marching ants" additionally
needs a phase advanced by `SetTimer`, which is feel-polish, not correctness.

---

## 3. Window rectangles

`GetWindowRect` returns the window's bounding rectangle **including the invisible resize
border** Windows 10+ draws around top-level windows: "the dimensions are given in screen
coordinates relative to the upper-left corner of the screen"
([GetWindowRect](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowrect)),
and on Win11 that rect is the *extended frame*, not the visible frame.

`DWMWA_EXTENDED_FRAME_BOUNDS` is the attribute that returns the visible bounds:

> **DWMWA_EXTENDED_FRAME_BOUNDS** — Retrieve the bounds of the window, excluding the
> drop shadow.
> — [DWMWA_EXTENDED_FRAME_BOUNDS](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute)

Read with `DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &rc, sizeof(rc))`
(`dwmapi.lib`). It is stated to be *relative to the window origin*, so it is a *size*
source when the DWM frame differs from the Win32 frame — a client-side-decoration window
(WinUI, Chromium) has no Win32 non-client area at all, and the two rectangles diverge
noticeably there. For a snipping tool the visible frame is the truthful one: sizing a window
snip from `GetWindowRect` includes a translucent resize margin and a shadow-adjacent sliver
of desktop.

Practical rule for the real `overlay`/`capture` modules: **use `DWMWA_EXTENDED_FRAME_BOUNDS`
for the highlight and for the `PrintWindow` target rect, falling back to `GetWindowRect`
when the DWM call fails** (it does on some windows, e.g. certain layered or ownerless
windows). This is the same fallback shape the capture research already prescribes for
`PrintWindow`.

---

## 4. Incidental Win32 traps met while building the prototype

- **`MONITORINFO.cbSize` is mandatory.** `GetMonitorInfo` "returns FALSE" on failure and
  requires the structure's size; once set, full-screen mode
  (`MonitorFromPoint` → `GetMonitorInfo`) returned the correct monitor rect. Omitting it
  makes *every* call fail and the mode silently select nothing. The same applies to
  `GetMonitorInfo`'s sibling structures generally — always `SIZEOF`.
- **`r9` (and all volatile registers) must be read before any `call`.** In a `WndProc`,
  `WM_LBUTTONDOWN`'s `lParam` arrives in `r9`; calling `SetCapture` first destroys it, so the
  selection origin reads `(0,0)` and every selection anchors at the screen origin. Parse the
  message parameters into memory *first*. This was a real off-by-a-call bug in the
  prototype (handoff bug 1).
- **A mode that resolves on *hover* must not also run the drag handler on mouse-down.** If
  `WM_LBUTTONDOWN` falls through to a rectangular selection update, it overwrites the
  hovered window with a zero-size rect taken from the click point, and the snip collapses to
  `0 x 0` even though the hover was correct. Each mode needs its own mouse-down path.
- **DWM compositing can show a half-drawn layered window.** Painting the dim and the punched
  hole directly to the window DC lets DWM composite the moment between them (hole missing)
  — visible flicker. Painting the whole frame into one memory DC and presenting it once per
  frame fixes it. The same double-buffer discipline is a prerequisite for
  `UpdateLayeredWindow`, which only ever receives a finished bitmap.

---

## 5. Recommendation for the real overlay module

1. **Selection input** — one `Overlay` window spanning the virtual screen, topmost,
   layered, `WDA_EXCLUDEFROMCAPTURE`; `SetProcessDpiAwarenessContext` PMv2 before creation
   (capture research §5).
2. **Window mode hit-test** — `WindowFromPoint` + `GetAncestor(GA_ROOT)` with the overlay
   flipped `WS_EX_TRANSPARENT` around the call; refuse shell classes and cloaked windows;
   highlight and capture the whole top-level window (not the specific control).
3. **Highlight rect** — `DWMWA_EXTENDED_FRAME_BOUNDS`, falling back to `GetWindowRect`.
4. **Chrome rendering** — own a 32bpp premultiplied DIB and present it with
   `UpdateLayeredWindow`; dim at 128, chrome at 255. Drop the colour key.
5. **Readout** — a real text renderer (`DrawTextW` for layout, or GDI+ `GdipDrawString` for
   antialiased glyphs) instead of `TextOutW` with the stock GUI font, drawn opaque on the
   DIB. Keep the end-of-session dimensions reporting as the fallback truth.
6. **Modes** — all four (`rect`, `free`, `window`, `full`) are wanted; the delay is a plain
   pre-show `Sleep` with no countdown (verdict on ticket 07).

---

## Measurement: what was run on the dev machine

Host: Windows 11 build 26200, AMD64, virtual screen `0,0–5360,1440`, two monitors.
Throwaway PowerShell + P/Invoke scripts under `%TEMP%\opencode\*.ps1` (not part of the
repo); the overlay under test was `prototypes/overlay/build/overlay.exe`.

1. **Z-order and phantom containers.** Two `Windows.Forms` windows (700×500 at
   `(300,200)` and 240×180 at `(450,320)`, the smaller activated) with the cursor at a point
   inside both. `EnumWindows` returned the small window *before* the large one, so
   enumeration order is Z-order. The same walk reported 40+ windows whose
   `vis=True && PtInRect(point)` held, nearly all of them `vis=False` phantoms with
   virtual-screen-sized rects; `WindowFromPoint` returned the small window directly.
2. **Self-hit and the `WS_EX_TRANSPARENT` toggle.** A borderless, topmost, 60 %-opacity
   window over the same pair: `WindowFromPoint` returned the overlay; adding
   `WS_EX_TRANSPARENT` made it return the small window; restoring the style returned the
   overlay again.
3. **End-to-end window mode.** Driving `overlay.exe window` with posted
   `WM_MOUSEMOVE`/`WM_LBUTTONDOWN`/`WM_LBUTTONUP` over the overlap produced the result
   dialog `mode=window class=WindowsForms… x=450 y=320 w=240 h=180` — the front window, with
   its true rect.
4. **Mode regression.** `rect` → `x=400 y=300 w=200 h=150`; `free` → `x=420 y=320 w=140
   h=110`; `full` → `x=0 y=0 w=3440 h=1440`; all as expected after the fixes.
5. **`MONITORINFO.cbSize`.** Before setting it, `full` produced no selection at all;
   after, the monitor rect above.

### Not measured on this machine

- **`DWMWA_EXTENDED_FRAME_BOUNDS` versus `GetWindowRect`** — documented, and the ~7 px
  border is common knowledge, but not measured here because the prototype used
  `GetWindowRect`. Verify when the real window-mode capture lands, and record the delta.
- **`UpdateLayeredWindow` with a premultiplied DIB** — the *failure* of uniform alpha is
  measured (§2.1); the fix is reasoned from the API contract, not yet built. Building it is
  the first task of the real `overlay` module, not of the throwaway prototype.
- **Layered-window hit-testing under `WS_EX_TRANSPARENT`** is measured for a plain layered
  window; confirm it still holds once chrome is presented with `UpdateLayeredWindow` (it
  should — hit-testing follows the window region, not the alpha).

---

## Sources

Microsoft Learn:

- [EnumWindows](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumwindows)
- [GetTopWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-gettopwindow)
- [GetWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindow)
- [WindowFromPoint](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-windowfrompoint)
- [GetAncestor](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getancestor)
- [DWMWA_CLOAKED](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute)
- [DWMWA_EXTENDED_FRAME_BOUNDS](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute)
- [SetLayeredWindowAttributes](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setlayeredwindowattributes)
- [UpdateLayeredWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-updatelayeredwindow)
- [BLENDFUNCTION](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-blendfunction)
- [SetWindowDisplayAffinity](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)
- [GetMonitorInfo](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmonitorinfow)
- [GetWindowRect](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowrect)
- [SetROP2](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setrop2)
- [DrawFocusRect](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-drawfocusrect)
- [DrawText](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-drawtextw)

Companion research: [Screen capture, DPI awareness, and multi-monitor](capture-dpi-multimonitor.md);
[PNG encoding from pure asm via COM](png-encoding-com.md).
