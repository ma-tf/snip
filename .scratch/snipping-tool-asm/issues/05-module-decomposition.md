# Module decomposition and file layout

Label: wayfinder:grilling
Type: grilling
Status: open
Blocked by: 01

## Question

How is the assembly split into units, and where are the seams?

A Snipping Tool in asm is several thousand lines: capture, DIB handling, the overlay, the selection state machine, the editor's tools, the encoder, the shell. Decide the file/unit boundaries; what each unit's interface is (what a caller must know); whether units assemble as one module or several `.obj`s linked together; how shared data is exposed (globals in a common segment vs accessors); and how pure logic — crop geometry, mask building, encoders — stays separable from Win32 calls so it can be tested. `codebase-design` vocabulary may help.
