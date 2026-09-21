# Verification strategy

Label: wayfinder:grilling
Type: grilling
Status: open
Blocked by: none

## Question

How will we know any of this works?

Decide what "tested" means for a Win32 GUI program in asm: which logic gets pulled out and exercised by a console harness (crop geometry, mask building, PNG bytes — so Python can drive it and diff against golden files); how the GUI half is verified (a manual checklist vs scripted `SendInput` vs screenshot diffing); and where golden images live in the repo.

Account for the cases this machine cannot reproduce, which the capture research flagged as documentation-only: mixed DPI across monitors, monitors at negative virtual origins, HDR, DRM-protected content, and exclusive-fullscreen apps. For each, decide whether it gets a code path we reason about, a mitigation, or a documented limitation.
