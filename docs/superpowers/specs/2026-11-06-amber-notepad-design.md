# Amber Notepad

Approved intent: a native macOS editor, one window and one text or Markdown document at a time.
Amber monospaced text, warm nearly black screen, amber filename/status strip, block caret,
subtle glow and scanlines, rounded screen. No tabs, sidebar, rendered Markdown, network,
accounts, dependencies, or settings system.

New/Open/Save/Save As, native undo and clipboard, find and replace, word wrap.
Unsaved text autosaves to a recovery file until explicitly saved. Saved documents autosave
to their chosen path. Recover the last session after quitting/restarting. Never overwrite an
externally modified file automatically. Display save errors and preserve recovery contents.
Prompt Save/Discard/Cancel before replacing an edited document. Closing preserves recovery.

Implementation choices: Swift, AppKit, Swift Package Manager, macOS 13 minimum. A build
script produces build/Amber Notepad.app, signed locally. No external packages.

## Architecture gate
- Values: TextFile(text, encoding), Snapshot(text, path?, savedBytes?, encoding).
  Dirty means encoded text differs from last saved bytes; untitled nonempty text is dirty.
- CORE: decode(Data) throws -> TextFile, encoded() throws -> Data, cursorPosition(text, offset).
  Preserve UTF-8 BOM and UTF-16 BOM/byte order, existing newline bytes; reject invalid input.
- SHELL: DocumentSession owns explicit recovery URL, file read/write, snapshot, autosave.
  AppDelegate owns one window and debounce timer on the main actor. No concurrency locks.
- Expected failures use Swift throwing errors at codec/filesystem boundaries, caught by UI.
- Writes: recovery JSON atomically first, then user file atomically, then updated recovery.
  A stale recovery after a crash is safe: compare bytes and require explicit conflict choice.
- Dependencies bound at launch: recovery URL in Application Support/Amber Notepad.
  Integration tests use independent temporary directories and real files.
- No events, database, streams, optics, framework layers, or custom FP abstractions.
- Observability: visible saved/draft/conflict/error status; actionable native error dialogs.
- Risks: synchronous local I/O suits small text documents. Very large files are not a target.
  Crash before debounce (0.6 seconds) can lose the latest keystrokes; lifecycle flushes reduce it.
- Verify Unicode/BOM/newline round trips; recovery, named autosave, external edits/deletion,
  failed writes, Save As, cancellation; launch and inspect rendered native UI.

## Scope and acceptance
Only Sources/, Tests/, scripts/, docs/, Package.swift, README.md, .gitignore, and app bundle
metadata. Three runtime parts: document storage, editor UI, application lifecycle.
PASS requires build, real file tests, rendered UI, and single-document lifecycle checks.
