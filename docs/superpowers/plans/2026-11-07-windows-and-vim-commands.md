# Multiple windows and Vim file commands

Goal: User explicitly expanded the original single-window brief to multiple Amber windows.
Each window edits one text/Markdown file; no tabs, splits, sidebars, or new settings.
Preserve the approved 12pt body, compact header/footer, icon and caret fixes.

Architecture gate:
- Existing DocumentSession is one independent value/state + file boundary per window.
- New pure VimCommand enum/parser throws explicit unsupported/invalid-argument errors.
- New EditorWindow resource owns one NSWindow, TerminalView, DocumentSession, debounce timer.
- AppDelegate owns window collection, shared menus and all-window coordination on MainActor.
- Command entry reuses the footer, preserves document text, and returns focus on Enter/Escape.
- Recovery: each new window gets Application Support/Amber Notepad/Drafts/<UUID>.json;
  startup also restores existing legacy Recovery.json in place. No format/data migration.
- Cmd-Q autosaves every open window and retains recovery files for next launch.
  Closing a window protects every dirty document, named or untitled: save must succeed or
  discard must be explicit before removing only that window's recovery.
- Cmd-N creates a window; Cmd-O/Finder opens each file in its own window. :e replaces current.
- Core commands: w[!] [path], wq[!] [path], wqa[!], wa[!], q[!], qa[!], x, e[!] [path], new.
  Long aliases write, wquit, wqall, wall, quit, qall, exit, edit are explicit aliases.
  No shell/external commands or general Vim language. Unsupported commands give an error.
- q/e refuse unsaved changes (E37), ! permits discard. Already autosaved file writes remain.
  w path refuses an existing different destination unless !; writes retain conflict guard.
  wqa saves all modified documents before closing any; failed/cancelled saves keep all open.
- Mutable window registry/timers are confined to the native shell. No background threads.
- Allowed edits: existing app modules, new EditorWindow.swift, VimCommand.swift, matching tests,
  DocumentSession's recovery-delete boundary, README and verification docs. No unrelated Vim edits.

Verification:
1. Pure parser tests: requested commands, aliases, bang/path, whitespace, rejected arguments.
2. Real-file tests: independent sessions/recoveries, deleting one recovery leaves others/file intact.
3. Native component tests: command entry cancellation doesn't edit document; callback executes once;
   window buffers/undo are independent; q rejects dirty untitled buffer; write failure keeps window.
4. Full Swift suite, release build/signature, native UI: two windows with independent text;
   :w / cancellation; :e preserves/replaces correct buffer; :wq current; :wqa all; quit/relaunch
   restores multiple drafts; existing legacy recovery is preserved. Independent final review.

Implementation tasks:
- Pure VimCommand parser and tests (independent of UI).
- Footer command-entry UI and key routing, with focused tests (independent of parser).
- Extract per-window lifecycle from AppDelegate; wire workspace commands and recovery.
- Integrate, test, inspect UI, review, install, commit and update existing PR.

File ownership invariant: one live editor owns each canonical on-disk file. Native Open and
Finder Open activate an existing owner instead of creating a duplicate buffer. :e and every
save destination (native Save As, :w path, :wq path) refuse another window's file, even with !.
Resolve symlinks and compare filesystem device/inode for existing files, falling back to
standardized resolved paths for new destinations. Tests cover symlink/alternate-path ownership.
All-window save force never bypasses this ownership rule.

Completion evidence: 44 tests pass; release build and signature pass; native UI verified
independent windows, per-window write/quit, save/close/save-all cancellation, legacy+new draft
restoration, and :w/:e/:wqa/:x with isolated recovery. Code and UI independent reviews PASS,
A-. Old header alignment was preserved and reapplied after native window placement. Installed
app retains the user's scratchpad. No remaining required implementation or validation steps.
