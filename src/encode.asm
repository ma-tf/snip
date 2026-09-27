; encode.asm
; WIC encoding to a PNG file and to the clipboard.
;
; Ticket 05. One COM apartment and one IWICImagingFactory are created at process
; init (encode_init, called from snip.asm) and cached for the life of the app;
; each operation then builds a stream, an encoder, and a frame, and writes the
; Snip's pixels straight in with WritePixels. There is no HBITMAP round-trip and
; no IWICBitmap: the Snip is already straight BGRA, which is exactly
; GUID_WICPixelFormat32bppBGRA (ADR-0001). WIC was chosen over GDI+ for this
; because it reports an exact HRESULT per call and serves file and memory
; through the same IStream (docs/research/png-encoding-com.md).
;
; The WIC methods are called through the vtable, not through an import library.
; GUIDs are literals here, so neither windowscodecs.lib nor uuid.lib is linked.
;
; The four COM entry points come from combase.dll resolved at startup with
; GetProcAddress, not from ole32.lib: ole32 exports them only as forwards to
; api-ms-win-core-com-l1-1-0, an API-set name with no file on disk, and the size
; build's Crinkler reads the exporting DLL's file. combase.dll is the real
; implementation and exports them directly. See docs/encode.md and docs/build.md.
;
; Failure is an HRESULT, not a message box: ticket 11 owns the error surface.
; Nothing here exits the process, and encode_init's failure just leaves Copy and
; Save broken until 11 reports it.

.386
.model flat, stdcall
option casemap:none

include snip.inc
include win32.inc

PUBLIC encode_init
PUBLIC encode_file
PUBLIC encode_clipboard

; ---------------------------------------------------------------------------
; vtable byte offsets. A COM vtable is an array of pointers, so on x86 every
; slot is 4 bytes: the offset is slot * 4. (The research's table is x64, where a
; slot is 8 bytes; these are half those values.) Slot order pinned against the
; installed wincodec.h / objidl.h.
; ---------------------------------------------------------------------------
IUNKNOWN_RELEASE        EQU 08h   ; IUnknown slot 2
FACTORY_CREATE_ENCODER  EQU 20h   ; IWICImagingFactory slot 8
FACTORY_CREATE_STREAM   EQU 38h   ; IWICImagingFactory slot 14
STREAM_INIT_FILENAME    EQU 3Ch   ; IWICStream slot 15
ISTREAM_STAT            EQU 30h   ; IStream slot 12
ENCODER_INIT            EQU 0Ch   ; IWICBitmapEncoder slot 3
ENCODER_CREATE_FRAME    EQU 28h   ; IWICBitmapEncoder slot 10
ENCODER_COMMIT          EQU 2Ch   ; IWICBitmapEncoder slot 11
FRAME_INIT              EQU 0Ch   ; IWICBitmapFrameEncode slot 3
FRAME_SET_SIZE          EQU 10h   ; IWICBitmapFrameEncode slot 4
FRAME_SET_PIXEL_FORMAT  EQU 18h   ; IWICBitmapFrameEncode slot 6
FRAME_WRITE_PIXELS      EQU 28h   ; IWICBitmapFrameEncode slot 10
FRAME_COMMIT            EQU 30h   ; IWICBitmapFrameEncode slot 12

E_FAIL_HR               EQU 80004005h

; Forward declarations so INVOKE reaches callees defined later in the file.
com_release       PROTO STDCALL :DWORD
mem_copy          PROTO STDCALL :DWORD, :DWORD, :DWORD
com_resolve       PROTO STDCALL
encode_stream     PROTO STDCALL :DWORD, :DWORD
ec_build_dibv5    PROTO STDCALL :DWORD
ec_build_dib      PROTO STDCALL :DWORD

; ---------------------------------------------------------------------------
; Read-only data. GUIDs are 16 literal bytes each, so no uuid.lib is needed.
; ---------------------------------------------------------------------------
.const
g_clsid_factory GUID <0CACAF262h, 9370h, 4615h, <0A1h,3Bh,9Fh,55h,39h,0DAh,4Ch,0Ah>>
g_iid_factory   GUID <0EC5EC8A9h, 0C395h, 4314h, <9Ch,77h,54h,0D7h,0A9h,35h,0FFh,70h>>
g_png           GUID <01B7CFAF4h, 713Fh, 473Ch, <0BBh,0CDh,61h,37h,42h,5Fh,0AEh,0AFh>>
g_bgra          GUID <06FDDC324h, 4E03h, 4BFEh, <0B1h,85h,3Dh,77h,76h,8Dh,0C9h,0Fh>>

png_name        DW 'P','N','G',0

; combase.dll and the four entry points resolved from it at startup.
combase_dll            DB 'combase.dll',0
fn_CoInitializeEx      DB 'CoInitializeEx',0
fn_CoCreateInstance    DB 'CoCreateInstance',0
fn_CreateStreamOnHGlobal DB 'CreateStreamOnHGlobal',0
fn_GetHGlobalFromStream  DB 'GetHGlobalFromStream',0

.data?
p_factory       DWORD ?     ; IWICImagingFactory *, created once
h_combase       DWORD ?     ; combase.dll, loaded once
pfn_CoInitializeEx        DWORD ?
pfn_CoCreateInstance      DWORD ?
pfn_CreateStreamOnHGlobal DWORD ?
pfn_GetHGlobalFromStream  DWORD ?

.code

; ---------------------------------------------------------------------------
; encode_init() -> BOOL in eax. Resolve the COM entry points from combase.dll,
; create the apartment, and cache the WIC factory. Called once from WinMainASM.
; S_FALSE and RPC_E_CHANGED_MODE both mean COM is usable (the latter that
; someone else owns the apartment, which is fine - we never uninitialise).
; ---------------------------------------------------------------------------
encode_init PROC
    mov  p_factory, 0
    mov  h_combase, 0

    INVOKE com_resolve
    test eax, eax
    jz   ei_fail

    ; CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)
    push COINIT_APARTMENTTHREADED
    push 0
    call dword ptr [pfn_CoInitializeEx]
    test eax, eax
    jz   ei_factory
    cmp  eax, 1                      ; S_FALSE: already initialised
    je   ei_factory
    cmp  eax, RPC_E_CHANGED_MODE
    je   ei_factory
    xor  eax, eax
    ret

ei_factory:
    ; CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
    ;                  &IID_IWICImagingFactory, &p_factory)
    lea  eax, p_factory
    push eax
    push OFFSET g_iid_factory
    push CLSCTX_INPROC_SERVER
    push 0
    push OFFSET g_clsid_factory
    call dword ptr [pfn_CoCreateInstance]
    test eax, eax
    js   ei_fail
    mov  eax, 1
    ret

ei_fail:
    xor  eax, eax
    ret
encode_init ENDP

; ---------------------------------------------------------------------------
; com_resolve() -> BOOL in eax. Load combase.dll and resolve the four entry
; points we call. All four must be found; a partial resolution is a failure.
; ---------------------------------------------------------------------------
com_resolve PROC USES ebx
    INVOKE LoadLibraryA, OFFSET combase_dll
    mov  h_combase, eax
    test eax, eax
    jz   cres_fail
    mov  ebx, eax

    INVOKE GetProcAddress, ebx, OFFSET fn_CoInitializeEx
    mov  pfn_CoInitializeEx, eax
    INVOKE GetProcAddress, ebx, OFFSET fn_CoCreateInstance
    mov  pfn_CoCreateInstance, eax
    INVOKE GetProcAddress, ebx, OFFSET fn_CreateStreamOnHGlobal
    mov  pfn_CreateStreamOnHGlobal, eax
    INVOKE GetProcAddress, ebx, OFFSET fn_GetHGlobalFromStream
    mov  pfn_GetHGlobalFromStream, eax

    cmp  pfn_CoInitializeEx, 0
    je   cres_fail
    cmp  pfn_CoCreateInstance, 0
    je   cres_fail
    cmp  pfn_CreateStreamOnHGlobal, 0
    je   cres_fail
    cmp  pfn_GetHGlobalFromStream, 0
    je   cres_fail
    mov  eax, 1
    ret

cres_fail:
    xor  eax, eax
    ret
com_resolve ENDP

; ---------------------------------------------------------------------------
; encode_file(Snip *snip, LPCWSTR path) -> HRESULT in eax.
; Encode the Snip as a PNG into a file. The WIC stream opens the file itself.
; ---------------------------------------------------------------------------
encode_file PROC USES ebx snip:DWORD, path:DWORD
    LOCAL pStream:DWORD
    LOCAL hr:DWORD

    mov  pStream, 0
    mov  hr, E_FAIL_HR

    mov  ebx, p_factory
    test ebx, ebx
    jz   ef_done

    mov  eax, [ebx]
    lea  ecx, pStream
    push ecx                         ; ppIWICStream
    push ebx                         ; This
    call dword ptr [eax+FACTORY_CREATE_STREAM]
    mov  hr, eax
    test eax, eax
    js   ef_done
    cmp  pStream, 0
    je   ef_done

    mov  ebx, pStream
    mov  eax, [ebx]
    push GENERIC_WRITE
    push path
    push ebx                         ; This
    call dword ptr [eax+STREAM_INIT_FILENAME]
    mov  hr, eax
    test eax, eax
    js   ef_done

    ; An IWICStream interface pointer is a valid IStream*: IWICStream derives
    ; from IStream, so the IStream methods sit at their usual slots.
    INVOKE encode_stream, pStream, snip
    mov  hr, eax

ef_done:
    INVOKE com_release, pStream
    mov  eax, hr
    ret
encode_file ENDP

; ---------------------------------------------------------------------------
; encode_clipboard(Snip *snip) -> HRESULT in eax.
; Put the Snip on the clipboard as CF_DIBV5, a registered "PNG" format, and
; CF_DIB. The PNG is encoded into an OLE stream, then copied into an
; exactly-sized moveable HGLOBAL (the stream's own handle carries allocator
; slack, which would corrupt the format). Ownership of every handle we hand to
; SetClipboardData passes to the clipboard on success.
; ---------------------------------------------------------------------------
encode_clipboard PROC USES ebx snip:DWORD
    LOCAL pStream:DWORD
    LOCAL hr:DWORD
    LOCAL stg:STATSTG
    LOCAL hSrc:DWORD
    LOCAL hDst:DWORD
    LOCAL hDib:DWORD
    LOCAL hDib2:DWORD
    LOCAL srcPtr:DWORD
    LOCAL dstPtr:DWORD
    LOCAL cbSize:DWORD
    LOCAL pngFmt:DWORD
    LOCAL tookPng:DWORD
    LOCAL tookDib:DWORD
    LOCAL tookDib2:DWORD
    LOCAL clipOpen:DWORD

    mov  pStream, 0
    mov  hr, E_FAIL_HR
    mov  hSrc, 0
    mov  hDst, 0
    mov  hDib, 0
    mov  hDib2, 0
    mov  cbSize, 0
    mov  tookPng, 0
    mov  tookDib, 0
    mov  tookDib2, 0
    mov  clipOpen, 0

    ; stream = CreateStreamOnHGlobal(NULL, FALSE, &pStream). FALSE: the HGLOBAL
    ; is ours to free, not the stream's, so it stays valid while we copy out.
    lea  eax, pStream
    push eax                         ; ppstm
    push 0                           ; fDeleteOnRelease
    push 0                           ; hGlobal
    call dword ptr [pfn_CreateStreamOnHGlobal]
    test eax, eax
    js   ec_cleanup
    cmp  pStream, 0
    je   ec_cleanup

    INVOKE encode_stream, pStream, snip
    mov  hr, eax
    test eax, eax
    js   ec_cleanup

    ; exact PNG byte count; GlobalSize includes allocator slack
    mov  ebx, pStream
    mov  eax, [ebx]
    lea  ecx, stg
    push STATFLAG_NONAME
    push ecx
    push ebx                         ; This
    call dword ptr [eax+ISTREAM_STAT]
    test eax, eax
    js   ec_cleanup
    mov  eax, stg.cbSizeLow
    test eax, eax
    jz   ec_cleanup
    mov  cbSize, eax

    lea  eax, hSrc
    push eax                         ; phglobal
    push pStream                     ; pstm
    call dword ptr [pfn_GetHGlobalFromStream]
    test eax, eax
    js   ec_cleanup
    INVOKE GlobalLock, hSrc
    mov  srcPtr, eax
    test eax, eax
    jz   ec_cleanup

    INVOKE GlobalAlloc, GMEM_MOVEABLE, cbSize
    mov  hDst, eax
    test eax, eax
    jz   ec_cleanup
    INVOKE GlobalLock, hDst
    mov  dstPtr, eax
    test eax, eax
    jz   ec_cleanup
    INVOKE mem_copy, dstPtr, srcPtr, cbSize
    INVOKE GlobalUnlock, hDst

    INVOKE ec_build_dibv5, snip
    mov  hDib, eax
    test eax, eax
    jz   ec_cleanup

    INVOKE ec_build_dib, snip
    mov  hDib2, eax
    test eax, eax
    jz   ec_cleanup

    ; --- publish -------------------------------------------------------------
    INVOKE OpenClipboard, 0
    test eax, eax
    jz   ec_cleanup
    mov  clipOpen, 1
    INVOKE EmptyClipboard

    INVOKE RegisterClipboardFormatW, OFFSET png_name
    mov  pngFmt, eax

    INVOKE SetClipboardData, pngFmt, hDst
    test eax, eax
    jz   ec_no_png
    mov  tookPng, 1
ec_no_png:
    INVOKE SetClipboardData, CF_DIBV5, hDib
    test eax, eax
    jz   ec_no_dib
    mov  tookDib, 1
ec_no_dib:
    INVOKE SetClipboardData, CF_DIB, hDib2
    test eax, eax
    jz   ec_no_dib2
    mov  tookDib2, 1
ec_no_dib2:
    INVOKE CloseClipboard
    mov  clipOpen, 0
    cmp  tookPng, 0
    je   ec_cleanup
    mov  hr, 0

ec_cleanup:
    cmp  clipOpen, 0
    je   ec_c1
    INVOKE CloseClipboard
ec_c1:
    cmp  hDst, 0
    je   ec_c2
    cmp  tookPng, 0
    jne  ec_c2
    INVOKE GlobalFree, hDst
ec_c2:
    cmp  hDib, 0
    je   ec_c2b
    cmp  tookDib, 0
    jne  ec_c2b
    INVOKE GlobalFree, hDib
ec_c2b:
    cmp  hDib2, 0
    je   ec_c3
    cmp  tookDib2, 0
    jne  ec_c3
    INVOKE GlobalFree, hDib2
ec_c3:
    INVOKE com_release, pStream
    cmp  hSrc, 0
    je   ec_c5
    INVOKE GlobalUnlock, hSrc
    INVOKE GlobalFree, hSrc
ec_c5:
    mov  eax, hr
    ret
encode_clipboard ENDP

; ---------------------------------------------------------------------------
; encode_stream(IStream *stream, Snip *snip) -> HRESULT in eax.
; The shared encoder body: factory -> encoder -> frame -> WritePixels -> commit.
; No IPropertyBag2: PNG's defaults are what a screenshot wants.
; ---------------------------------------------------------------------------
encode_stream PROC USES ebx esi edi stream:DWORD, snip:DWORD
    LOCAL pEncoder:DWORD
    LOCAL pFrame:DWORD
    LOCAL hr:DWORD
    LOCAL stride:DWORD
    LOCAL bufSize:DWORD
    LOCAL guid:GUID

    mov  pEncoder, 0
    mov  pFrame, 0
    mov  hr, E_FAIL_HR

    mov  ebx, p_factory
    test ebx, ebx
    jz   es_done

    ; stride and buffer size up front; they are needed for WritePixels and the
    ; pixel buffer is the Snip's straight-BGRA bit memory, top-down
    mov  esi, snip
    mov  ecx, [esi].Snip.w
    shl  ecx, 2
    mov  stride, ecx
    mov  edx, [esi].Snip.h
    mov  eax, ecx
    imul eax, edx
    mov  bufSize, eax

    ; --- CreateEncoder(&GUID_ContainerFormatPng, NULL, &pEncoder) -----------
    mov  eax, [ebx]
    lea  ecx, pEncoder
    push ecx                         ; ppIEncoder
    push 0                           ; pguidVendor
    push OFFSET g_png                ; guidContainerFormat
    push ebx                         ; This
    call dword ptr [eax+FACTORY_CREATE_ENCODER]
    mov  hr, eax
    test eax, eax
    js   es_done

    ; --- encoder->Initialize(stream, WICBitmapEncoderNoCache) ---------------
    mov  ebx, pEncoder
    mov  eax, [ebx]
    push WICBitmapEncoderNoCache
    push stream
    push ebx                         ; This
    call dword ptr [eax+ENCODER_INIT]
    mov  hr, eax
    test eax, eax
    js   es_done

    ; --- CreateNewFrame(&pFrame, NULL) --------------------------------------
    mov  eax, [ebx]
    lea  ecx, pFrame
    push 0                           ; ppIEncoderOptions: NULL is supported
    push ecx                         ; ppIFrameEncode
    push ebx                         ; This
    call dword ptr [eax+ENCODER_CREATE_FRAME]
    mov  hr, eax
    test eax, eax
    js   es_done

    ; --- frame->Initialize(NULL) --------------------------------------------
    mov  ebx, pFrame
    mov  eax, [ebx]
    push 0
    push ebx                         ; This
    call dword ptr [eax+FRAME_INIT]
    mov  hr, eax
    test eax, eax
    js   es_done

    ; --- frame->SetSize(w, h) -----------------------------------------------
    mov  esi, snip
    mov  eax, [ebx]
    push [esi].Snip.h
    push [esi].Snip.w
    push ebx                         ; This
    call dword ptr [eax+FRAME_SET_SIZE]
    mov  hr, eax
    test eax, eax
    js   es_done

    ; --- frame->SetPixelFormat(&32bppBGRA) ----------------------------------
    ; The parameter is [in,out]: pass a writable copy of the GUID. For PNG it
    ; comes back unchanged; if a codec ever changed it, WritePixels would fail,
    ; which the guards below report.
    lea  edi, guid
    mov  esi, OFFSET g_bgra
    mov  ecx, 4
    rep  movsd
    mov  eax, [ebx]
    lea  ecx, guid
    push ecx                         ; pPixelFormat
    push ebx                         ; This
    call dword ptr [eax+FRAME_SET_PIXEL_FORMAT]
    mov  hr, eax
    test eax, eax
    js   es_done

    ; --- frame->WritePixels(h, stride, stride*h, bits) ----------------------
    mov  esi, snip
    mov  eax, [ebx]
    push [esi].Snip.bits             ; pbPixels
    push bufSize                     ; cbBufferSize
    push stride                      ; cbStride
    push [esi].Snip.h                ; lineCount
    push ebx                         ; This
    call dword ptr [eax+FRAME_WRITE_PIXELS]
    mov  hr, eax
    test eax, eax
    js   es_done

    ; --- frame->Commit() ----------------------------------------------------
    mov  eax, [ebx]
    push ebx                         ; This
    call dword ptr [eax+FRAME_COMMIT]
    mov  hr, eax
    test eax, eax
    js   es_done

    ; --- encoder->Commit() --------------------------------------------------
    mov  ebx, pEncoder
    mov  eax, [ebx]
    push ebx                         ; This
    call dword ptr [eax+ENCODER_COMMIT]
    mov  hr, eax

es_done:
    INVOKE com_release, pFrame
    INVOKE com_release, pEncoder
    mov  eax, hr
    ret
encode_stream ENDP

; ---------------------------------------------------------------------------
; ec_build_dibv5(Snip *snip) -> HGLOBAL in eax, or 0.
; A clipboard CF_DIBV5 block: a BITMAPV5HEADER (top-down, BI_BITFIELDS, RGBA
; masks, sRGB) followed by the Snip's straight-BGRA pixels. V5 rather than
; BITMAPINFOHEADER so a free-form cut's per-pixel alpha survives (ticket 07).
; ---------------------------------------------------------------------------
ec_build_dibv5 PROC USES esi edi snip:DWORD
    LOCAL hdr:BITMAPV5HEADER
    LOCAL h:DWORD
    LOCAL p:DWORD
    LOCAL pixBytes:DWORD

    mov  esi, snip
    mov  eax, [esi].Snip.w
    mov  ecx, [esi].Snip.h
    imul eax, ecx
    shl  eax, 2
    mov  pixBytes, eax

    lea  edi, hdr
    xor  eax, eax
    mov  ecx, (SIZEOF BITMAPV5HEADER) / 4
    rep  stosd
    mov  hdr.bV5Size, SIZEOF BITMAPV5HEADER
    mov  eax, [esi].Snip.w
    mov  hdr.bV5Width, eax
    mov  eax, [esi].Snip.h
    neg  eax
    mov  hdr.bV5Height, eax
    mov  hdr.bV5Planes, 1
    mov  hdr.bV5BitCount, 32
    mov  hdr.bV5Compression, BI_BITFIELDS
    mov  hdr.bV5RedMask, 00FF0000h
    mov  hdr.bV5GreenMask, 0000FF00h
    mov  hdr.bV5BlueMask, 000000FFh
    mov  hdr.bV5AlphaMask, 0FF000000h
    mov  hdr.bV5CSType, LCS_sRGB

    mov  eax, pixBytes
    add  eax, SIZEOF BITMAPV5HEADER
    INVOKE GlobalAlloc, GMEM_MOVEABLE, eax
    mov  h, eax
    test eax, eax
    jz   bv5_zero
    INVOKE GlobalLock, h
    mov  p, eax
    test eax, eax
    jz   bv5_free

    INVOKE mem_copy, p, ADDR hdr, SIZEOF BITMAPV5HEADER
    mov  eax, p
    add  eax, SIZEOF BITMAPV5HEADER
    INVOKE mem_copy, eax, [esi].Snip.bits, pixBytes
    INVOKE GlobalUnlock, h
    mov  eax, h
    ret

bv5_free:
    INVOKE GlobalFree, h
bv5_zero:
    xor  eax, eax
    ret
ec_build_dibv5 ENDP

; ---------------------------------------------------------------------------
; ec_build_dib(Snip *snip) -> HGLOBAL in eax, or 0.
; A clipboard CF_DIB block: a BITMAPINFOHEADER (top-down, BI_RGB) followed by
; the pixels. Alpha is not carried by CF_DIB; CF_DIBV5 is the alpha-aware one.
; ---------------------------------------------------------------------------
ec_build_dib PROC USES esi edi snip:DWORD
    LOCAL hdr:BITMAPINFOHEADER
    LOCAL h:DWORD
    LOCAL p:DWORD
    LOCAL pixBytes:DWORD

    mov  esi, snip
    mov  eax, [esi].Snip.w
    mov  ecx, [esi].Snip.h
    imul eax, ecx
    shl  eax, 2
    mov  pixBytes, eax

    lea  edi, hdr
    xor  eax, eax
    mov  ecx, (SIZEOF BITMAPINFOHEADER) / 4
    rep  stosd
    mov  hdr.biSize, SIZEOF BITMAPINFOHEADER
    mov  eax, [esi].Snip.w
    mov  hdr.biWidth, eax
    mov  eax, [esi].Snip.h
    neg  eax
    mov  hdr.biHeight, eax
    mov  hdr.biPlanes, 1
    mov  hdr.biBitCount, 32
    mov  hdr.biCompression, BI_RGB

    mov  eax, pixBytes
    add  eax, SIZEOF BITMAPINFOHEADER
    INVOKE GlobalAlloc, GMEM_MOVEABLE, eax
    mov  h, eax
    test eax, eax
    jz   dib_zero
    INVOKE GlobalLock, h
    mov  p, eax
    test eax, eax
    jz   dib_free

    INVOKE mem_copy, p, ADDR hdr, SIZEOF BITMAPINFOHEADER
    mov  eax, p
    add  eax, SIZEOF BITMAPINFOHEADER
    INVOKE mem_copy, eax, [esi].Snip.bits, pixBytes
    INVOKE GlobalUnlock, h
    mov  eax, h
    ret

dib_free:
    INVOKE GlobalFree, h
dib_zero:
    xor  eax, eax
    ret
ec_build_dib ENDP

; ---------------------------------------------------------------------------
; com_release(IUnknown *obj) - Release if non-NULL. Leaf.
; ---------------------------------------------------------------------------
com_release PROC obj:DWORD
    mov  eax, obj
    test eax, eax
    jz   cr_done
    mov  ecx, [eax]
    push eax
    call dword ptr [ecx+IUNKNOWN_RELEASE]
cr_done:
    ret
com_release ENDP

; ---------------------------------------------------------------------------
; mem_copy(void *dst, void *src, DWORD cb) - flat byte copy. Leaf.
; ---------------------------------------------------------------------------
mem_copy PROC USES esi edi dst:DWORD, src:DWORD, cb:DWORD
    mov  ecx, cb
    test ecx, ecx
    jz   mc_done
    mov  edi, dst
    mov  esi, src
    rep  movsb
mc_done:
    ret
mem_copy ENDP

END
