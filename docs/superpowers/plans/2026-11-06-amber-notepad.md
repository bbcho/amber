# Amber Notepad Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Deliver a runnable Mac text editor matching the supplied amber terminal reference.
**Architecture:** Pure text encoding values, explicit file/recovery session, one AppKit window.
**Tech Stack:** Swift / AppKit / Swift Package Manager; no external dependencies.
**Spec:** docs/superpowers/specs/2026-11-06-amber-notepad-design.md

## Global Constraints
macOS 13 minimum. One window, one document. No tabs, preview, sidebar, or network.
Autosave untitled text to recovery, named text to its file. Preserve exact text and encoding.

## Review Focus
- Unicode and BOM/newline round trips must preserve original bytes.
- External changes or deletion must block autosave, retaining the editor's recovery copy.
- Failed writes must leave text recoverable and not mark it saved.
- Relaunch must restore unsaved text, filename, and conflict guard baseline.
- New/Open cancellation must leave the current buffer intact.

### Task 1: document storage
Files: Package.swift, Sources/NotepadCore/{TextFile,DocumentSession}.swift,
Tests/NotepadCoreTests/DocumentTests.swift.
Interfaces: TextFile.decode(_:) throws, encoded() throws; DocumentSession(recoveryURL:),
restore(), open(_:), updateText(_:), autosave(), save(to:overwrite:), reset(). All I/O throws.
- [x] Add focused codec/recovery/conflict/write-failure tests; run and observe missing behavior.
- [x] Implement minimum file and recovery model, run swift test until all assertions pass.
- [x] Review and commit coherent storage block.

### Task 2: native app and bundle
Files: Sources/AmberNotepad/{main,AppDelegate,TerminalView}.swift, scripts/build-app.sh,
scripts/Info.plist, README.md.
Interfaces: AppDelegate owns DocumentSession, TerminalView exposes NSTextView and status.
- [x] Build native window, menus, editing, debounce, file dialogs, conflict and recovery flows.
- [x] Build app bundle, run tests, launch app and exercise editing/save/recovery through UI.
- [x] Inspect screenshot against reference, fix material issues, obtain independent review.
- [x] Run final checks and commit. Fast-forward local main and deliver app plus source.

## Execution ruling
User explicitly requested building the agreed design. Execute inline without another approval
round. The initially empty folder has no remote or existing baseline tests.

## Execution ledger
- Design review: PASS, no architecture blockers.
- First core verification: 10 tests passed; Unicode/BOM/newlines, recovery, autosave,
  conflicts/deletion, failed open/write, Save As, reset.
- Independent review found long-text resizing truncation and cancelled-save debounce loss.
  Long-text regression reproduced (500 lines, viewport forced to 602px); keep document height.
  Cancelled-save reproduced in UI: recovery absent, footer remained Saving after cancellation.
  Keep the autosave timer alive through cancelled panels.
- Queue Finder open requests until startup recovery and UI initialization complete.
- User steering: reduce text to 12pt after two corrections, header to 12pt, add Vim-style modes and bindings.
- Storage and UI shipped as one coherent commit: package includes executable target, so
  committing the package alone would leave an unbuildable checkout.

- Final code and UI independent reviews: PASS, A-. 17 tests pass. Native file, recovery,
  cancellation, Finder cold-launch workflows verified. User chose final display name Amber.
