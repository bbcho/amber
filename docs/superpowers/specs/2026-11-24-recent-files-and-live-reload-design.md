# Recent files and live reload

Status: requested by the user 2026-11-24 ("make the changes"). Calls marked "my call" were
made on the user's behalf and listed to them.

## Intent

1. **Reopen and recents:** when Amber opens, it should show the last file you opened. Open
   should offer the last 10 files.
2. **Live reload:** when an agent changes an open file in the background, Amber should show
   the change, as Vim's `autoread` does. That includes the Markdown preview.

## Goals

- **File > Open Recent** lists the 10 most recently used files, newest first, plus Clear
  Menu. My call: this is the standard Mac location, because the system open dialog can't
  list them.
  - "Used" means opened (Open, Open Recent, Finder, `:e`) or saved to a new path (Save As,
    `:w path`). Untitled drafts are never listed.
  - Files that no longer exist are hidden. Duplicate names show their folder, as
    "notes.md — Projects".
- **Launch:** when no window would be restored, Amber opens the most recent file that still
  exists, or else an empty window as today. Restored windows are unchanged. My call: this
  covers closing the last window, after which Amber has nothing to restore.
- **Live reload:** each window checks its file twice a second.
  - **Your copy has no unsaved edits:** Amber reloads the file, keeps the cursor's line and
    column and the scroll position, and makes the reload one undo step.
  - **Your copy has unsaved edits:** your text is kept and the existing conflict status is
    shown.
  - **The file is deleted:** your text is kept and the status says so.
  - **The rendered view is showing:** it re-renders and keeps its scroll position.
- `:checktime` checks immediately.

## Non-goals and anti-goals

- No `:set autoread` toggle yet; it is always on until the planned `:set` system exists.
  My call.
- No system-wide recent items, Dock menu, or shared-file list.
- **Failure:** a background change overwriting your unsaved edits.
- **Failure:** Amber's own autosave being mistaken for an outside change.
- **Failure:** a reload that leaves the window marked as having unsaved changes.

## Approaches

- **Change detection, chosen: polling** the file's modification date and size every
  0.5 seconds, reading the bytes only when those change. It survives agents that save by
  writing a new file and renaming it over the old one.
  - Rejected: a kernel file watch (`DispatchSource`). It has to be re-armed after every
    such rename.
  - Rejected: `NSFilePresenter`. It only sees coordinated writes, and agents don't
    coordinate.
- **Recent list storage, chosen:** a small JSON file beside the recovery files
  (`Amber Notepad/Recent.json`). Its path is passed in explicitly, so tests use temporary
  folders.
  - Rejected: `NSDocumentController`'s recents, a global list that tests would pollute.
  - Rejected: `UserDefaults`, an implicit global.

## Design

- **`RecentFiles`** (NotepadCore, a pure value): `adding(_:)` moves a URL to the front,
  removes duplicates, and keeps 10. `load(from:)` and `save(to:)` read and write the JSON.
  A missing or corrupt file loads as empty.
- **`DocumentSession.checkDisk() -> DiskChange`** returns `.unchanged`, `.reloaded`,
  `.conflict` or `.missing`.
  - It compares bytes only when the file's modification date or size changed since Amber
    last read or wrote it.
  - Bytes equal to the last saved bytes count as `.unchanged`, so Amber's own saves are
    ignored.
  - A reload also writes recovery.
- **`EditorWindow`** runs a 0.5-second timer that calls `checkDisk()`, stopped when the
  window closes. It reports its file to the app whenever its document URL changes.
  - A reload replaces the editor text through `shouldChangeText`, `replaceCharacters` and
    `didChangeText`, so it is one undo step and the delegate stays in sync.
  - It then restores the cursor line and column and the scroll position, and re-renders
    the preview if it is showing.
- **`AppDelegate`** owns the `RecentFiles` value and its file. It builds the Open Recent
  submenu on demand, opens a chosen file, clears the list, and picks the launch file.
- **`VimCommand.checkTime`** comes from `checkt[ime]`.

## Tasks

1. **`RecentFiles`:** with tests for ordering, de-duplication, the cap of 10, and loading a
   missing or corrupt file.
2. **`DocumentSession.checkDisk`:** tests with real files for each `DiskChange` case,
   including after Amber's own save.
3. **Recording files and the menu:** windows report files to the app; then the Open Recent
   menu, Clear Menu, and opening the recent file at launch. Workspace tests cover each.
4. **Live reload in the window:** the timer, reload application, conflict and missing
   status, preview re-render, and `:checktime`. Tests cover cursor and line preservation,
   one undo step, no unsaved-changes flag, and dirty buffers being kept.
5. **Finish:** README, full suite, an independent review, the merge, and the reinstall.
