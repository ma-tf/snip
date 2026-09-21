# PNG encoding from pure asm via COM

Label: wayfinder:research
Type: research
Status: resolved
Blocked by: none

## Question

How does a pure MASM64 program turn a 32bpp DIB into a PNG file and into clipboard data, without linking any C?

Compare the two COM routes: Windows Imaging Component (`CoCreateInstance` → `IWICImagingFactory` → `IWICBitmapFrameEncode`) and GDI+ (`GdiplusStartup` → `GdipCreateBitmapFromHBITMAP` → `GdipSaveImageToFile`). For the winner, pin down the minimal vtable call sequence, what a vtable call looks like written by hand (`mov rax, [rcx]` / `call qword ptr [rax+N]`, and which register holds `this`), how `VARIANT` / `PROPBAG2` / `IPropertyBag2` arguments must be laid out in asm, how failures surface (HRESULT vs GDI+ status), and which import libs plus which `CoInitializeEx` apartment the process needs.

Deliverable: facts written to `docs/research/png-encoding-com.md`, with a recommendation.

## Answer

**WIC wins.** Full reasoning and citations: [`docs/research/png-encoding-com.md`](../../../docs/research/png-encoding-com.md).

GDI+ (`GdiplusStartup` → `GdipCreateBitmapFromHBITMAP` → `GdipSaveImageToFile`) works and needs no COM apartment for PNG, but it forces an HBITMAP round-trip (a second full copy of the image), reports failures through a coarse `Status` enum whose constructors collapse to `OutOfMemory`/`GenericError`, and still needs `ole32` for the clipboard `IStream`. WIC encodes the DIB in place with `WritePixels`, returns an exact `HRESULT` per call, and uses one API for file and memory.

**Minimal WIC sequence** (4 interface pointers; no `IPropertyBag2` needed for default PNG):

1. `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)` — `ole32.lib` (`S_FALSE` = already init; tolerate `RPC_E_CHANGED_MODE`). Balance with `CoUninitialize` only if it returned `S_OK`.
2. `CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, &pFactory)` — use literal GUID `{CACAF262-9370-4615-A13B-9F5539DA4C0A}`; note the SDK `#define`s `CLSID_WICImagingFactory` to the v2 coclass.
3. `pFactory->CreateStream(&pStream)` — vtable `+0x70`.
4. `pStream->InitializeFromFilename(L"out.png", GENERIC_WRITE)` — `+0x78`.
5. `pFactory->CreateEncoder(&GUID_ContainerFormatPng, NULL, &pEncoder)` — `+0x40`.
6. `pEncoder->Initialize(pStream, WICBitmapEncoderNoCache)` — `+0x18`.
7. `pEncoder->CreateNewFrame(&pFrame, NULL)` — `+0x50` (`NULL` = accept defaults).
8. `pFrame->Initialize(NULL)` — `+0x18`.
9. `pFrame->SetSize(w, h)` — `+0x20`.
10. `pFrame->SetPixelFormat(&GUID_WICPixelFormat32bppBGRA)` — `+0x30`; `[in,out]` guid, verify unchanged.
11. `pFrame->WritePixels(h, w*4, w*4*h, pDIBBits)` — `+0x50`; top-down scanlines, stride `w*4`.
12. `pFrame->Commit()` — `+0x60`.
13. `pEncoder->Commit()` — `+0x58`.
14. `Release` frame, encoder, stream, factory — `+0x10`.

Clipboard: encode into an OLE growable stream (`CreateStreamOnHGlobal(NULL, FALSE, &s)`; `Initialize` accepts a plain `IStream*`), then `Stat` for the exact size, copy into a `GMEM_MOVEABLE` handle, and `SetClipboardData(RegisterClipboardFormatW(L"PNG"), hMem)`.

asm notes, all in the research doc: `this` is in **RCX**, the vtable pointer is `[[rcx]]`, method N is at `[vtable + N*8]`; `mov rax,[rcx]` / `call qword ptr [rax+OFFSET]`. `FAILED(hr)` is `js` after `test eax,eax`. `PROPBAG2` is 40 bytes (`dwType@0, vt@4, cfType@6, dwHint@8, pstrName@16, clsid@24`), `VARIANT` is 24 bytes (`vt@0`, payload union `@8`), and `IPropertyBag2::Write` is slot 4 (`+0x20`). Import libs: `windowscodecs.lib` + `ole32.lib`.
