# PNG encoding from pure asm via COM

Ticket: `.scratch/snipping-tool-asm/issues/03-png-encoding-com.md`
Status: resolved
Scope: turn a 32bpp top-down DIB into (a) a PNG file and (b) PNG bytes for the
clipboard, from a pure MASM64 program, without linking a C/C++ translation unit.

All facts below were taken from primary sources: Microsoft Learn API reference
pages and the Windows SDK headers installed on this machine
(`10.0.26100.0` / `10.0.28000.0`). Every non-obvious claim is cited. Sources are
listed at the bottom.

## TL;DR

**Use WIC (Windows Imaging Component).** It encodes a 32bpp DIB directly with
`IWICBitmapFrameEncode::WritePixels` — no HBITMAP round-trip, no GDI object
lifetime — and reports precise `HRESULT`s. GDI+ works but forces you to build an
HBITMAP (or a second bitmap object), reports failures through a small `Status`
enum where `OutOfMemory` is documented to mean "constructor failed for some
reason", and still needs `ole32` for the clipboard stream.

WIC needs exactly **one** `CoCreateInstance` and **four** interface pointers
(factory → stream → encoder → frame), **no** `IPropertyBag2` if you accept the
default PNG encoder options. The whole operation is about 18 calls: 13 to
initialise and encode, 4 `Release`s, and 1 `CoUninitialize`.

> Note: GDI+ has its own in-box PNG encoder and does not itself need COM for PNG,
> but its own `GdiplusStartupInputEx` header comment says its Heif/Avif codecs
> "require COM to be initialized" — both stacks sit on the same Windows imaging
> substrate. Choosing WIC removes a layer rather than adding one.

## The two routes side by side

| Dimension | WIC (`windowscodecs.lib` + `ole32.lib`) | GDI+ (`gdiplus.lib`) |
| --- | --- | --- |
| Entry point | `CoCreateInstance(CLSID_WICImagingFactory, …, IID_IWICImagingFactory, …)` | `GdiplusStartup(&token, &input, NULL)` |
| COM objects to manage | 1 coclass + up to 4 interfaces (factory, stream, encoder, frame) | none (flat C exports) |
| vtable calls to write by hand | ~10–13 | 0 (plain imports) |
| Source of pixels | `WritePixels` copies your DIB scanlines directly | `GdipCreateBitmapFromHBITMAP` needs an HBITMAP |
| Extra GDI work | none | `CreateDIBSection` + `memcpy` + `DeleteObject` (or `GdipCreateBitmapFromScan0`) |
| Encoder selection | `GUID_ContainerFormatPng` constant | CLSID must be looked up or hardcoded `{557CF406-…}` |
| Error reporting | `HRESULT` per call (exact code) | `Status` enum (22 values; constructors collapse to `OutOfMemory`/`GenericError`) |
| COM apartment needed | yes — `CoInitializeEx` on each using thread | no (for PNG); `ole32` stream still needed for clipboard |
| File output | `IWICStream::InitializeFromFilename` opens the file itself | `GdipSaveImageToFile` takes a filename |
| Memory/clipboard output | `CreateStreamOnHGlobal` → `GetHGlobalFromStream` | `GdipSaveImageToStream` over an `IStream` |
| Import libs | `windowscodecs.lib`, `ole32.lib` | `gdiplus.lib`, `ole32.lib` (for stream), `gdi32.lib` |
| Approx. hand-written asm | 4 object slots + a vtable-offset table + per-call `HRESULT` checks | ~6 flat calls + HBITMAP plumbing + CLSID fetch |

Both are in-box on Windows 11. Neither needs an installer.

---

## Route A — WIC (recommended)

### Constants you must have in asm

From `wincodec.h` (`DEFINE_GUID`) and MS Learn:

| Symbol | Value | Source |
| --- | --- | --- |
| `CLSID_WICImagingFactory` | `{CACAF262-9370-4615-A13B-9F5539DA4C0A}` | `wincodec.h` |
| `CLSID_WICImagingFactory2` | `{317D06E8-5F24-433D-BDF7-79CE68D8ABC2}` | `wincodec.h` |
| `IID_IWICImagingFactory` | `{EC5EC8A9-C395-4314-9C77-54D7A935FF70}` | `wincodec.h` (`wincodec.idl`) |
| `GUID_ContainerFormatPng` | `{1B7CFAF4-713F-473C-BBCD-6137425FAEAF}` | `wincodec.h`, PNG Format Overview |
| `CLSID_WICPngEncoder` | `{27949969-876A-41D7-9447-568F6A35A4DC}` | PNG Format Overview |
| `GUID_WICPixelFormat32bppBGRA` | `{6FDDC324-4E03-4BFE-B185-3D77768DC90F}` | `wincodec.h` |
| `GUID_WICPixelFormat32bppBGR` | `{6FDDC324-4E03-4BFE-B185-3D77768DC90E}` | `wincodec.h` |
| `CLSCTX_INPROC_SERVER` | `0x1` | `wtypesbase.h` |
| `WICBitmapEncoderNoCache` | `0x2` | `wincodec.h` |
| `GENERIC_WRITE` | `0x40000000` | `winnt.h` |

> **SDK quirk — read this before you hardcode the factory GUID.** The installed
> `wincodec.h` declares both `CLSID_WICImagingFactory`
> (`{CACAF262-9370-4615-A13B-9F5539DA4C0A}`) and `CLSID_WICImagingFactory2`
> (`{317D06E8-5F24-433D-BDF7-79CE68D8ABC2}`), then adds
> `#define CLSID_WICImagingFactory CLSID_WICImagingFactory2`, which redirects C
> *source* to the v2 coclass. Both coclasses are registered and both implement
> `IWICImagingFactory`. Recommendation for asm: put the 16 literal bytes of
> `{CACAF262-…}` in your own `.data` and ask for `IID_IWICImagingFactory`, so the
> code does not depend on which of the two symbols your `link.exe` resolves.

### The minimum call sequence (PNG file from a 32bpp top-down DIB)

`FAILED(hr)` = `hr < 0` (`js` after `test eax,eax`). Every step is guarded by
the previous `HRESULT`.

1. `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)`
   — needs `ole32.lib`. Treat `S_OK` and `S_FALSE` as success; if it returns
   `RPC_E_CHANGED_MODE`, COM is already initialised on this thread (possibly
   MTA) and WIC still works, so continue and do **not** `CoUninitialize` at the
   end. (CoInitializeEx doc.)
2. `CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, &pFactory)`
   — `CLSCTX_INPROC_SERVER` avoids any proxy/marshalling; WIC is in `Windowscodecs.dll`.
3. `pFactory->CreateStream(&pStream)` — vtable `+0x70`.
4. `pStream->InitializeFromFilename(L"out.png", GENERIC_WRITE)` — `+0x78`.
5. `pFactory->CreateEncoder(&GUID_ContainerFormatPng, NULL, &pEncoder)` — `+0x40`.
   `NULL` vendor = no preference.
6. `pEncoder->Initialize(pStream, WICBitmapEncoderNoCache)` — `+0x18`.
7. `pEncoder->CreateNewFrame(&pFrame, NULL)` — `+0x50`.
   **Passing `NULL` for `ppIEncoderOptions` is explicitly supported**: "It is
   also possible to eliminate the property bag when no encoder options are being
   considered… `CreateNewFrame(&piBitmapFrame, 0)` … `Initialize(0)`"
   (Encoding Overview). PNG's defaults (non-interlaced, unspecified filter) are
   what a screenshot wants.
8. `pFrame->Initialize(NULL)` — `+0x18`.
9. `pFrame->SetSize(width, height)` — `+0x20`.
10. `pFrame->SetPixelFormat(&guid)` — `+0x30`, with a **writable** copy of
    `GUID_WICPixelFormat32bppBGRA`. This parameter is `[in, out]`: the codec
    overwrites the GUID with the closest format it will actually use. Compare it
    afterwards; if it is unchanged you may `WritePixels` your DIB bytes as-is.
    (SetPixelFormat doc.)
11. `pFrame->WritePixels(height, width*4, width*4*height, pDIBBits)` — `+0x50`.
    Row 0 first (top-down), stride = `width*4`, buffer = `height*stride`.
    "Successive WritePixels calls are assumed to be sequential scan-line
    access." (WritePixels doc.) A 32bpp BI_RGB DIB is already BGRA byte order,
    so it matches `32bppBGRA`; alpha is preserved.
12. `pFrame->Commit()` — `+0x60`.
13. `pEncoder->Commit()` — `+0x58`. This closes/flushes the stream.
14. `Release()` each interface in reverse order (frame, encoder, stream,
    factory) — vtable `+0x10`.
15. `CoUninitialize()` if step 1 returned `S_OK`.

That is the whole encoder. No `IWICBitmap`, no `IWICFormatConverter`, no
`IPropertyBag2`, no `IWICStream` beyond `InitializeFromFilename`.

### Vtable offsets (x64, 8 bytes/slot)

Every interface derives from `IUnknown`, so slots 0–2 are
`QueryInterface`/`AddRef`/`Release` at `0x00`/`0x08`/`0x10`. The offsets below
are taken from the C-style `*Vtbl` structs in
`…\um\wincodec.h` and `…\um\ocidl.h` — **not** from the Learn method tables,
which are alphabetical and therefore misleading.

`IWICImagingFactory` (vtable at header line 7803):

| Slot | Offset | Method |
| --- | --- | --- |
| 3 | `0x18` | `CreateDecoderFromFilename` |
| 4 | `0x20` | `CreateDecoderFromStream` |
| 5 | `0x28` | `CreateDecoderFromFileHandle` |
| 6 | `0x30` | `CreateComponentInfo` |
| 7 | `0x38` | `CreateDecoder` |
| 8 | `0x40` | **`CreateEncoder`** |
| 9 | `0x48` | `CreatePalette` |
| 10 | `0x50` | `CreateFormatConverter` |
| 11 | `0x58` | `CreateBitmapScaler` |
| 12 | `0x60` | `CreateBitmapClipper` |
| 13 | `0x68` | `CreateBitmapFlipRotator` |
| 14 | `0x70` | **`CreateStream`** |
| 15 | `0x78` | `CreateColorContext` |
| 16 | `0x80` | `CreateColorTransformer` |
| 17 | `0x88` | `CreateBitmap` |
| 18 | `0x90` | `CreateBitmapFromSource` |
| 19 | `0x98` | `CreateBitmapFromSourceRect` |
| 20 | `0xA0` | `CreateBitmapFromMemory` |
| 21 | `0xA8` | `CreateBitmapFromHBITMAP` |
| 22 | `0xB0` | `CreateBitmapFromHICON` |
| 23 | `0xB8` | `CreateComponentEnumerator` |
| 24 | `0xC0` | `CreateFastMetadataEncoderFromDecoder` |
| 25 | `0xC8` | `CreateFastMetadataEncoderFromFrameDecode` |
| 26 | `0xD0` | `CreateQueryWriter` |
| 27 | `0xD8` | `CreateQueryWriterFromReader` |

`IWICStream` (line 3116: 3 IUnknown + 2 `ISequentialStream` + 9 `IStream` + 4 `IWICStream`):

| Offset | Method |
| --- | --- |
| `0x18` | `Read` |
| `0x20` | `Write` |
| `0x28` | `Seek` |
| `0x30` | `SetSize` |
| `0x38` | `CopyTo` |
| `0x40` | `Commit` |
| `0x48` | `Revert` |
| `0x50` | `LockRegion` |
| `0x58` | `UnlockRegion` |
| `0x60` | `Stat` |
| `0x68` | `Clone` |
| `0x70` | `InitializeFromIStream` |
| `0x78` | **`InitializeFromFilename`** |
| `0x80` | `InitializeFromMemory` |
| `0x88` | `InitializeFromIStreamRegion` |

`IWICBitmapEncoder` (line 3749):

| Offset | Method |
| --- | --- |
| `0x18` | **`Initialize`** |
| `0x20` | `GetContainerFormat` |
| `0x28` | `GetEncoderInfo` |
| `0x30` | `SetColorContexts` |
| `0x38` | `SetPalette` |
| `0x40` | `SetThumbnail` |
| `0x48` | `SetPreview` |
| `0x50` | **`CreateNewFrame`** |
| `0x58` | **`Commit`** |
| `0x60` | `GetMetadataQueryWriter` |

`IWICBitmapFrameEncode` (line 3943):

| Offset | Method |
| --- | --- |
| `0x18` | **`Initialize`** |
| `0x20` | **`SetSize`** |
| `0x28` | `SetResolution` (takes `double`, `double` → XMM0/XMM1) |
| `0x30` | **`SetPixelFormat`** (`[in,out]` GUID*) |
| `0x38` | `SetColorContexts` |
| `0x40` | `SetPalette` |
| `0x48` | `SetThumbnail` |
| `0x50` | **`WritePixels`** |
| `0x58` | `WriteSource` |
| `0x60` | **`Commit`** |
| `0x68` | `GetMetadataQueryWriter` |

`IPropertyBag2` (line 6434) — only needed if you set encoder options:

| Offset | Method |
| --- | --- |
| `0x18` | `Read` |
| `0x20` | `Write` |
| `0x28` | `CountProperties` |
| `0x30` | `GetPropertyInfo` |
| `0x38` | `LoadObject` |

### What a hand-written vtable call looks like

`this` is the first integer argument, so it goes in **`RCX`** under the Windows
x64 ABI. A COM object's first 8 bytes are its `lpVtbl` pointer, so the method
pointer is `[[rcx] + slot*8]`. Integer args 2–4 go in `RDX`, `R8`, `R9`; the
5th and later go on the stack after 32 bytes (`20h`) of shadow space. The caller
must keep `RSP` 16-byte aligned **at the `call`**. (`RCX`/`RDX`/`R8`/`R9`/`RAX`/
`R10`/`R11` are volatile — keep your interface pointers in `RBX`/`RSI`/`RDI`/
`R12`–`R15`.)

```asm
; --- simple 3-argument call -----------------------------------------------
; pFactory->CreateEncoder(&GUID_ContainerFormatPng, NULL, &pEncoder)
;   rcx = this, rdx = REFGUID (pointer to 16 bytes), r8 = vendor (NULL)
;   returns HRESULT in eax
    sub  rsp, 20h                 ; shadow space
    mov  rcx, r12                 ; r12 = IWICImagingFactory*
    lea  rdx, g_ContainerFormatPng
    xor  r8d, r8d
    mov  rax, [rcx]               ; rax = lpVtbl  (first field of *this)
    call qword ptr [rax+40h]      ; CreateEncoder, slot 8
    add  rsp, 20h
    test eax, eax
    js   fail                     ; FAILED(hr)

; --- call with a 5th (stack) argument -------------------------------------
; pFrame->WritePixels(height, stride, stride*height, pBits)
;   rcx=this, rdx=height, r8=stride, r9=cbBufferSize, [rsp+20h]=pBits
;   RSP is assumed 16-byte aligned before the "sub".
    sub  rsp, 30h                 ; 20h shadow + 8h stack arg, keeps alignment
    mov  rcx, r13                 ; r13 = IWICBitmapFrameEncode*
    mov  edx, r14d                ; height
    mov  r8d,  r15d               ; stride = width*4
    mov  r9d,  r10d               ; stride*height
    mov  [rsp+20h], rbx           ; pBits
    mov  rax, [rcx]
    call qword ptr [rax+50h]      ; WritePixels, slot 10
    add  rsp, 30h
    test eax, eax
    js   fail

; --- CoCreateInstance is 5 args too ---------------------------------------
; HRESULT CoCreateInstance(rclsid, pUnkOuter, dwClsContext, riid, ppv)
    sub  rsp, 30h
    lea  rcx, g_CLSID_WICImagingFactory
    xor  edx, edx                 ; pUnkOuter = NULL
    mov  r8d, 1                   ; CLSCTX_INPROC_SERVER
    lea  r9,  g_IID_IWICImagingFactory
    lea  rax, g_pFactory
    mov  [rsp+20h], rax           ; ppv
    call CoCreateInstance
    add  rsp, 30h

fail:
    ; HRESULT is negative on failure; preserve it for the caller / log it
```

Alignment note: a function body is entered with `RSP % 16 == 8`. If you have
already pushed an odd number of registers (e.g. `push rbp`), `RSP % 16 == 0` and
`sub rsp, 20h` is enough. From a bare entry, `sub rsp, 20h` leaves `RSP % 16 == 8`
and the callee sees a misaligned stack; use `sub rsp, 28h` (no stack args) or
`sub rsp, 30h` (one stack arg) instead. The snippets above assume an aligned
`RSP` and say so.

### GUID / `PROPBAG2` / `VARIANT` layout in memory (if you ever set options)

Default PNG is fine, so this section is reference only. PNG supports exactly two
encoder options (PNG Format Overview, Encoding Overview):

| Property name | VARTYPE | Value |
| --- | --- | --- |
| `InterlaceOption` | `VT_BOOL` (11) | `TRUE`/`FALSE` (0 / 0xFFFF), default FALSE |
| `FilterOption` | `VT_UI1` (17) | a `WICPngFilterOption`, default `WICPngFilterUnspecified` |

To set one you must first get the bag: call
`CreateNewFrame(&pFrame, &pBag)` with `pBag` initialised to `NULL` (passing a
non-NULL pointer would leak it — CreateNewFrame doc), then
`pBag->Write(1, &propbag2, &variant)` (vtable `+0x20`), then
`pFrame->Initialize(pBag)`.

`GUID` (`guiddef.h`) is 16 bytes: `DWORD Data1; WORD Data2; WORD Data3; BYTE Data4[8];`.

`PROPBAG2` (`ocidl.h` line 6383) is **40 bytes** on x64:

| Offset | Size | Field | Value to set |
| --- | --- | --- | --- |
| `+0x00` | 4 | `DWORD dwType` | `PROPBAG2_TYPE_DATA` = 1 |
| `+0x04` | 2 | `VARTYPE vt` | `VT_BOOL`/`VT_UI1` |
| `+0x06` | 2 | `CLIPFORMAT cfType` | 0 (unused for data) |
| `+0x08` | 4 | `DWORD dwHint` | 0 |
| `+0x0C` | 4 | *padding* | |
| `+0x10` | 8 | `LPOLESTR pstrName` | pointer to `L"InterlaceOption"` |
| `+0x18` | 16 | `CLSID clsid` | all zero |

`VARIANT` (`oaidl.h` line 476) is **24 bytes** on x64: the header is 8 bytes
(`VARTYPE vt` at `+0x00`, then three `WORD` reserved fields) and the payload
union starts at `+0x08` and is 16 bytes (largest member `DECIMAL`, which is 16
bytes — `wtypes.h` `tagDEC`). For `VT_BOOL`, write the 16-bit value
(`0xFFFF` = TRUE) at `+0x08`; for `VT_UI1`, write the byte at `+0x08`. Zero the
whole 24 bytes first. (You can avoid `VariantInit`/`oleaut32` entirely by
zero-filling and setting `vt` and the payload by hand.)

### Clipboard path

`IWICBitmapEncoder::Initialize` takes a plain `IStream*` (its declared parameter
type), so you do **not** need `IWICStream` for memory output. Use the OLE
growable stream:

1. `CreateStreamOnHGlobal(NULL, FALSE, &pStream)` — `ole32.lib`. `fDeleteOnRelease
   = FALSE` keeps you in charge of the handle. (CreateStreamOnHGlobal doc.)
2. Encode exactly as steps 5–13 above, but `Initialize(pStream, …)` instead of
   `Initialize(pIwicStream, …)`. No `GUID_ContainerFormatPng` change.
3. After `pEncoder->Commit()`, find the exact byte count with
   `pStream->Stat(&statstg, STATFLAG_NONAME)` (vtable `+0x60`) and read
   `statstg.cbSize` — `GlobalSize` can include allocator slack.
4. Allocate an exact-size moveable handle: `GlobalAlloc(GMEM_MOVEABLE, cbSize)`,
   `GlobalLock`, `pStream->Seek(0, STREAM_SEEK_SET, NULL)` (`+0x28`) then
   `pStream->Read(dst, cbSize, NULL)` (`+0x18`) to copy the PNG bytes in,
   `GlobalUnlock`.
5. `OpenClipboard` → `EmptyClipboard` →
   `SetClipboardData(RegisterClipboardFormatW(L"PNG"), hMem)` → `CloseClipboard`.
   The system takes ownership of `hMem` after a successful `SetClipboardData`
   (Clipboard Formats doc: "the system automatically deletes the object using
   `GlobalFree`" for globally-allocated handle formats). Also offer `CF_DIBV5`
   from the original DIB; Win32 will synthesise `CF_DIB`/`CF_BITMAP` from it
   (Clipboard Formats doc). The exact clipboard contract is ticket 06's; this is
   only the PNG encoder's half.
6. `pStream->Release()` and, because `fDeleteOnRelease` was FALSE,
   `GetHGlobalFromStream` + `GlobalFree` the *stream's* handle.

Optionally `IWICStream::InitializeFromMemory` (vtable `+0x80`) works if you
pre-allocate a buffer, but its docs warn "This method should be avoided whenever
possible… ensure the memory block is valid for the lifetime of the stream" and
"the stream cannot grow beyond the buffer size" — so it is a poor fit for PNG,
whose compressed size is not known in advance.

### Failure reporting

Every WIC method returns an `HRESULT`. Success is `S_OK` (0); `S_FALSE` is also
a success. Failure has bit 31 set, so in asm `test eax,eax` / `js failed` is the
`FAILED()` test. Common ones: `REGDB_E_CLASSNOTREG` (factory not registered),
`E_NOINTERFACE`, `WINCODEC_ERR_WRONGSTATE` (`SetPixelFormat` before
`Initialize`), `WINCODEC_ERR_CODECTOOMANYSCANLINES` (`WritePixels` line count >
image height). `CoCreateInstance` also documents `E_POINTER`,
`CLASS_E_NOAGGREGATION`. Map these to a single user-facing "couldn't save the
image" surface; the raw `HRESULT` is still far more diagnostic than GDI+.

### Import libs and apartment

- `windowscodecs.lib` — the WIC methods' import stubs and the WIC GUID symbols
  (every WIC Learn page lists "Library: Windowscodecs.lib"). DLL:
  `windowscodecs.dll`.
- `ole32.lib` — `CoInitializeEx`, `CoUninitialize`, `CoCreateInstance`,
  `CreateStreamOnHGlobal`, `GetHGlobalFromStream`. DLL: `ole32.dll` /
  `combase.dll`.
- Optionally `uuid.lib` if you reference GUID symbols rather than literals.

Apartment: WIC is an ordinary in-proc COM client; the only hard requirement is
that COM be initialised on the calling thread before `CoCreateInstance`
(CoInitializeEx doc: "You need to initialize the COM library on a thread before
you call any of the library functions… Otherwise, the COM function will return
`CO_E_NOTINITIALIZED`"). The GUI thread has a message loop, so
`COINIT_APARTMENTTHREADED` is the natural choice and is what the WIC samples use;
because WIC runs in-proc there is no cross-apartment marshalling either way. If
a background thread ever encodes, call `CoInitializeEx` on *that* thread too. Do
not call it from `DllMain` (CoInitializeEx doc).

### Rough asm cost

- 4 interface pointer slots (`.data`) + 1 `HRESULT` temp.
- 5 GUID constants: factory CLSID, factory IID, container format, pixel format
  (plus the two option structs only if you set options).
- 1 apartment pair (`CoInitializeEx`/`CoUninitialize`), 1 `CoCreateInstance`.
- ~8 vtable calls with hardcoded offsets + 4 `Release`s.
- Per-call: 2–4 lines for shadow space/args, 1 `mov rax,[rcx]`, 1 indirect
  `call`, 2 lines to check `eax`.

---

## Route B — GDI+ (viable fallback)

### Minimum call sequence

1. `GdiplusStartup(&token, &input, NULL)` (`gdiplus.lib`) with
   `GdiplusStartupInput` = `{GdiplusVersion=1, DebugEventCallback=NULL,
   SuppressBackgroundThread=FALSE, SuppressExternalCodecs=FALSE}`. On x64 the
   struct is 24 bytes (4 + 4 pad + 8 + 4 + 4). Returns a `Status`.
2. Build an HBITMAP from the DIB: `CreateDIBSection` into a `BITMAPINFO` for the
   same 32bpp top-down layout, then `memcpy` the DIB bits (or create directly
   with `GdipCreateBitmapFromScan0`, which skips GDI).
   `GdipCreateBitmapFromHBITMAP(hbm, NULL, &bitmap)`.
3. `GdipSaveImageToFile(bitmap, L"out.png", &pngClsid, NULL)`.
   `pngClsid` is `{557CF406-1A04-11D3-9A73-0000F81EF32E}` — Microsoft's own
   "Retrieving the Class Identifier for an Encoder" page prints exactly that
   CLSID for the PNG encoder. Or discover it at runtime:
   `GdipGetImageEncodersSize(&num,&size)`, allocate, `GdipGetImageEncoders(num,
   size, pInfo)`, walk the `ImageCodecInfo[]` comparing `MimeType` to
   `L"image/png"` and copy `Clsid`.
4. `GdipDisposeImage(bitmap)`, `DeleteObject(hbm)`, `GdiplusShutdown(token)`.
5. Clipboard: `GdipSaveImageToStream(bitmap, pStream, &pngClsid, NULL)` with an
   `IStream` from `CreateStreamOnHGlobal` (or `SHCreateMemStream`); everything
   else is the same HGLOBAL dance.

`ImageCodecInfo` (`gdiplusimaging.h`) is: `CLSID Clsid; GUID FormatID; WCHAR*
CodecName; WCHAR* DllName; WCHAR* FormatDescription; WCHAR* FilenameExtension;
WCHAR* MimeType; DWORD Flags, Version, SigCount, SigSize; BYTE* SigPattern,
SigMask;` — 96 bytes on x64, with `MimeType` at offset 48.

### Failure reporting

GDI+ flat functions return `Status` (an `int`; `Ok = 0`). It is a 22-value enum
and the docs warn that constructors "set the status to `OutOfMemory` when they
fail regardless of the reason for failure", and `GenericError = 1` otherwise.
There is no per-failure code, no `HRESULT`, no message. You also get the classic
"GDI+ does not allow you to save an image to the same file that you used to
construct the image" footgun, though here the source is a DIB, not a file.

### Import libs and apartment

- `gdiplus.lib` (DLL `gdiplus.dll`) — `GdiplusStartup`, `GdiplusShutdown`,
  `GdipCreateBitmapFromHBITMAP`, `GdipSaveImageToFile`, `GdipSaveImageToStream`,
  `GdipGetImageEncoders(Size)`, `GdipDisposeImage`.
- `gdi32.lib` (`CreateDIBSection`, `DeleteObject`) for the HBITMAP path.
- `ole32.lib` for `CreateStreamOnHGlobal` on the clipboard path.
- No `CoInitializeEx` required for PNG. (The Heif/Avif codecs in
  `GdiplusStartupInputEx` V3 do need COM, per its header comment — not our case.)
- The library FAQ note: `GdiplusStartup` must not be called from `DllMain`; call
  it from `wWinMain`/`main` and shut down after all GDI+ objects are gone.

### Rough asm cost

- 1 `GdiplusStartupInput` (24 bytes) + token + `Status` temp + a `BITMAPINFO`.
- 1 CLSID either hardcoded or a 30–50 line enumerator over `ImageCodecInfo[]`.
- `CreateDIBSection` + `memcpy` + `DeleteObject` plumbing.
- ~5 flat calls. No vtable offsets, no `this`, no apartment.

---

## Recommendation

**Adopt WIC.** Reasons, in priority order:

1. **No HBITMAP round-trip.** `WritePixels` copies the DIB scanlines straight
   into the encoder. GDI+ makes you materialise a second copy of the image as an
   HBITMAP (or a `GpBitmap`) before it will encode. For a 4K snip that is a
   wasted multi-megabyte copy per save, and another GDI object to leak.
2. **Precise failures.** `HRESULT` per call beats a coarse `Status` enum that the
   docs themselves admit is ambiguous for constructors. Ticket 10
   (verification strategy) wants an encoder-failure surface; WIC gives exact
   codes for free.
3. **One API for file and clipboard.** `IWICStream::InitializeFromFilename` and
   an OLE `IStream` are both `IStream`; the same encoder/frame code serves both,
   differing only in step 3/4. GDI+ needs two different functions
   (`GdipSaveImageToFile` vs `GdipSaveImageToStream`) and a hand-built stream.
4. **It is the supported, modern path.** PNG support, alpha, and the option
   surface are documented and stable; the PNG container GUID and encoder CLSID
   are published on Learn.

The costs are honest: WIC needs COM initialised and a small vtable-offset table,
and its Learn method lists are alphabetical so the offsets must come from the
headers. That is a few dozen lines of constants against GDI+'s HBITMAP copy and
CLSID lookup — a good trade. If the project ever wants to avoid COM for the
*file* path specifically, GDI+ is a fine second choice, but the clipboard path
needs `ole32` regardless, so the "no COM" saving is partial.

## Sources

Microsoft Learn (fetched for this ticket):

- IWICImagingFactory — <https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nn-wincodec-iwicimagingfactory>
- IWICBitmapEncoder::Initialize — <https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwicbitmapencoder-initialize>
- IWICBitmapEncoder::CreateNewFrame — <https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwicbitmapencoder-createnewframe>
- IWICBitmapFrameEncode::Initialize — <https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwicbitmapframeencode-initialize>
- IWICBitmapFrameEncode::SetPixelFormat — <https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwicbitmapframeencode-setpixelformat>
- IWICBitmapFrameEncode::WritePixels — <https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwicbitmapframeencode-writepixels>
- IWICImagingFactory::CreateEncoder — <https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwicimagingfactory-createencoder>
- IWICStream::InitializeFromMemory — <https://learn.microsoft.com/en-us/windows/win32/api/wincodec/nf-wincodec-iwicstream-initializefrommemory>
- PNG Format Overview (encoder options) — <https://learn.microsoft.com/en-us/windows/win32/wic/png-format-overview>
- Encoding Overview (WIC, full sample + no-property-bag form) — <https://learn.microsoft.com/en-us/windows/win32/wic/-wic-creating-encoder>
- CoCreateInstance — <https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-cocreateinstance>
- CoInitializeEx — <https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-coinitializeex>
- CreateStreamOnHGlobal — <https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-createstreamonhglobal>
- VARIANT — <https://learn.microsoft.com/en-us/windows/win32/api/oaidl/ns-oaidl-variant>
- GdiplusStartup — <https://learn.microsoft.com/en-us/windows/win32/api/gdiplusinit/nf-gdiplusinit-gdiplusstartup>
- Status (GDI+) — <https://learn.microsoft.com/en-us/windows/win32/api/gdiplustypes/ne-gdiplustypes-status>
- Image::Save — <https://learn.microsoft.com/en-us/windows/win32/api/gdiplusheaders/nf-gdiplusheaders-image-save(constwchar_constclsid_constencoderparameters)>
- ImageCodecInfo — <https://learn.microsoft.com/en-us/windows/win32/api/gdiplusimaging/nl-gdiplusimaging-imagecodecinfo>
- Retrieving the Class Identifier for an Encoder (PNG CLSID) — <https://learn.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-retrieving-the-class-identifier-for-an-encoder-use>
- Clipboard Formats — <https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats>
- x64 calling convention — <https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention>

Windows SDK headers (authoritative for vtable order and struct layout):

- `C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um\wincodec.h`
  — `IWICImagingFactoryVtbl` (7803), `IWICStreamVtbl` (3116),
  `IWICBitmapEncoderVtbl` (3749), `IWICBitmapFrameEncodeVtbl` (3943), all
  `DEFINE_GUID` values, `WICBitmapEncoderNoCache`, pixel-format GUIDs.
- `…\um\ocidl.h` — `PROPBAG2` (6383), `IPropertyBag2Vtbl` (6434).
- `…\um\oaidl.h` — `tagVARIANT` (476); `…\shared\wtypes.h` — `tagDEC`,
  `VT_BOOL=11`, `VT_UI1=17`; `…\shared\guiddef.h` — `_GUID`.
- `…\um\gdiplusinit.h` — `GdiplusStartupInput` (46), `GdiplusStartup` (147).
- `…\um\gdiplusflat.h` — `GdipSaveImageToFile` (1163),
  `GdipCreateBitmapFromHBITMAP` (1334), `GdipGetImageEncoders(Size)` (2363).
- `…\um\gdiplusimaging.h` — `ImageFormatPNG` (B96B3CAF-…, note: this is the
  *format* GUID, not the encoder CLSID), `ImageCodecInfo` (117),
  `EncoderParameters` (251).
- `…\shared\wtypesbase.h` — `CLSCTX_INPROC_SERVER = 0x1`.
