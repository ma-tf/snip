# Copy and Save As: WIC, the clipboard, and the toolbar

How a Snip leaves the Editor — onto the clipboard, or into a PNG file. Follows
the template in [`docs/architecture.md`](architecture.md).

## What it is

The Editor's Copy, Save, and New buttons, and the encoder behind Copy and Save.
**Copy** publishes the live Snip to the clipboard; **Save** opens the standard
Save As dialog and writes a PNG; **New** starts another Snipping session without
closing the Editor. Both Copy and Save read the **Working** bitmap in place, so
what they publish is what the Editor shows (annotations included, once ticket 06
lands). The Editor stays open after either.

Encoding is **WIC**, not GDI+: it writes the Snip's straight-BGRA pixels straight
into a PNG encoder with no `HBITMAP` round-trip, returns an exact `HRESULT` per
call, and serves the file and the clipboard through the same `IStream`. See
[`docs/research/png-encoding-com.md`](research/png-encoding-com.md) for why.

## Where it lives

| File | Owns |
| --- | --- |
| `src/encode.asm` | The COM apartment and WIC factory, the encoder, and the clipboard formats. |
| `src/editor.asm` | The toolbar controls and the Copy/Save/New commands. |
| `src/win32.inc` | The kernel32/user32/comdlg32 bindings, the clipboard and WIC constants, and the `GUID`/`STATSTG`/`BITMAPV5HEADER`/`OPENFILENAMEW` layouts. |
| `src/snip.inc` | `encode_init`/`encode_file`/`encode_clipboard` and the Editor control IDs. |

`encode.asm` is impure by nature — COM, WIC, and the clipboard are the point —
but it owns no window and reads the Snip only through `dib_snip`.

## How it works

**One apartment, one factory.** `encode_init` runs once from `snip.asm`, before
the Shell is created. It resolves the COM entry points (below), calls
`CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)`, and caches one
`IWICImagingFactory`. `S_FALSE` (already initialised) and `RPC_E_CHANGED_MODE`
(someone else owns the apartment) are both treated as success — WIC runs in-proc
so the apartment mode does not matter, and we never `CoUninitialize` (the process
exit does it). Every later operation reuses the factory.

**The encoder is one shared body.** `encode_stream(IStream*, Snip*)` is the
whole of WIC:

```
factory->CreateEncoder(GUID_ContainerFormatPng, NULL, &encoder)
encoder->Initialize(stream, WICBitmapEncoderNoCache)
encoder->CreateNewFrame(&frame, NULL)          ; NULL options: PNG defaults are right
frame->Initialize(NULL)
frame->SetSize(w, h)
frame->SetPixelFormat(&32bppBGRA)              ; a writable copy; [in,out]
frame->WritePixels(h, w*4, w*4*h, bits)        ; straight from the Snip
frame->Commit(); encoder->Commit()
```

No `IWICBitmap`, no `IWICFormatConverter`, no `IPropertyBag2`. `encode_file`
gives it an `IWICStream` over `InitializeFromFilename`; `encode_clipboard` gives
it an OLE stream. There is no second copy of the image and no GDI object.

**The clipboard gets three formats.** `CF_DIBV5` (a `BITMAPV5HEADER` with RGBA
masks and `LCS_sRGB`, then the pixels), a registered `"PNG"` format (the encoded
bytes), and `CF_DIB` (a `BITMAPINFOHEADER` and the pixels). `CF_DIBV5` carries
the alpha a free-form cut will have (ticket 07); `CF_DIB`/`CF_BITMAP` would be
synthesised from it, but the ticket asks for `CF_DIB` explicitly. The PNG is
encoded into an OLE stream first, then copied into an exactly-sized `GMEM_MOVABLE`
handle: `SetClipboardData` takes `GlobalSize` as the format length, and the
stream's handle carries allocator slack. Ownership of each handle passes to the
clipboard on a successful `SetClipboardData`.

**Save As is the common dialog.** `editor_save` fills an `OPENFILENAMEW`
(PNG filter first, default name `Capture.png`, default extension `png`,
`OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_EXPLORER`) and calls
`GetSaveFileNameW`; on OK it hands the path to `encode_file`.

**The toolbar is stock buttons.** Seven `BUTTON` controls in a row, same as the
Shell's New. New/Save/Copy are wired; Pen, Highlighter, Eraser, and Undo are
present but inert until ticket 06. The Editor's client area is the toolbar
(`ED_TOOLBAR_H`, 32 px) plus the image; `editor_fit` widens the window to
`ED_TOOLBAR_MINW` when the Snip is narrower than the button row, and
`editor_do_paint` fills the strip and blits the Snip below it.

## Gotchas

- **x86 COM enters through the stack, not RCX.** `INVOKE` cannot reach a
  computed target, so every WIC method is a hand-rolled call: `this` is the first
  argument and is pushed **last**, arguments go right-to-left, and there is no
  shadow space. `mov eax, pObj` / `mov eax, [eax]` grabs the vtable.
- **x86 vtable offsets are half the x64 ones.** A vtable slot is a pointer, 4
  bytes on x86 against 8 on x64, so the research's table must be halved:
  `CreateEncoder` 0x40 → **0x20**, `InitializeFromFilename` 0x78 → **0x3C**,
  `WritePixels` 0x50 → **0x28**, and so on. The offsets in `encode.asm` are the
  x86 values, pinned against `wincodec.h`.
- **`SetPixelFormat` is `[in,out]`.** Pass a *writable* copy of
  `GUID_WICPixelFormat32bppBGRA`; the codec may overwrite it. For PNG it comes
  back unchanged, which is what makes `WritePixels` of the raw DIB valid.
- **`ole32.dll` cannot be bound statically in the size build.** Its COM entry
  points are forwarders to `api-ms-win-core-com-l1-1-0`, an API-set name with no
  file on disk. `link` follows the forward fine, but Crinkler reads the exporting
  DLL's file to hash exports and fails with `Cannot find DLL
  API-MS-WIN-CORE-COM-L1-1-0.DLL` (tried `/REPLACEDLL` and `/FALLBACKDLL`: no
  help). So `encode.asm` loads `combase.dll` — the real implementation, which
  exports all four directly — and resolves `CoInitializeEx`,
  `CoCreateInstance`, `CreateStreamOnHGlobal`, and `GetHGlobalFromStream` with
  `GetProcAddress` at startup. `ole32.lib` is therefore **not** in `build.cmd`.
- **`CreateStreamOnHGlobal` and ownership.** With `fDeleteOnRelease = FALSE` the
  stream does not free its `HGLOBAL`, so `encode_clipboard` frees it after
  `Release`; with `TRUE` it would free it under us. Either way the bytes must be
  copied into a fresh handle before `SetClipboardData` (see above).
- **The toolbar makes the Editor wider than a narrow Snip.** A 40-px-wide snip
  still opens a ~456-px window; the image sits at the top-left under the toolbar.
  The button pixel sizes do not scale with DPI, exactly like the Shell's chrome.
- **`WM_ERASEBKGND` is suppressed.** The Editor paints every pixel, so
  `editor_do_paint` must fill the toolbar strip itself (`FillRect` with the
  button-face brush) or the gaps between buttons show garbage.

## See also

- [`docs/architecture.md`](architecture.md) — the explainer template and module layout.
- [`docs/capture.md`](capture.md) — the Snip representation the encoder reads.
- [`docs/shell.md`](shell.md) — the other stock-control window.
- [`docs/build.md`](build.md) — the libraries and the size build.
- [`docs/adr/0002-x86-for-crinkler.md`](adr/0002-x86-for-crinkler.md) — why x86, and the Crinkler constraints.
- [`docs/research/png-encoding-com.md`](research/png-encoding-com.md) — the WIC-over-GDI+ decision.
- [Ticket 05](../.scratch/asm-snip-build/issues/05-copy-save-as.md).
