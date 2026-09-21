# Snipping Tool in x64 assembly

A Windows Snipping Tool replica written in pure x64 MASM assembly against Win32. This glossary fixes the vocabulary the wayfinder map and the code share; it records names, not implementation.

## Language

### Capturing

**Snip**:
The captured region of the screen, owned as one cropped bitmap. A Snip is what the Editor annotates and what Copy and Save As publish.
_Avoid_: screenshot, capture, grab, clip

**Selection**:
The region the user marks on the Overlay. A Selection becomes a Snip once it is cropped out of the screen capture.
_Avoid_: region, marquee, area

**Overlay**:
The full-screen dimmed surface a Selection is marked on. It spans the virtual screen and excludes itself from capture.
_Avoid_: mask, layer, backdrop

**Pristine bitmap**:
A Snip's post-capture pixels, never drawn on. The Eraser restores from it.
_Avoid_: original, backup, master

**Working bitmap**:
A Snip's bitmap that annotations rasterise into — what the Editor shows and the encoder reads.
_Avoid_: canvas, scratch, current

### Windows

**Shell**:
The application's main window: the mode dropdown, the delay, and the command that starts a snip.
_Avoid_: main window, home

**Editor**:
The window shown after a Selection becomes a Snip, holding the Working bitmap and the annotation tools.
_Avoid_: canvas window, annotator
