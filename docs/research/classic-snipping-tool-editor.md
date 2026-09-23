# Classic Snipping Tool — annotation editor behaviour

Reference behaviour for [Annotation editor and undo model](../../.scratch/snipping-tool-asm/issues/08-annotation-editor-undo.md)
(ticket 08), gathered 2026-09-22 by a research subagent from public sources. This is
supporting evidence for the replica's editor, not a decision: the decisions live in the
ticket.

**Scope:** the Win32 desktop `SnippingTool.exe` shipped with Windows Vista / 7 / 8.x (and the
same app carried into Windows 10). This is *not* Snip & Sketch / the Win11 app. Where
Vista/Win7 and the later Win10 build of the same classic app differ, that is noted. Sources
are linked per claim; anything not directly documented is marked **[uncertain]**.

---

## 1. Toolbar layout / chrome

**Window structure (Vista/Win7/8.x):** a single "mark-up window" titled **Snipping Tool** with
a normal title bar (minimise / maximise / close), a **menu bar: File · Edit · Tools · Help**,
and one toolbar row. The toolbar buttons, left to right:

1. **New** (scissors icon, with a drop-down arrow for the snip type)
2. **Save Snip** (floppy-disk icon)
3. **Copy** (two-sheets icon)
4. **Email / Send Snip** (envelope, with a drop-down arrow for "E-mail Recipient" vs
   "E-mail Recipient (as attachment)")
5. *(separator)* **Pen** (pen icon, with a drop-down arrow)
6. **Highlighter** (yellow marker icon)
7. **Eraser** (pink eraser icon)

- Confirmed visually in a Windows 7 screenshot of the editor: [CAES/UGA, "Windows Snipping Tool – Get the Picture" (editor window screenshot)](https://oit.caes.uga.edu/windows-snipping-tool-get-the-picture) and its image [sniptool_3.jpg](https://oit.caes.uga.edu/files/2015/07/sniptool_3.jpg).
- The 2011 groovyPost walk-through (Windows 7) shows the same toolbar and the Pen drop-down: [groovyPost, "Take Screenshots with Windows 7 with the Snipping Tool"](https://www.groovypost.com/howto/howto/take-screenshots-windows-7-free-snipping-tool/) (images [clip_image006.png](https://www.groovypost.com/wp-content/uploads/2011/06/clip_image006.png), [clip_image007.png](https://www.groovypost.com/wp-content/uploads/2011/06/clip_image007.png), [clip_image008.png](https://www.groovypost.com/wp-content/uploads/2011/06/clip_image008.png), [clip_image009.png](https://www.groovypost.com/wp-content/uploads/2011/06/clip_image009.png)).
- Toolbar button functions are itemised in the Win7/8 handout: "Creates a new snipping image… Save… Copy… Email… Draw on the current image with a red, black, blue, or custom pen tool… yellow highlighter… Erase any pen or highlighter marks created." — [Bucks County CC, "Using the built-in Snipping Tool from Windows 7/8" (PDF)](https://www.bucks.edu/media/bcccmedialibrary/pdf/tlc/facstaff/Snipping-Tool.pdf).
- Microsoft's own "annotate" wording matches: "write or draw… by selecting the Pen or Highlighter buttons. Select Eraser to remove the lines you've drawn." — [Microsoft Support, "Use Snipping Tool to capture screenshots"](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b) and the archived Win7 page [archived Microsoft Support, Win7 "Use Snipping Tool to capture screen shots"](https://web.archive.org/web/20101222165014/http://windows.microsoft.com/en-US/windows7/Use-Snipping-Tool-to-capture-screen-shots).

**Windows 10 build of the classic app:** the same toolbar plus **Mode** (drop-down) and
**Delay** (drop-down) buttons, and **Cancel** is shown while a capture is armed. Users
describe it as "NEW MODE DELAY X CANCEL OPTIONS" — [Microsoft Q&A, "SNIPPING TOOL WINDOWS 10" (2021)](https://learn.microsoft.com/en-us/answers/questions/3785012/snipping-tool-windows-10). The menu bar (File/Edit/Tools/Help) remains.

**Undo/Redo buttons:** none — the toolbar has no undo/redo controls (see screenshots above).

**Window sizing:** the mark-up window opens sized to the snip, but is capped to a portion of
the screen; if the snip is larger, the image area gets **horizontal and vertical scrollbars**
(the image is *not* scaled to fit). This is clearly visible in the Win7 editor screenshot
[sniptool_3.jpg](https://oit.caes.uga.edu/files/2015/07/sniptool_3.jpg). Users also report the
window "changes size" with each snip — [Microsoft Q&A, "Snipping Tool keeps moving on top of just snipped content" (2015)](https://learn.microsoft.com/en-us/answers/questions/2669147/snipping-tool-keeps-moving-on-top-of-just-snipped). Exact cap size **[uncertain]**.

**Always-on-top:** the mark-up window is a **normal window, not a topmost/pinned window** —
there is no "always on top" option. It is brought to the front when a snip completes, but it
can be covered and must be moved manually; the 2015 thread complains it cannot be "locked"
and keeps relocating over the work area. (Contrast: the Win11 app was later criticised for
sending the editor *behind* other windows, with users noting the classic Win10 tool stayed in
the foreground — foreground focus ≠ always-on-top.) Sources:
[MS Q&A 2015](https://learn.microsoft.com/en-us/answers/questions/2669147/snipping-tool-keeps-moving-on-top-of-just-snipped);
[MS Q&A, "Snipping tool going to background – win 11" (2023)](https://learn.microsoft.com/en-us/answers/questions/1280500/snipping-tool-going-to-background-win-11).

**Auto-open / auto-copy:** after a snip, the editor opens automatically and, by default, the
snip is also placed on the clipboard (Options → *Always copy snips to the Clipboard*). —
[archived Win7 MS Support](https://web.archive.org/web/20101222165014/http://windows.microsoft.com/en-US/windows7/Use-Snipping-Tool-to-capture-screen-shots);
Options dialog shown in [sniptool_6.jpg](https://oit.caes.uga.edu/files/2015/07/sniptool_6.jpg)
and [sniptool_4.jpg](https://oit.caes.uga.edu/files/2015/07/sniptool_4.jpg).

---

## 2. Pen

**Colours offered.** The Pen button's drop-down (identical to **Tools ▸ Pen**) lists exactly:

- **Red Pen**
- **Blue Pen**
- **Black Pen**
- **Custom Pen**
- *(separator)*
- **Customize…**

The currently-selected pen is shown with a radio dot. This is visible in: the Win10 classic
**Tools ▸ Pen** screenshot ([Tools menu image](https://i.pinimg.com/originals/0a/a5/e0/0aa5e0037c608820fcd95dc8d76bf728.png)),
the Windows 7 Pen drop-down ([groovyPost clip_image006.png](https://www.groovypost.com/wp-content/uploads/2011/06/clip_image006.png)),
and the Windows 8.1 Pen drop-down ([iSunshare, "Use Snipping Tool in Windows 8/8.1"](https://www.isunshare.com/windows-8/use-snipping-tool-in-windows-8-8.1.html),
image [choose-a-pen…png](https://www.isunshare.com/images/article/windows-8/use-snipping-tool-in-windows-8-8.1/choose-a-pen-to-write-sth-on-the-snip.png)).
The default selection in the screenshots is **Blue Pen**.

**Customize dialog.** "Customize…" opens a pen-customisation dialog that lets you set
**colour, tip type/shape, and line thickness**:

- "The Pens come in a variety of colors which you can customize by clicking the customize
  button. There you can customize the Pen TIP type, line thickness, and color." —
  [groovyPost (2011)](https://www.groovypost.com/howto/howto/take-screenshots-windows-7-free-snipping-tool/).
- "The pen can be customized by selecting Tools | Pen – the size of the tip, the shape and the
  color can be modified." —
  [BellaOnline, "Using Windows Vista Snipping Tool" (archived 2009)](https://web.archive.org/web/20090305010844/http://www.bellaonline.com/articles/art59349.asp).

**How many stroke widths / pixel widths.** **[uncertain]** — no Microsoft or archival source
enumerates the width presets or gives pixel values, and no screenshot of the Customize dialog
was obtained. Observation from the screenshots: the default blue pen stroke measures roughly
**2–3 px thick** in the 399×396 groovyPost editor capture (a pixel scan of
[clip_image008.png](https://www.groovypost.com/wp-content/uploads/2011/06/clip_image008.png)
found typical vertical run-lengths of 2–3 px across the strokes); treat this as a rough,
scale-dependent observation, not a spec.

**Antialiasing / smoothness.** **[uncertain]** — undocumented. It is a Win32/GDI-era app and
the strokes in screenshots look smooth, but no primary source confirms anti-aliased rendering.

---

## 3. Highlighter

**Colours.** Most sources say the classic highlighter is **yellow and not user-changeable**:
"Draw on the current image with a yellow highlighter"
([Bucks PDF](https://www.bucks.edu/media/bcccmedialibrary/pdf/tlc/facstaff/Snipping-Tool.pdf));
"the highlighter color can not be changed"
([BellaOnline, archived](https://web.archive.org/web/20090305010844/http://www.bellaonline.com/articles/art59349.asp));
a 2010 MS Q&A thread on changing the highlighter colour confirms it can't be changed in the
classic tool ([Microsoft Q&A, "can the highlighter color be changed in the snipping tool?"](https://learn.microsoft.com/en-us/answers/questions/2418712/can-the-highlighter-color-be-changed-in-the-snippi)).
The Tools menu shows **Highlighter** with **no sub-menu and no drop-down**, consistent with no
options. **[uncertain conflict]:** one Windows 8.1 tutorial screenshot shows a *green* highlight
([iSunshare highlighter image](https://www.isunshare.com/images/article/windows-8/use-snipping-tool-in-windows-8-8.1/use-highlighter-tool-to-highlight-sth-on-the-snip.png)).
Unreconciled; it may be a mislabelled pen stroke or a version/locale difference. Treat
"yellow, fixed" as the well-supported default and the green screenshot as an outlier.

**Width.** **[uncertain]** — no documented presets; visually the highlighter is much wider than
the pen (a broad band), but no pixel value was found.

**Compositing (opaque vs translucent).** It is **translucent** — the underlying screenshot
shows through the highlight. Pixel-sampling the Win8.1 screenshot above, the highlight over the
blue desktop is a blend (≈ RGB 70,165,0) rather than a flat opaque colour, indicating a
semi-transparent overlay. The exact alpha value is **[uncertain]** (the screenshot may have been
resized/compressed). It composites *over* the image; it does not replace it.

---

## 4. Eraser

**What it erases.** The eraser removes **only the pen/highlighter annotations**, never the
underlying screenshot pixels:

- "The eraser's functionality is to remove the marking that you make using Pen or the
  Highlighter in the snipping tool. It will not erase the screen captured." —
  [Microsoft Q&A, "How to use eraser with snipping tool" (2021)](https://learn.microsoft.com/en-us/answers/questions/3788243/how-to-use-eraser-with-snipping-tool).
- "ERASE deletes the pen or highlighter additions… To erase portions of the original snip you
  need to use Paint or a photo editing program." —
  [PC Review forum, "How to erase in Snipping Tool" (2008)](https://www.pcreview.co.uk/threads/how-to-erase-in-snipping-tool.3414068/).
- "Select Eraser to remove the lines you've drawn." —
  [Microsoft Support](https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b);
  "Erase any pen or highlighter marks created" —
  [Bucks PDF](https://www.bucks.edu/media/bcccmedialibrary/pdf/tlc/facstaff/Snipping-Tool.pdf);
  "the eraser only works on added the pen and highlighter" —
  [BellaOnline, archived](https://web.archive.org/web/20090305010844/http://www.bellaonline.com/articles/art59349.asp).

**Granularity (object vs pixel).** The described interaction is *click a mark to delete it, or
drag across marks to delete several* — "click the drawings that you don't want, they will
disappear. Alternatively you can click and drag over all the drawings you don't want"
([MS Q&A 2021](https://learn.microsoft.com/en-us/answers/questions/3788243/how-to-use-eraser-with-snipping-tool)).
This reads as an **annotation/stroke ("object") eraser** operating on the ink layer, not a
pixel brush restoring the original bitmap. **[uncertain]**: no primary source states explicitly
whether it removes whole strokes vs. partial stroke geometry; it is definitely *not* erasing
the screenshot.

**Size options.** None — the Eraser button has no drop-down and there is no Eraser sub-menu in
the Tools menu (screenshots above). **[certain]** it does not expose brush-size choices in the
classic tool.

---

## 5. Undo / Redo

**The thinnest area of documentation — treat everything here as [uncertain].**

- The editor **has an Edit menu** (File · Edit · Tools · Help) — visible in every classic
  editor screenshot, e.g. [sniptool_3.jpg](https://oit.caes.uga.edu/files/2015/07/sniptool_3.jpg)
  and [iSunshare menu-bar image](https://www.isunshare.com/images/article/windows-8/use-snipping-tool-in-windows-8-8.1/all-functions-included-in-menu-bar-tabs.png).
  A tutorial notes the toolbar functions are also available under File/Edit/Tools —
  [iSunshare](https://www.isunshare.com/windows-8/use-snipping-tool-in-windows-8-8.1.html).
- There are **no Undo/Redo buttons** on the toolbar (screenshots).
- No Microsoft, archived, or reputable source was found that documents: the depth of the undo
  stack; what counts as one step; whether Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z are bound; whether a
  Redo command exists; or whether redo is cleared on a new stroke. The archived Win7
  keyboard-shortcut list (Alt+M, Alt+N, Shift+arrows, Alt+D, Ctrl+C, Ctrl+S) does **not** list
  any undo/redo shortcut —
  [archived Win7 MS Support](https://web.archive.org/web/20101222165014/http://windows.microsoft.com/en-US/windows7/Use-Snipping-Tool-to-capture-screen-shots)
  — but its absence there is weak evidence, not proof.
- **Practical guidance for a replica:** the safest reading is that the classic editor offered,
  at most, a modest undo of annotation operations via the Edit menu, with no dedicated Redo UI.
  Do not assume unbounded undo, and do not assume Redo exists.

---

## 6. Copy / Save As behaviour

**Copy keeps the editor open.** Clicking **Copy** places the annotated image on the clipboard
and the mark-up window **stays open**; you can then Email, Save, or click New, all from the
same window. The Windows 8.1 walk-through performs exactly this sequence — Copy, then Email,
then Save, then New — without the window closing
([iSunshare Tip 7](https://www.isunshare.com/windows-8/use-snipping-tool-in-windows-8-8.1.html)).
There is **no confirmation toast** in the classic app (the modern Win11 tool added a
"Screenshot copied to clipboard" notification; that is not classic behaviour). Note the default
**Options ▸ Always copy snips to the Clipboard** means a copy also happens automatically the
moment the snip is taken, independent of the Copy button
([archived Win7 MS Support](https://web.archive.org/web/20101222165014/http://windows.microsoft.com/en-US/windows7/Use-Snipping-Tool-to-capture-screen-shots)).

**Save As uses the standard Windows file dialog.** **File ▸ Save As** (or the Save Snip
toolbar button) opens the ordinary Windows "Save As" dialog with a **File name** field
(defaults to `Capture`) and a **Save as type** drop-down. Offered types (in this order):
**Portable Network Graphic (PNG)**, **GIF file**, **JPEG file**, **Single file HTML (MHT)** —
visible in the Win7 dialog screenshot [sniptool_5.jpg](https://oit.caes.uga.edu/files/2015/07/sniptool_5.jpg);
also documented by [Wikipedia](https://en.wikipedia.org/wiki/Snipping_Tool) and the
[archived Win7 FAQ](https://web.archive.org/web/20101223153715/http://windows.microsoft.com/en-us/windows7/Snipping-Tool-frequently-asked-questions)
("save a snip as an HTML, PNG, GIF, or JPEG file").

**Default format/extension.** Generally **PNG** (the first entry) on first use; the dialog then
tends to remember the last-used type. Sources conflict slightly (some users saw JPEG persist) —
[Microsoft Q&A, "Snipping tool – change default back to save as jpg"](https://learn.microsoft.com/en-us/answers/questions/2768074/snipping-tool-change-default-back-to-save-as-jpg).
Treat "PNG first/default, last-used remembered" as the best-supported reading; **[uncertain]**
on exact persistence semantics.

**Does Copy ever close the tool?** In the classic app, **no** — neither Copy nor Save closes the
editor (you close it with the window X / Alt+F4). The "Copy closes/ends the session" behaviour
belongs to the modern Win11 quick-markup flow, not the classic tool.

---

## 7. Internal representation (vector vs rasterised)

**Undocumented — Microsoft never published how the classic editor stores annotations.** There is
no Microsoft Learn / MSDN / archival doc describing it. What can be inferred:

- The **eraser removes annotations but not the screenshot**, and annotations can be added/removed
  repeatedly before the final rasterised save (PNG/GIF/JPEG/MHT) —
  [MS Q&A eraser](https://learn.microsoft.com/en-us/answers/questions/3788243/how-to-use-eraser-with-snipping-tool);
  save formats per [Wikipedia](https://en.wikipedia.org/wiki/Snipping_Tool). This is consistent
  with **annotations held as a separate ink layer (stroke objects) composited over the captured
  bitmap at save/copy time**, i.e. not baked into the screenshot during editing.
- The existence of distinct, selectable **"pens"** (Red/Blue/Black/Custom) and a stroke-oriented
  eraser also point to stroke objects rather than free pixels.
- **No primary source confirms vector vs rasterised**, so mark this as an **inference only
  [uncertain]**. If exact fidelity matters, verify against the binary.

---

## Quick reference table

| Item | Best-supported answer | Confidence |
|---|---|---|
| Editor chrome | Title bar + File/Edit/Tools/Help menu + toolbar: New, Save Snip, Copy, Email, Pen, Highlighter, Eraser | High |
| Win10 classic adds | Mode, Delay, Cancel on toolbar | High |
| Window sizing | Sized to snip, capped, scrollbars for large snips; no zoom | Medium |
| Always-on-top | No — normal window, not topmost | Medium-High |
| Pen colours | Red, Blue, Black, Custom + "Customize…" | High |
| Pen default | Blue | Medium |
| Pen widths / px | Customize dialog has tip type + line thickness; **count/pixels undocumented**; default ≈2–3 px observed | Low |
| Pen AA | Undocumented | Low |
| Highlighter colour | Fixed yellow (one green outlier screenshot) | Medium |
| Highlighter width | Undocumented | Low |
| Highlighter compositing | Translucent overlay, content shows through | Medium |
| Eraser scope | Annotation ink only; never the screenshot | High |
| Eraser granularity | Click/drag to remove marks (object-style) | Medium |
| Eraser sizes | None | High |
| Undo depth / redo | **Undocumented**; no toolbar buttons; possibly Edit-menu undo only | Low |
| Copy closes editor? | No — stays open, no toast | Medium-High |
| Save As | Standard dialog; PNG/GIF/JPEG/MHT; default PNG | High |
| Internal representation | Undocumented; likely separate ink layer (inference) | Low |

**Caveat on the "classic" lineage:** Microsoft shipped the *same* Win32 app across Vista→Win10
with minor UI additions (Mode/Delay/Cancel). A replica targeting specifically Win7/8.1 uses the
7-button toolbar without Mode/Delay.
