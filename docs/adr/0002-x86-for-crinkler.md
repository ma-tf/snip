# Target x86 so the size build can be compressed by Crinkler

`snip.exe` is built as 32-bit x86 MASM (stdcall) and runs under WOW64, rather than as a native x64 image. The reason is the size build: the project wants a small artifact, and the only mature compressing linker for Windows — Crinkler — does not accept x64 objects and its owner states there are no plans to support them. Crinkler hash-imports DLL functions (four bytes each instead of a full import table) and compresses the image behind a self-extracting stub, taking the Shell-only binary from 4,096 bytes linked to **1,038 bytes**. That is roughly 3.5× smaller than the best x64 technique available (a 40-byte DOS stub, 3,584 bytes), and unlike the stub it removes the import table too. Functionally the app is unaffected: per-monitor DPI v2, `BitBlt`/`CAPTUREBLT`, `PrintWindow(PW_RENDERFULLCONTENT)`, `UpdateLayeredWindow`, `WDA_EXCLUDEFROMCAPTURE`, GDI+, WIC and COM all exist in 32-bit and run under WOW64 on Windows 11, and the app's working set is small enough that the 2 GB address space is not a practical limit.

## Evidence

Crinkler rejected the real x64 object with `Unsupported file type`. The source confirms it: `CoffObjectLoader::Clicks` requires machine `IMAGE_FILE_MACHINE_I386`, only `IMAGE_REL_I386_*` relocations are handled, and `main.cpp` skips any module whose PE magic is not `IMAGE_NT_OPTIONAL_HDR32_MAGIC`. Every object in Crinkler's own test suite is i386. Asked directly about x64 (issue #1), the maintainer replied: *"Crinkler doesn't support x64… We have no current plans for x64 support. For the use case we are targeting (<=8kb intros), x64 is still not that compelling."*

The x86 port was measured as a throwaway spike before this decision: both modules assembled and linked, the debug build ran and exited 0, and the Crinkler build ran and exited 0 at 1,038 bytes.

## Considered Options

- **Stay x64, adopt the 40-byte DOS stub (3,584 B)** — free, link-only, keeps native x64 and the existing conventions, but leaves the ~700-byte import table and the remaining ~2.5 KB of code uncompressed. This was the recommendation before Crinkler was considered.
- **Stay x64 and hand-roll a depressor** — would need an x64 self-extractor that is itself tiny enough to be worth it, and it is a lot of bespoke machinery. Contradicts the project's "small, understandable units" value.
- **Port only the size artifact to x86 and keep an x64 main build** — rejects on cost: two ABIs and two copies of every module, forever.
- **Move to ARM64 or another target** — Crinkler has no support either, and the platform story is worse.

## Consequences

The whole app is x86, not just the size build. The debug build is x86 too, but stays fully debuggable: `link /debug` still emits a PDB and WinDbg still loads it. The x64 conventions die with the target — there is no `PROC FRAME`/`.pushreg`/`.allocstack` unwind boilerplate and no `.pdata`; SEH is the `fs:[0]` chain. Argument passing moves to `INVOKE` over typed `PROTO`s, which removed the hand-laid twelve-argument `CreateWindowExW` block and made the source shorter, not longer.

Two costs are accepted and recorded:

- **Crinkler's size output can never be debugged.** No PDB, no symbols; it is a shipping artifact, never the working build.
- **The size build has a ceiling and an antivirus hazard.** Crinkler 3.0 limits uncompressed size to 64 KB per part, and MASM funnels all `.code` into one section, so the finished tool's code must fit under 64 KB or `build.cmd size` will stop linking. Separately, Defender quarantined the `TINYHEADER` variant of the output within a second of the build writing it; TINYHEADER is therefore not used, but the normal output remains subject to heuristic detection. The linked `debug` build is the fallback if either bites.

If Crinkler ever ships x64 support, or the app outgrows the part limit, this ADR can be superseded by reverting to the x64 sources (the pre-port tree is recorded in the ticket history) and taking the DOS-stub route instead.
