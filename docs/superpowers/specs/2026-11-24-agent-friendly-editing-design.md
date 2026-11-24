# Agent-friendly editing: quiet reloads, follow mode, path completion

Status: requested by the user 2026-11-24 ("add the remaining items"). The items were proposed
after the recent-files and live-reload merge. Choices marked "my call" were stated to the user.

## Goals

1. **Quiet reloads:** the background check reloads only after the file's date, size and
   identity have stayed the same for one extra check (0.5 s). An agent writing in quick
   pieces doesn't show a half-written file; a writer that pauses longer can still be caught
   mid-write. `:checktime` still reloads immediately. My call: one
   extra check is the shortest wait that skips a write still in progress.
2. **Follow mode:** if the cursor is on the last line when an outside change arrives, it
   stays on the new last line and the view keeps it visible, like `tail -f`. The rendered
   view stays at the bottom if it was at the bottom. Elsewhere, reload behaves as before.
3. **Path completion:** in the command line, Tab completes the path after `:e`, `:edit`,
   `:w`, `:write`, `:wq` and `:wquit`, including the `!` forms.
   - **Matching:** the first Tab inserts the first match, and later Tabs cycle through the
     matches. Folders end in `/`. Hidden files appear only when the typed name starts with
     `.`. A typed `~` is kept.
   - **Base folder:** relative paths start where `:e` resolves them: beside the current
     file, or in the home folder.
   - **Empty path:** Tab cycles through the recent files.

## Non-goals

- A completion popup (Vim's wildmenu).
- Completion for other commands.
- Debounce tuning settings.

## Design

- `DocumentSession.checkDisk(waitForQuiet:)` remembers the last changed stamp it saw.
  With `waitForQuiet: true`, it returns `.unchanged` until two checks in a row see the same
  stamp. The window's timer passes `true`; `:checktime` and direct calls pass `false`.
- `TerminalView.replaceSourceText` notes whether the cursor was on the last line, and
  whether the rendered view was scrolled to the bottom, then restores both positions after
  the replacement.
- `PathCompletion.candidates(for:relativeTo:recent:)` (NotepadCore) returns full command
  lines. `TerminalView` handles Tab in the command line, cycles through the candidates, and
  resets them when the text is edited. `EditorWindow` supplies the base folder, and
  `AppDelegate` supplies the recent files.
