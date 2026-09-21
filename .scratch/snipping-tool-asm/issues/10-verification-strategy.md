# Verification strategy

Label: wayfinder:grilling
Type: grilling
Status: open
Blocked by: none

## Question

How will we know any of this works?

Decide what "tested" means for a Win32 GUI program in asm: which logic gets pulled out and exercised by a console harness (crop geometry, mask building, PNG bytes — so Python can drive it and diff against golden files); how the GUI half is verified (a manual checklist vs scripted `SendInput` vs screenshot diffing); and where golden images live in the repo.
