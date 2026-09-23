# Windows 11 Snipping Tool — window structure and lifecycle

Reference behaviour for the Windows 11 Snipping Tool, gathered 2026-09-23 by a research
subagent from public sources. This is supporting evidence for the replica's Shell/Editor
split, not a decision: the decisions live in
[Main window shell](../../.scratch/snipping-tool-asm/issues/11-main-window-shell.md)
(ticket 11) and the rest of the tracker.

**Scope:** the modern WinUI `Snipping Tool` app that ships with Windows 11 (Store identity
`Microsoft.ScreenSketch`), the app that replaced *both* the classic Win32 Snipping Tool and
Snip & Sketch. This is **not** the Win7/8.1 single-window app — that is covered by
[classic-snipping-tool-editor.md](classic-snipping-tool-editor.md). The Win11 app is
Store-serviced and has changed a lot since 2021, so where a behaviour is version-specific
the app version is noted. Sources are linked per claim; anything not directly documented is
marked **[uncertain]**, with a confidence note. Screenshots marked *(inspected)* were
downloaded and read directly for this report.

---

## 1. Window topology

**Two window roles, both titled "Snipping Tool".** The app presents:

1. a compact **Shell / Home** window, and
2. an **Editor** window showing the captured image with a markup toolbar.

Both are titled **`Snipping Tool`** in the title bar, with the standard minimise / maximise /
close controls (no custom chrome). *(inspected)*
- Shell: Microsoft Support's own interface image
  [snipping-tool-opened-png.png](https://support.microsoft.com/en-us/windows/media/snipping-tool-opened-png.png)
  and ElevenForum's
  [Snipping_Tool_app.png](https://www.elevenforum.com/attachments/snipping_tool_app-png.100488/).
- Editor: the 2021 announcement image
  [SnippingAnnotate.png](https://blogs.windows.com/wp-content/uploads/prod/sites/44/2021/08/SnippingAnnotate.png),
  ElevenForum's
  [Snipping_Tool-_annotate.jpg](https://www.elevenforum.com/attachments/snipping_tool-_annotate-jpg.100491/),
  and the Store's editor screenshot
  [store screenshot 3](https://store-images.s-microsoft.com/image/apps.25076.13878650002538161.67171d0b-f781-4cf7-b23a-3f84776627b3.47c8bc3f-d5e4-4a84-9a46-a06b6ad61545).
- Microsoft's own text calls the editor simply "the Snipping Tool window": "When you capture a
  snip, it's automatically copied to the **Snipping Tool window** where you make changes, save,
  and share." — [Microsoft Support, "Use Snipping Tool to capture screenshots"](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b).

**Settings is a page inside the Shell window, not a separate window.** The Shell's `…`
(See more) ▸ **Settings** opens a Settings view whose title bar shows a **back arrow** and the
heading **Settings** — i.e. a navigation page within the app's main window. *(inspected)*
[ElevenForum settings screenshot](https://www.elevenforum.com/attachments/snipping_tool_multiple_windows-png.42619/);
the `See more ▸ Settings` path is also in the [Microsoft Support article](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b)
("select **See More** then select **Settings**").

**More than one Editor can be open at once — but only if you turn it on.** The Settings page
has a **Multiple windows** switch, described as **"Open new screenshots in different windows"**,
and it defaults **Off**. *(inspected)*
[ElevenForum, "Turn On or Off Multiple Windows for Snipping Tool"](https://www.elevenforum.com/t/turn-on-or-off-multiple-windows-for-snipping-tool-in-windows-11.9815/)
("You can turn on multiple windows in Snipping Tool to open new screenshots in different
windows instead of the same window"; the tutorial's screenshot shows the toggle **Off** by
default). So the default behaviour is one **reused** capture window; multiple Editor windows
require opting in.

**[uncertain] Shell and Editor as simultaneous windows.** Primary sources never say whether
the Shell and the Editor are two top-level windows open at the same time, or **one** window
that swaps between a Home view and an Editor view. The evidence is genuinely mixed:

- *For a single window:* the Editor repeats the Shell's whole top row (`+ New`, Snip/Record
  toggle, mode drop-down, delay drop-down), *(inspected)* and the Settings page is a
  NavigationView page in the Shell window — the shape of one window whose content switches.
- *For separate windows:* the "Multiple windows" setting is worded around screenshots opening
  in windows, and the Store capability list includes **"Close themselves and their own
  windows, and delay the closing of their app"**, confirming the app is multi-window-capable
  — [Microsoft Store, Snipping Tool](https://apps.microsoft.com/detail/9mz95kl8mr0l).

**Confidence: Medium.** The two *roles* are solid; the literal HWND relationship is not
documented. A replica is free to model them as two windows (see §9), but that should be
recorded as a replica choice, not a fidelity claim.

**Lineage / identity.** The 2021 launch post states: "In Windows 11, both the classic Snipping
Tool and Snip & Sketch apps have been replaced by a new Snipping Tool app that represents the
best experiences of both apps…" — [Windows Insider Blog, 2021-08-12](https://blogs.windows.com/windows-insider/2021/08/12/first-set-of-windows-app-updates-rolling-out-to-windows-insiders-for-windows-11/).
The package identity is still Snip & Sketch's: `Microsoft.ScreenSketch_8wekyb3d8bbwe`
(temp path cited by [ElevenForum](https://www.elevenforum.com/t/take-and-annotate-screenshots-with-snipping-tool-app-in-windows-11.497/))
and the MSIX bundle is named `Microsoft.ScreenSketch_…` (download listing in
[ElevenForum, Quick Markup thread](https://www.elevenforum.com/t/use-quick-markup-in-snipping-tool-app-in-windows-11.40007/)).

---

## 2. Shell contents

The Shell window contains, left to right, on a single toolbar row: *(inspected)*
[Microsoft Support image](https://support.microsoft.com/en-us/windows/media/snipping-tool-opened-png.png),
[ElevenForum image](https://www.elevenforum.com/attachments/snipping_tool_app-png.100488/)

1. **`+ New`** — a labelled button (blue `+`), starts a capture.
2. **Snip / Record toggle** — a camera icon and a video icon; one is selected (underline).
   Record (screen recording) was added later; the original 2021 app had no Record button
   ([2021 announcement](https://blogs.windows.com/windows-insider/2021/08/12/first-set-of-windows-app-updates-rolling-out-to-windows-insiders-for-windows-11/);
   recording announced [2022-12-08](https://blogs.windows.com/windows-insider/2022/12/08/screen-recording-in-snipping-tool-begins-rolling-out-to-windows-insiders/)).
3. **Snipping-mode drop-down** — the four modes (§3).
4. **Delay drop-down** — a clock icon; the values in §4.
5. **`…` (See more)** at the far right — holds **Settings** (and, in the Editor, Share, Open
   file, Print, etc. — §6).

Below the toolbar the Shell shows a hint line: **"Press Windows logo key + Shift + S to start
a snip"** *(inspected)*. There is **no menu bar** (no File/Edit/Tools/Help).

**No Email / Send button — confirmed.** The Win7/8.1 "Email / Send Snip" button is gone.
Sharing is instead **See more ▸ Share** ("select the **See More** menu on top right, and then
select **Share**") — [Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b).
**Confidence: High.**

**Settings page contents** (Shell ▸ See more ▸ Settings), *(inspected)*
[ElevenForum](https://www.elevenforum.com/attachments/snipping_tool_multiple_windows-png.42619/):

| Group | Setting | Default (2022 build shown) |
|---|---|---|
| Shortcuts | Print Screen key shortcut (link: "Change in Windows settings") | — |
| Snipping | **Automatically copy changes** ("Edits … automatically copied to your clipboard") | On |
| Snipping | **Automatically save screenshots** | On |
| Snipping | **Ask to save edited screenshots** | Off |
| Snipping | **Multiple windows** ("Open new screenshots in different windows") | Off |
| Snipping | **Add border to each screenshot** | Off |
| Appearance | **App theme** | (Windows theme) |
| About | Version string (screenshot shows `Snipping Tool 11.2209.2.0`) | — |

Newer builds add recording/audio settings (the [2023-08-31 post](https://blogs.windows.com/windows-insider/2023/08/31/new-updates-for-snipping-tool-and-notepad-for-windows-insiders/)
describes "new app settings … default audio recording settings"), a "Save screenshots to
OneDrive" option, and a default Screenshots folder — [ElevenForum tutorial index](https://www.elevenforum.com/t/take-and-annotate-screenshots-with-snipping-tool-app-in-windows-11.497/).

---

## 3. Mode names

The mode drop-down lists, in this order, exactly: *(inspected)*
[Microsoft Support mode image](https://support.microsoft.com/en-us/windows/media/snipping-tool-mode-png.png),
[ElevenForum mode image](https://www.elevenforum.com/attachments/new_snipping_tool-png.74763/),
[capture-bar mode image](https://blogs.windows.com/wp-content/uploads/prod/sites/44/2023/08/Paint_OverlayScreenshot.png)

1. **Rectangle**
2. **Window**
3. **Full screen**
4. **Freeform**

These match Microsoft's prose exactly ("Rectangle", "Window", "Full screen", "Freeform") —
[Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b).
The **2021** original used labelled controls instead: the mode control read **"Rectangle
mode"** with a drop-down, and the delay read **"No delay"** *(inspected)*
[2021 announcement image](https://blogs.windows.com/wp-content/uploads/prod/sites/44/2021/08/SnippingLight.png).

**Video snip / Record** is a fifth capture kind, not a "mode" in the same drop-down: it is the
video toggle / the **Record** button, with the shortcut **Win + Shift + R**
([Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b)).
The internal mode identifiers are `RectangleSnip`, `WindowSnip`, `FreeformSnip`,
`FullscreenSnip`, `RectangleRecord` — [Microsoft Learn, "Launch Snipping Tool"](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-snipping-tool).

**Confidence: High** (mode labels and order).

---

## 4. Delay

**There is a delay control, and it lives in the toolbar** as a clock icon with a drop-down
(in both the Shell and the Editor). The values, exactly as the UI labels them: *(inspected)*
[ElevenForum delay image](https://www.elevenforum.com/attachments/snipping_tool_delay-png.100494/)

- **No delay**
- **3-second delay**
- **5-second delay**
- **10-second delay**

The same three timed values appear in the app's **Start-menu jump list** as "New screenshot in
3 seconds / 5 seconds / 10 seconds" *(inspected)*
[ElevenForum Start-menu image](https://www.elevenforum.com/attachments/start_menu-2-png.100490/),
and in Microsoft's prose ("select **Delay** and then select, for example, 5 seconds") —
[Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b).
Independent corroboration for 3/5/10: [Microsoft Q&A, "Want a 3 second delay…"](https://learn.microsoft.com/en-us/answers/questions/5916092/want-a-3-second-delay-in-capturing-screenshot).

**[uncertain conflict] — Microsoft's own shortcut table says "1-5 seconds".** The same Support
page's keyboard-shortcut table lists **Alt + D — "Delay capture by 1-5 seconds"**, which does
not match the 3/5/10 UI. Treat **No delay / 3 / 5 / 10** as the well-supported UI values and
the "1-5" line as an error or stale wording. **Confidence: High** for the dropdown values;
**Low** for the "1-5" line.

---

## 5. Lifecycle

**Starting a capture shows a separate top-most capture overlay, not the app window.** With
**Win + Shift + S** the screen dims and a small floating rounded toolbar appears at the top of
the screen: camera / video toggle, mode drop-down, (later) Quick-markup button, and an `X`.
*(inspected)* [2023 combined capture bar](https://blogs.windows.com/wp-content/uploads/prod/sites/44/2023/08/Paint_OverlayScreenshot.png),
[ElevenForum Quick-markup bar](https://www.elevenforum.com/attachments/snipping_tool_quick_markup-webp.145831/).
Microsoft calls this "the snipping tool overlay" / "the capture bar" —
[Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b);
[2023-08-31 post](https://blogs.windows.com/windows-insider/2023/08/31/new-updates-for-snipping-tool-and-notepad-for-windows-insiders/)
("the combined capture bar … without having to open the app").

**Does the Shell hide, minimise, or stay? [uncertain].** No primary source states this. What is
documented is that the capture overlay is its own top-most surface and that the app window is
not part of the capture UI. The replica's choice (Shell hides during capture — ticket 11) is
consistent with the overlay, but it is **not confirmed** by a source. Note also that the
cold-start path has **no Shell window at all**: Win + Shift + S can be pressed with the app
not open, so "Shell hides and returns" cannot be the only model. **Confidence: Low.**

**After the capture the app does not always jump into the Editor.** Two documented flows exist:

- **Notification-first (default in current builds).** The screenshot is copied to the clipboard
  and a toast appears: **"Snipping Tool — Screenshot copied to clipboard / Select here to mark
  up and share."** *(inspected)* [ElevenForum notification image](https://www.elevenforum.com/attachments/snipping_tool_notification-jpg.100492/).
  Clicking the toast opens the Editor. Microsoft's 2021 post described this notification as a
  fix-in-progress ("If you have notifications turned off or Focus Assist on, you will not
  receive a notification pop-up after taking a screenshot. Your screenshot will still be copied
  to your clipboard") — [2021-08-12 post](https://blogs.windows.com/windows-insider/2021/08/12/first-set-of-windows-app-updates-rolling-out-to-windows-insiders-for-windows-11/).
- **Editor-first.** Taking a snip from the app's own **New** button opens the Editor directly.
  Users report Microsoft later removed the ability to force editor-first for the hotkey flow —
  [Microsoft Q&A 5674485](https://learn.microsoft.com/en-us/answers/questions/5674485/when-did-the-snipping-tool-force-a-capture-save-or)
  ("Snipping Tool no longer opens editor immediately after capture"; there is "no longer a
  built-in way to force 'editor opens immediately'").

**The Editor stays open after Copy or Save — yes.** A community answer: "Click on the
notification and the Snipping Tool will open, showing your current snip. **It will stay open,
allowing you to make as many new snips as you like.**" —
[ElevenForum, "Snipping Tool – Keeping Open?"](https://www.elevenforum.com/t/snipping-tool-keeping-open.35606/).
Nothing in the Support article says Copy or Save closes the window. **Confidence: Medium-High.**

**There is a toast on copy — at capture time.** The "Screenshot copied to clipboard" toast
(above) is the app's advertised copy notification. Whether a *manual* **Copy** button press in
the Editor also raises a toast is **[uncertain]** (not documented). **Confidence: High** for
the capture toast, **Low** for the manual-Copy toast.

**Auto-copy and auto-save are ON by default.** Settings defaults **Automatically copy changes**
and **Automatically save screenshots** to On (§2), and the Support article says the snip is
"automatically copied" and "automatically saved to your Screenshots folder" —
[Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b);
default save location `C:\Users\<user>\Pictures\Screenshots`
([ElevenForum](https://www.elevenforum.com/t/take-and-annotate-screenshots-with-snipping-tool-app-in-windows-11.497/)).
**This matters for ticket 11**: the ticket chose *no* auto-copy for v1, which diverges from the
Win11 default (§9).

**Quick markup (2025+) adds a deferred path.** With Quick markup active, the capture bar offers
**Capture** (Ctrl+Enter), **Save to** (Ctrl+S), **Copy only** (Ctrl+C), and "for these options,
the image will **not** be copied to your clipboard or autosaved" —
[ElevenForum, "Use Quick Markup"](https://www.elevenforum.com/t/use-quick-markup-in-snipping-tool-app-in-windows-11.40007/),
feature introduced in Snipping Tool `11.2508.24.0`. *(inspected)*
[Quick-markup capture menu](https://www.elevenforum.com/attachments/snipping_tool_quick_markup-4-webp.145835/).
**Confidence: High** for the menu labels.

---

## 6. Editor toolbar

The Editor window repeats the Shell's top-left controls (`+ New`, Snip/Record toggle, mode
drop-down, delay drop-down) and then adds the markup tools. The tool set, from the Support
article, the 2024 Shape/ruler posts, and screenshots: *(inspected)*
[ElevenForum editor](https://www.elevenforum.com/attachments/snipping_tool-_annotate-jpg.100491/),
[Store editor screenshot](https://store-images.s-microsoft.com/image/apps.25076.13878650002538161.67171d0b-f781-4cf7-b23a-3f84776627b3.47c8bc3f-d5e4-4a84-9a46-a06b6ad61545)

- **Pen** ("Ballpoint pen") — clicking it again opens colour/thickness
- **Highlighter** — colour/thickness on second click
- **Eraser** — removes added lines/shapes; **click it twice** to get "erase all ink"
- **Touch Writing** — draw with mouse/finger (needed for mouse freehand)
- **Shapes** — rectangle, oval, straight line, arrow, plus **Emoji**; fill/outline colour and
  **opacity** ([2024-02-08 post](https://blogs.windows.com/windows-insider/2024/02/08/snipping-tool-and-notepad-updates-begin-rolling-out-to-windows-insiders/);
  [2024-05-09 post](https://blogs.windows.com/windows-insider/2024/05/09/snipping-tool-and-paint-updates-begin-rolling-out-to-windows-insiders/))
- **Ruler / Protractor** — in **See more**, shortcut **Ctrl + R** (reintroduced 2024-05-09)
- **Undo / Redo** — "Select **Undo** or **Redo** to undo or redo your annotations"
  ([Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b))
- **Image crop**
- **Text Actions (OCR)** — selectable text, **Copy all text**, **Quick redact** (emails/phone
  numbers), **Redact Text** from the right-click menu, **Copy as table**, QR-code detection;
  processed locally ([2023-09-14 post](https://blogs.windows.com/windows-insider/2023/09/14/new-updates-for-snipping-tool-and-phone-link-begin-rolling-out-to-windows-insiders/);
  [2024-05-09 post](https://blogs.windows.com/windows-insider/2024/05/09/snipping-tool-and-paint-updates-begin-rolling-out-to-windows-insiders/);
  [Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b))
- **Copy** — two-sheets icon (Ctrl + C)
- **Save / Save as** — floppy icon (Ctrl + S)
- **Share** — in **See more**
- **Edit in Paint** — opens the snip in Paint
- **Zoom** — magnifier icon; **Ctrl + `+` / `-`**; **Ctrl + drag** pans
- **See more (`…`) menu** — Zoom, Show ruler, Visual Search with Bing, Share, Open file
  (Ctrl + O), Open Screenshots folder, Print (Ctrl + P), Settings *(inspected)*
- **Visual Search with Bing**, **Ask Copilot** (newer builds)
- **Print** — the Support article instead points to right-click ▸ Print in the saved folder

**No Email/Send button** in the Editor either. **Confidence: High** for the tool list,
**Medium** for exact icon order (it shifted between 2021 and 2024).

**Save formats:** the Save dialog offers **PNG, JPG, GIF** *(inspected)*
[ElevenForum save dialog](https://www.elevenforum.com/attachments/snipping_tool-save-1-jpg.6077/)
and the Microsoft learning-center page says "save the file as a PNG or JPG"
([Windows Learning Center](https://www.microsoft.com/en-us/windows/learning-center/how-to-use-snipping-tool-on-windows-screenshots-shortcuts-and-screen-recordings)).
GIF export was added later ([2025-06-19 post](https://blogs.windows.com/windows-insider/2025/06/19/gif-export-in-snipping-tool-begins-rolling-out-to-windows-insiders/)).
Default format is **[uncertain]** (not stated).

---

## 7. Exit behaviour

**Not documented. [uncertain].** No Microsoft or reputable source states what closing the Shell
does to an open Editor, or vice-versa. What can be said:

- The Store capability list includes **"Close themselves and their own windows, and delay the
  closing of their app"** — [Microsoft Store](https://apps.microsoft.com/detail/9mz95kl8mr0l) —
  i.e. the app may keep running without any window (a background/notification process), which
  is how the notification-first flow works when the app was never opened.
- There is **no save prompt by default**: **Ask to save edited screenshots** is Off (§2).
- Nothing indicates a "Shell close leaves the Editor alive" behaviour, nor the reverse.

The replica's choice (**closing the Shell exits the process and takes any open Editor with
it** — ticket 11) is plausible and not contradicted, but it is **not confirmed** by a source.
**Confidence: Low.**

---

## 8. Keyboard shortcuts the app advertises

From the Microsoft Support shortcut table and the Insider posts
([Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b)):

| Shortcut | Action | Source |
|---|---|---|
| **Win + Shift + S** | Open the overlay to capture an image | Support; [2021 post](https://blogs.windows.com/windows-insider/2021/08/12/first-set-of-windows-app-updates-rolling-out-to-windows-insiders-for-windows-11/) |
| **Win + Shift + R** | Open the overlay to record video | Support; [2022-12-08 post](https://blogs.windows.com/windows-insider/2022/12/08/screen-recording-in-snipping-tool-begins-rolling-out-to-windows-insiders/) |
| **PrtScn** | Full-screen snapshot to clipboard (Windows-mapped; can be turned off) | Support; [Keyboard shortcuts in Windows](https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec) |
| **Alt + M** | Choose a snipping mode | Support |
| **Alt + N** | New snip in the same mode as the last one | Support |
| **Shift + arrow keys** | Move the cursor to select different snip types | Support |
| **Alt + D** | Delay capture (table says "1-5 seconds" — see §4) | Support |
| **Ctrl + C** | Copy the snip to clipboard | Support |
| **Ctrl + S** | Save the snip | Support |
| **Ctrl + R** | Toggle the ruler | [2024-05-09 post](https://blogs.windows.com/windows-insider/2024/05/09/snipping-tool-and-paint-updates-begin-rolling-out-to-windows-insiders/) |
| **Ctrl + A**, **Ctrl + C** | Select/copy all text in Text Actions | [2023-09-14 post](https://blogs.windows.com/windows-insider/2023/09/14/new-updates-for-snipping-tool-and-phone-link-begin-rolling-out-to-windows-insiders/) |
| **Ctrl + O / Ctrl + P** | Open file / Print (shown in the See more menu) | Editor See more menu *(inspected)* |
| **Ctrl + `+` / `-`** | Zoom in / out | [ElevenForum](https://www.elevenforum.com/t/take-and-annotate-screenshots-with-snipping-tool-app-in-windows-11.497/) |
| **Ctrl + drag** | Pan the image | [ElevenForum](https://www.elevenforum.com/t/take-and-annotate-screenshots-with-snipping-tool-app-in-windows-11.497/) |
| **Ctrl + Enter / Ctrl + S / Ctrl + C** | Quick markup: Capture / Save to / Copy only | [ElevenForum Quick Markup](https://www.elevenforum.com/t/use-quick-markup-in-snipping-tool-app-in-windows-11.40007/) |

**Ctrl + Z / Ctrl + Y (undo/redo in the Editor) are [uncertain]** — the app has Undo/Redo
buttons, but the Support shortcut table does not list keys for them. **Confidence: Medium.**

---

## 9. Bearing on ticket 11 (replica decisions vs. the Win11 reference)

Ticket 11's fidelity caveat asked whether its lifecycle answers match the Win11 app. Status:

| Ticket 11 assumption | Research verdict |
|---|---|
| Two windows — a Shell plus an Editor | **Partly confirmed.** Two distinct roles, both titled "Snipping Tool"; Settings is a page in the Shell. Whether they are simultaneous top-level windows is **not documented**. |
| One **reused** Editor window | **Matches the default.** "Multiple windows" is Off by default, so a new capture reuses one window; turning it On allows several. |
| Shell **hides while the Overlay is up** | **Not confirmed** by any source. Consistent with the overlay being separate, but undocumented. |
| Shell and Editor **coexist** afterwards | **Not confirmed.** The app supports multiple windows, but Shell-vs-Editor coexistence is undocumented. |
| **Closing the Shell exits the process** | **Not confirmed.** Plausible; the app is a background-capable UWP. Undocumented. |
| **Delay drop-down (None / 1–5 s)** | **Diverges.** The UI is **No delay / 3 / 5 / 10 s**. Only Microsoft's shortcut table says "1-5". |
| **No Email button** | **Confirmed** — no Email/Send; Share is in See more. |
| No menu bar, toolbar buttons only | **Confirmed.** |
| **No auto-copy** in v1 | **Diverges from the reference.** Win11 **does** auto-copy (and auto-save) by default, with the "Screenshot copied to clipboard" toast. This is a deliberate replica choice, not fidelity. |
| Normal window, not topmost | **[uncertain]** for the Shell; the capture overlay *is* top-most. |

---

## Quick reference table

| Item | Best-supported answer | Confidence |
|---|---|---|
| Window titles | Both Shell and Editor titled **"Snipping Tool"** | High |
| Topology | Compact Shell (Home) + Editor; Settings is a page in the Shell | Medium-High |
| Separate simultaneous windows? | **Undocumented**; app is multi-window-capable | Low |
| Multiple Editors at once? | Yes if **Multiple windows** is On; **default Off → one reused window** | High |
| Shell controls | `+ New`, Snip/Record toggle, mode drop-down, delay drop-down, See more (Settings) | High |
| Shell hint text | "Press Windows logo key + Shift + S to start a snip" | High |
| Email/Send button | **Absent** (Share lives in See more) | High |
| Mode names | **Rectangle, Window, Full screen, Freeform** | High |
| Video | Separate **Record** toggle / Win + Shift + R; not in the mode list | High |
| Delay control | Toolbar clock drop-down | High |
| Delay values | **No delay / 3 / 5 / 10 seconds** ("1-5" only in MS's shortcut table) | High / Low |
| Capture UI | Separate top-most overlay/capture bar, not the app window | High |
| Shell during capture | **Undocumented** (hide/minimise/stay all unconfirmed) | Low |
| After capture | Notification-first by default ("Screenshot copied to clipboard"); editor-first via New | Medium-High |
| Toast on copy | Yes, on capture | High |
| Editor after Copy/Save | **Stays open** | Medium-High |
| Auto-copy / auto-save | **Both On by default** | High |
| Editor tools | Pen, Highlighter, Eraser, Touch Writing, Shapes (+Emoji), Ruler/Protractor, Undo/Redo, Crop, Text Actions (OCR/redact), Copy, Save, Share, Edit in Paint, Zoom, Print, Visual Search | High (list), Medium (order) |
| Save formats | **PNG, JPG, GIF** | Medium-High |
| Closing the Shell | **Undocumented**; no save prompt by default | Low |
| Advertised shortcuts | Win+Shift+S/R, PrtSc, Alt+M/N/D, Shift+arrows, Ctrl+C/S, Ctrl+R, Ctrl+A/C (OCR), Ctrl+O/P | High |
| Editor Ctrl+Z / Ctrl+Y | Undo/Redo buttons exist; keys **not listed** | Low |

---

## Where the Win11 app differs from the Win7/8.1 classic app

- **Window shape.** Classic = one mark-up window with a menu bar and a 7-button toolbar.
  Win11 = a compact Shell (no menu bar) plus an Editor, both titled "Snipping Tool"; a
  **Settings page** replaces the classic **Options** dialog.
- **Toolbar.** Classic: New, Save Snip, Copy, **Email/Send**, Pen, Highlighter, Eraser, plus
  Mode/Delay/Cancel on the Win10 build. Win11: New, Snip/Record toggle, mode and delay
  drop-downs, and Pen / Highlighter / Eraser / Touch Writing / Shapes / Crop / Text Actions /
  Undo / Redo / Copy / Save / Share — **no Email**, no Cancel button, no menu bar.
- **Modes.** Classic had no named modes until Win10's Mode drop-down; Win11 names them
  **Rectangle / Window / Full screen / Freeform** and adds **video recording**.
- **Delay.** Win10 classic: 1/2/3/5 s style values. Win11: **No delay / 3 / 5 / 10 s**.
- **Capture flow.** Classic opened the editor in the same window immediately and auto-copied.
  Win11 uses a **separate overlay**, then by default a **toast** ("Screenshot copied to
  clipboard") that opens the Editor; the Editor is a distinct window and can be multiplied
  with **Multiple windows**.
- **Editor extras absent from classic:** shapes/emoji, ruler & protractor, image crop, OCR
  "Text Actions" with redaction, zoom/pan, Share, Print, Edit in Paint, Visual Search.
- **Chrome:** classic was a Win32 window with a File/Edit/Tools/Help menu; Win11 is WinUI with
  rounded corners, light/dark theme honouring the system theme, and no menu bar
  ([2021-08-12 post](https://blogs.windows.com/windows-insider/2021/08/12/first-set-of-windows-app-updates-rolling-out-to-windows-insiders-for-windows-11/)).

**Lineage caveat:** Microsoft shipped the same Win32 classic app from Vista through Win10
(see [classic-snipping-tool-editor.md](classic-snipping-tool-editor.md)). The Win11 app is a
different codebase — the Snip & Sketch UWP/WinUI app renamed to "Snipping Tool" — so behaviour
does not carry over; only the name and the core modes do.
