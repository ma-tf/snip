# The keyboard map

How the two windows are driven from the keyboard. Follows the template in
[`docs/architecture.md`](architecture.md).

## What it is

Six shortcuts, plus Tab traversal:

| Window | Key | Action |
| --- | --- | --- |
| Shell | `Alt+N` | start a snip (the New button) |
| Shell | `Alt+M` | focus the mode drop-down and drop its list |
| Shell | `Alt+D` | focus the Delay drop-down and drop its list |
| Editor | `Alt+N` | start another snip |
| Editor | `Ctrl+C` | Copy the Snip to the clipboard |
| Editor | `Ctrl+S` | Save As |
| Editor | `Ctrl+Z` | Undo the last annotation |
| Overlay | `Esc`, right-click | cancel the Snipping session |
| both | `Tab` / `Shift+Tab` | move focus between the controls |
| both | `Space` | activate the focused button |
| a focused drop-down | arrow keys | change the selection |

Enter is **deliberately unbound** on both windows, and Escape does nothing in the
Editor. There is no "default button", so Enter never implicitly means New — Tab to
the control you want and press Space.

## Where it lives

| File | Owns |
| --- | --- |
| `src/keys.asm` | The accelerator tables, `keys_init`/`keys_free`, and the routing (`keys_translate`). No actions. |
| `src/snip.asm` | Calls `keys_init` at init and `keys_translate` in the message pump. |
| `src/shell.asm` | Handles `IDA_NEW`/`IDA_MODE`/`IDA_DELAY`; `shell_focus_combo` drops a drop-down. |
| `src/editor.asm` | Handles `IDA_NEW`/`IDA_COPY`/`IDA_SAVE`/`IDA_UNDO` in `ew_command`. |
| `src/select.asm` | The Overlay's `Esc` and right-click, read as plain `WM_KEYDOWN`/`WM_RBUTTONUP`. |
| `src/snip.inc` | The `IDA_*` command ids. |
| `src/win32.inc` | The `ACCEL` struct, the `FVIRTKEY`/`FALT`/`FCONTROL` flags, and the five user32 imports. |

## How it works

**Accelerators are the mechanism, not a keydown handler.** An accelerator is a
table entry (`ACCEL`) that `TranslateAcceleratorW` matches against the current
keyboard message and turns into a `WM_COMMAND` for the window it is handed. This
is what makes the shortcuts work *regardless of which control has focus*: with a
toolbar button focused, a `WM_KEYDOWN` never reaches the parent, but
`TranslateAccelerator` still fires. `keys.asm` builds two tables with
`CreateAcceleratorTableW` and the pump offers every message to `keys_translate`
before `TranslateMessage`/`DispatchMessageW`.

**Routing is by capability, not by focus.** The Editor's table is tried first, so
`Ctrl+C`/`Ctrl+S`/`Ctrl+Z` and `Alt+N` work even while the Shell is the focused
window, and the Shell's table second, so `Alt+M`/`Alt+D` reach it. A window that
is not visible is skipped, so nothing fires while the Overlay is up — and with the
Editor hidden an unmatched Shell command (a stray `Ctrl+C`) is simply ignored.

**Commands get their own id range.** `TranslateAcceleratorW` delivers an
accelerator as a `WM_COMMAND` whose **notification word is 1** — which is also
`CBN_SELCHANGE`. The `IDA_*` ids (`snip.inc`) cannot collide with a control id, and
both WndProcs dispatch them *before* their control-notification logic, so the two
kinds of `WM_COMMAND` never have to be told apart by accident.

**`IsDialogMessageW` supplies the traversal.** It gives Tab/Shift+Tab ordering
from each control's `WS_TABSTOP`, Space on a focused button, and the arrow keys
inside a focused drop-down — none of which the app otherwise has. Unlike the
accelerators it must be handed the **window the message actually belongs to**
(picked from the target's root with `GetAncestor(GA_ROOT)`), because its Tab
handling is per-window. It is never called for the Overlay: `select.asm` owns that
window's `Esc`, and traversal there would be meaningless.

## Gotchas

- **`ACCEL` is 6 bytes in C, 5 under MASM.** `{ BYTE fVirt; WORD key; WORD cmd; }`
  is padded so `key` is 2-aligned; MASM's default packing is 1. `win32.inc`
  declares the pad byte explicitly and guards it with `.ERRNZ SIZEOF ACCEL - 6`.
  Left packed, every entry after the first is read from the wrong offset.
- **An accelerator's `WM_COMMAND` notification is 1.** Match on the `IDA_*` id, not
  the notification, or Shell accelerators look like `CBN_SELCHANGE`.
- **`Alt+key` is not `WM_KEYDOWN`.** It arrives as `WM_SYSKEYDOWN`/`WM_SYSCHAR`;
  `TranslateAcceleratorW` matches those, a hand-rolled keydown handler would not.
- **`keys_translate` returns "consumed".** A 1 means the pump must *not* also
  translate/dispatch the message, or the key press runs the action twice.
- **A `ComboBoxEx32` only opens on a *real* `Alt+Down`.** Three quieter routes
  all fail, which is worth knowing before trying them again:
  - `CB_SHOWDROPDOWN` — the Ex control does not honour the base class's message.
  - `CB_GETCOMBOBOXINFO` — fails on the Ex control, so the inner combo is not
    reachable that way either.
  - `WM_KEYDOWN`/`VK_DOWN` — a bare Down navigates a list that is *already* open;
    on a closed drop-down list it does not open one.
  A posted `Alt+Down` fails too: the combo's `WM_SYSKEYDOWN` handler opens or
  closes the list *depending on which arrow key the user pressed*, so it reads
  real keyboard state. `shell_focus_combo` therefore focuses the control and
  plays the keystroke with `SendInput` — the only faithful way to synthesise it.
- **`INPUT` is 28 bytes on x86, sized by its widest member.** `MOUSEINPUT` is 24
  bytes and `KEYBDINPUT` is 16, so the union is padded out to the mouse member,
  not the keyboard one. `win32.inc` spells the fill and guards it with
  `.ERRNZ SIZEOF INPUT - 28`. Two MASM traps live here: `type` is a reserved
  word (so the field is `type_`) and `dx` is a register (so `MOUSEINPUT` uses
  `_dx`).
- **`Ctrl+Z` is reference-verified, not documented.** Microsoft's published
  shortcut table does not list undo in the Editor; investigating the shipping app
  showed `Ctrl+Z` undoes Pen and Highlighter strokes. We bind it, but our
  `ink_undo` reverses the last operation of any kind — an Eraser pass included.
- **The Overlay's `Esc` is not an accelerator.** It is `select.asm`'s own
  `WM_KEYDOWN` check; keeping the two paths separate is why Esc can mean "cancel
  the session" and "nothing" in the Editor at the same time.

## See also

- [`docs/architecture.md`](architecture.md) — the explainer template and the message pump.
- [`docs/shell.md`](shell.md) — the controls the Shell shortcuts drive.
- [`docs/editor.md`](editor.md) — the window whose Copy/Save/Undo the shortcuts reach.
- [`docs/select.md`](select.md) — the Overlay and its Escape/right-click cancel.
- [`docs/research/win11-snipping-tool-shell.md`](research/win11-snipping-tool-shell.md) — §8, the shortcuts the reference advertises.
- `.scratch/asm-snip-build/issues/12-keyboard-accelerators.md` — the ticket.
