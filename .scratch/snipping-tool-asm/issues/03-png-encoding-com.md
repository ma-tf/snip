# PNG encoding from pure asm via COM

Label: wayfinder:research
Type: research
Status: open
Blocked by: none

## Question

How does a pure MASM64 program turn a 32bpp DIB into a PNG file and into clipboard data, without linking any C?

Compare the two COM routes: Windows Imaging Component (`CoCreateInstance` → `IWICImagingFactory` → `IWICBitmapFrameEncode`) and GDI+ (`GdiplusStartup` → `GdipCreateBitmapFromHBITMAP` → `GdipSaveImageToFile`). For the winner, pin down the minimal vtable call sequence, what a vtable call looks like written by hand (`mov rax, [rcx]` / `call qword ptr [rax+N]`, and which register holds `this`), how `VARIANT` / `PROPBAG2` / `IPropertyBag2` arguments must be laid out in asm, how failures surface (HRESULT vs GDI+ status), and which import libs plus which `CoInitializeEx` apartment the process needs.

Deliverable: facts written to `docs/research/png-encoding-com.md`, with a recommendation.
