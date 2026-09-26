# Snipping Tool in x64 assembly

A Windows Snipping Tool replica written in pure x64 MASM assembly against Win32. This glossary fixes the vocabulary the wayfinder map and the code share; it records names, not implementation.

## Language

### Capturing

**Snipping session**:
The span from starting a snip to the Snip landing in the Editor: the Overlay is up for its duration and the Shell is hidden.
_Avoid_: capture, snipping run

**Snip**:
The captured region of the screen, owned as one cropped bitmap. A Snip is what the Editor annotates and what Copy and Save As publish.
_Avoid_: screenshot, capture, grab, clip

**Selection**:
The region the user marks on the Overlay. A Selection becomes a Snip once it is cropped out of the screen capture.
_Avoid_: region, marquee, area

**Overlay**:
The full-screen dimmed surface a Selection is marked on. It spans the virtual screen and excludes itself from capture.
_Avoid_: mask, layer, backdrop

**Dim**:
The Overlay's translucent black layer, at which a Selection is punched out as an undimmed hole.
_Avoid_: shade, tint, scrim

**Readout**:
The opaque plate on the Overlay naming the Selection's size as `W x H`. Opaque chrome is why the Overlay presents per-pixel alpha.
_Avoid_: tooltip, label, badge

**Trace**:
The continuous path a hand draws on the Overlay in free-form mode, from press to release. A Trace becomes a Mask when the Snip is cropped.
_Avoid_: stroke, path, outline

**Mask**:
The per-pixel alpha that cuts a free-form Snip to its Trace: opaque within, absent without, partially transparent along the cut.
_Avoid_: clip, region, lasso

**Pristine bitmap**:
A Snip's post-capture pixels, never drawn on. Annotations are composited over it, and the Eraser reveals it again.
_Avoid_: original, backup, master

**Working bitmap**:
A Snip's bitmap that annotations rasterise into — what the Editor shows and the encoder reads.
_Avoid_: canvas, scratch, current

### Annotating

**Annotation**:
Ink added over a Snip by the Pen or Highlighter, held as strokes.
_Avoid_: markup, drawing, scribble

**Stroke**:
One continuous Pen or Highlighter mark, from press to release. The unit the Eraser removes and Undo reverses.
_Avoid_: line, path, mark

### Windows

**Shell**:
The application's main window: the mode dropdown, the delay, and the command that starts a snip.
_Avoid_: main window, home
**Editor**:
The window shown after a Selection becomes a Snip, holding the Working bitmap and the annotation tools.
_Avoid_: canvas window, annotator

### Approach

**Platform primitive**:
A Win32 or COM facility the OS already provides, chosen over hand-rolled code whenever one fits. GDI+ is a platform primitive for antialiased drawing.
_Avoid_: library, dependency, helper, utility
