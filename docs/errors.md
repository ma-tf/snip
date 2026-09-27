# The error surface

How `snip.exe` reports a failure. Follows the template in
[`docs/architecture.md`](architecture.md).

## What it is

One `MessageBoxW` at the point of failure, and nothing else: no status bar, no log, no retry
loop. When a capture, an encode, a clipboard write, or an allocation fails, the operation is
aborted and the user is told which one failed. The app does not crash and does not lose the
Snip it already had.

There are exactly two weights of failure:

- **Operational failures** — a capture, Copy, Save, or clipboard operation that did not work —
  report and return. The Shell comes back usable and the Editor stays open, so the user can
  retry. An allocation failure *inside* one of those operations is reported as that operation's
  failure, not as a separate one.
- **The two fatal failures** — COM or the WIC factory unavailable, or the Shell window could not
  be created — report and then end the process cleanly (exit code 1). Nothing else exits.

A capture that *succeeds* but comes back black is not a failure here. It is a documented
limitation (DRM video, exclusive-fullscreen surfaces), and the app cannot tell it apart from a
region that is legitimately black. See [`docs/capture.md`](capture.md).

## Where it lives

- `src/err.asm` — the whole surface. `err_show` maps an id to a wide string and calls
  `MessageBoxW`; the caption, the five messages, and `err_table` sit in `.const`.
- `src/snip.inc` — the `ERR_*` ids (`ERR_CAPTURE`, `ERR_COPY`, `ERR_CLIPBOARD_BUSY`,
  `ERR_SAVE`, `ERR_STARTUP`, `ERR_SHELL`) and the `err_show` prototype. The contract is an id,
  not a string.
- `src/win32.inc` — the `MessageBoxW` binding, `MB_OK`/`MB_ICONERROR`, and
  `CLIPBRD_E_CANT_OPEN`.
- The call sites, each at the operation it owns:
  - `src/snip.asm` — `encode_init` failing (`ERR_STARTUP`) or `shell_create` failing
    (`ERR_SHELL`) at startup, then `ExitProcess 1`.
  - `src/select.asm` — `select_finish` after a failed crop (`ERR_CAPTURE`).
  - `src/editor.asm` — `editor_copy` and `editor_save` after a failed encode or dialog.
  - `src/encode.asm` — sets `CLIPBRD_E_CANT_OPEN` when `OpenClipboard` fails, so `editor`
    can tell the clipboard-busy case apart.

## How it works

**Report at the operation, not in the encoder.** `encode.asm` and `dib.asm` return their
results (`HRESULT`, `BOOL`) and never touch the UI; the module that owns the *user operation*
raises the message. That keeps the encode and DIB plumbing free of window code and lets a
failure be reported by whoever knows what the user was trying to do.

**An id, mapped in one place.** `err_show(hwndOwner, id)` rejects an id above `ERR_LAST`, looks
up the string in `err_table`, and shows it with `MB_OK | MB_ICONERROR`. The caller names the
failure; the wording and the icon live in `err.asm`. Adding a message is an `ERR_*` constant, a
string, a table entry, and `ERR_LAST` moved on — no scattered string literals.

**Recoverable by construction.** The Snip is atomic (`dib_crop*` builds the new bitmap before
freeing the old one), so a failed capture leaves the previous Snip and its Editor exactly as
they were. `select_finish` restores the Shell first, then reports, then returns — so the box
appears over a usable app, not over the closing Overlay. Copy and Save simply return; the
Editor was never closed.

**The locked clipboard is its own message.** `OpenClipboard` returns a `BOOL`, not an
`HRESULT`, so `encode_clipboard` synthesises `CLIPBRD_E_CANT_OPEN` at that branch. `editor_copy`
checks for it and shows "in use by another application" rather than the generic copy failure.

**Fatal means fatal, once.** `WinMainASM` calls `encode_init` before any window exists. If it
returns 0, there is no COM apartment and no WIC factory, so Copy, Save, and the whole point of
the app are gone; the box has no owner (there is no window yet) and `ExitProcess 1` follows. A
failed `shell_create` is the same shape: without the Shell there is no app, so it reports
`ERR_SHELL` and exits 1.

## Gotchas

- **Black is not an error.** The capture path's last resort (a screen blit) is accepted even if
  every pixel is black. Do not add a blackness check here; it would fire on a legitimately
  black region and is exactly the limitation the spec documents instead.
- **Don't report a cancelled Save.** `editor_save` calls `CommDlgExtendedError` to tell a
  dismissed dialog (0, no error) from a real dialog failure; only the latter, or a negative
  `HRESULT` from `encode_file`, is reported.
- **`OpenClipboard` has no HRESULT.** It is `BOOL` + `GetLastError`. The clipboard error is
  synthesised in `encode.asm`; there is no useful error code to pass through.
- **The box is modal to the UI thread.** `MessageBoxW` blocks the calling thread, so it is
  always shown *after* the app is back in a usable state (Shell restored, Editor open) — never
  in the middle of the handoff.
- **Startup is the only exit.** `ERR_STARTUP` and `ERR_SHELL` are the calls whose caller ends
  the process. Every other `err_show` returns to the message loop.
- **The delay makes the box wait too.** A `MessageBoxW` raised while the UI thread is mid-`Sleep`
  cannot appear until the delay ends; in practice no failure happens during the delay because no
  capture is running yet.

## See also

- [`docs/capture.md`](capture.md) — the capture path whose failure `ERR_CAPTURE` reports.
- [`docs/encode.md`](encode.md) — the `HRESULT`s that Copy and Save surface.
- [`docs/select.md`](select.md) — `select_finish`, where a failed crop is reported.
- [`docs/editor.md`](editor.md) — Copy and Save As, the Editor's own operations.
- [`CONTEXT.md`](../CONTEXT.md) — *Shell*, *Editor*, *Snip*.
- [Ticket 11](../.scratch/asm-snip-build/issues/11-error-surface.md).
