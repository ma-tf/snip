# Stand up the build loop and a walking skeleton

Label: wayfinder:task
Type: task
Status: open
Blocked by: 01

## Question

Nothing can be decided about the shape of this program until a window opens from a build command.

Do the work: pick the repo layout (`src/`, `build/`), write `build.cmd` that invokes `vcvars64` (or the absolute `ml64` / `link` paths), assemble and link the skeleton from ticket 01, produce `snip.exe` that opens a window and exits cleanly, and settle the debug loop (WinDbg vs x64dbg vs VS, and how symbols get loaded).

Answer records: the exact build command, the layout, the debugger choice, and anything the research ticket got wrong in practice.
