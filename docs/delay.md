# The Delay

The wait between pressing New and the Overlay appearing, so the user can open a menu or
set up hover state before the screen is taken. Follows the template in
[`docs/architecture.md`](architecture.md).

## What it is

A setting on the Shell's Delay drop-down — No delay, 3, 5, or 10 seconds — that `select_begin`
honours at the start of a Snipping session. When a delay is chosen, New hides our windows and
then waits that long before raising the Overlay. The values match the Windows 11 Snipping Tool
(see [`docs/research/win11-snipping-tool-shell.md`](research/win11-snipping-tool-shell.md) §4).

## Where it lives

- `App.delay` (`src/snip.inc`) holds the drop-down's **index**, not a duration. `shell.asm`
  writes it on `CBN_SELCHANGE`, exactly like `App.mode`.
- The index→milliseconds table and the wait are in `src/select.asm`: `delay_ms` in `.const`,
  and the `sb_delay` block in `select_begin`.
- `Sleep` is bound in `src/win32.inc` (kernel32; `kernel32.lib` is already linked).

## How it works

**An index, mapped to milliseconds.** `select_begin` clamps `App.delay` to the last index and
reads `delay_ms` (`0, 3000, 5000, 10000`). A bad index falls back to No delay rather than
indexing past the table. No delay is a real zero, so the wait is skipped entirely — no
`Sleep(0)` call.

**After the hide, before the raise.** The wait sits between hiding the Shell and Editor and
calling `overlay_show`. That placement does two jobs: the desktop is clear of our windows while
the user arranges (the whole point of the delay), and the wait is independent of the snip mode,
so it applies to rectangle, window, full-screen, and free-form alike.

**A plain `Sleep`.** The spec chose a blocking wait over a timer. The UI thread is ours to
block: the Shell and Editor are already hidden, so there is no window it would otherwise be
serving. The cost is that our app processes no messages during the wait — it cannot react to a
monitor change or cancel until the delay elapses.

**The origin is read after the wait.** Because no messages are processed during the `Sleep`, a
`WM_DISPLAYCHANGE` cannot be handled mid-wait; `select_begin` therefore reads
`SM_X/YVIRTUALSCREEN` *after* the `Sleep`, live, so the session's coordinate space matches what
`overlay_show` reads a moment later. See [`docs/multimonitor.md`](multimonitor.md).

**The choice persists across snips.** `App.delay` is only written by the drop-down, so once the
user picks a delay it stays set for every later Snipping session in the same run; the Shell's
combo still shows it when the Shell returns. Nothing resets it.

## Gotchas

- **`App.delay` is an index, not a duration.** The table owns the millisecond values; the Shell
  only ever reports the list position. Adding a value is a row in `shell.asm` *and* an entry in
  `delay_ms`.
- **No delay must not call `Sleep(0)`.** `Sleep(0)` yields the rest of the time slice; skipping
  the call is what makes "No delay" genuinely immediate.
- **A blocking wait swallows messages.** `WM_DISPLAYCHANGE` and `WM_DPICHANGED` during the
  delay are not seen until it ends. That is why the virtual origin is re-read after the wait
  rather than before it.
- **The wait is before the mode dispatch, on purpose.** Putting it in a per-mode branch would
  have to be repeated four times and could drift; at the top of `select_begin` it is one path.

## See also

- [`docs/select.md`](select.md) — the session lifecycle the delay sits in.
- [`docs/shell.md`](shell.md) — the Delay drop-down and how `App.delay` is written.
- [`docs/multimonitor.md`](multimonitor.md) — the virtual-screen origin read after the wait.
- [`CONTEXT.md`](../CONTEXT.md) — *Snipping session*.
- [Ticket 10](../.scratch/asm-snip-build/issues/10-delay.md).
