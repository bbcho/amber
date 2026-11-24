# Amber

A small native Mac editor for text and Markdown. One document per window, amber text, no tabs.

## Run

Double-click `build/Amber.app`. Build it locally with:

```sh
./scripts/build-app.sh
open "build/Amber.app"
```

Requires macOS 13 or newer and Apple's Swift tools to build. The bundle is signed locally,
not notarized for distribution. It is built for the Mac's current processor architecture.

## Use

- Command-N: new window. Command-O: open text or Markdown files in separate windows.
- File > Open Recent: the 10 files you opened or saved most recently, newest first.
- Command-S: choose a location for a draft, or save the current file.
- Command-Shift-S: save a separate copy.
- Command-F: find. Option-Command-F: find and replace.
- Command-Shift-M or `:mm`: switch between the source and rendered Markdown.
- Standard Mac undo, redo, selection, and clipboard shortcuts work.

Markdown is edited as source text; the rendered view is for checking how it reads. Word wrap is always on. Each window has its own document,
undo history, Vim mode, and autosave. Opening an already-open file focuses its existing window.

## Reopening and outside changes

Amber reopens every window that was open when you quit. If there is nothing to restore,
for example after closing the last window, it opens your most recent file instead, or an
empty window if that file no longer exists.

Each window checks its file twice a second, like Vim's `autoread`. When another program or
an agent changes the file and you have no unsaved edits, Amber reloads it, keeping your
cursor's line and column and your scroll position, and the rendered Markdown view updates
too. The reload is one undo step. If you have unsaved edits, Amber keeps your text and
shows that the file changed outside the app; press Command-S to choose what to keep.

## Autosave and recovery

Text autosaves 0.6 seconds after you stop typing. Until you choose Save, each window stores
its own recovery file in `~/Library/Application Support/Amber Notepad/Drafts/`. Existing
`Recovery.json` drafts from the earlier single-window app are restored too. These working
copies survive a restart. After saving, autosave updates your chosen file and its recovery.

Command-Q preserves all open windows for the next launch. Closing a window asks before
discarding unsaved changes and removes that window's recovery after a successful save or
explicit discard. Other windows and their drafts are unaffected.

Autosave refuses to replace a file changed or deleted outside this app. Press Command-S to
resolve the conflict, or explicitly use `:w!`. Another open window's file can never be claimed
by Save As, `:w`, or `:e`, even with `!`. Duplicate recovered buffers become separate untitled
copies so neither version is lost.

Files are written atomically. UTF-8 and BOM-marked UTF-16 are supported; their byte order,
UTF-8 BOM, and existing newline characters are preserved. Unsupported encodings are rejected
rather than guessed. New documents use UTF-8. This editor is intended for ordinary local
text files, not multi-gigabyte documents. A crash within the debounce interval may lose
the latest keystrokes; closing and quitting flush pending edits.

## Check

```sh
./scripts/test.sh
```

The tests use real temporary files and cover encoding, recovery, autosave, Save As,
external edits/deletion, failed writes, failed opens, reset behavior, command parsing/entry, file ownership, and independent window recovery. Running tests
requires full Xcode because Apple's command-line-tools installation lacks XCTest.

## Vim-style keybindings

Vim bindings start in Normal mode. Press `i` to type and Escape to return to Normal.
Toggle **Edit > Vim Keybindings** for conventional text editing.

| Keys | Action |
| --- | --- |
| `h j k l`, `w b e` | Move by character, visual line, or word |
| `0`, `^`, `$`, `gg`, `G` | Start/end of line or document (`^` currently uses line start) |
| `i a I A`, `o O` | Insert, append, or open a line |
| `x`, `dd`, `D`, `C`, `dw`, `cw`, `cc` | Delete/change character, line, to line end, or word |
| `yy`, `yw`, `p P` | Yank and paste |
| `v`, then movement and `d`, `x`, `y`, or `c` | Select and edit in Visual mode |
| `v`, then movement and `D` or `C` | Delete or change the selected lines |
| `u`, Control-R | Undo and redo |
| `/`, `n`, `N` | Native find, next, previous match |
| Numeric prefix | Repeat a movement or supported edit, such as `3j` or `2dd` |

This is a focused Vim-style subset, not an embedded Vim runtime. There are no macros,
plugins, vimrc, shell commands, or general Vim scripting. Standard Mac shortcuts remain
available in every mode.

## Colon commands

Press `:` in Normal mode, enter a command, and press Return. Escape cancels the command line.

| Command | Action |
| --- | --- |
| `:w`, `:w path` | Save; choose a location for an unnamed document, or save as the given path |
| `:wq`, `:wq path` | Save, then close this window; cancellation/failure leaves it open |
| `:wa`, `:wqa` | Save modified documents in all windows; `:wqa` then closes them all |
| `:q`, `:qa` | Close this window or all windows; refuse unsaved changes |
| `:x` | Save if changed, then close this window |
| `:e`, `:e path` | Reload or replace the current document; use Open when unnamed |
| `:new` | Open a new empty window |
| `:mm` | Switch between the source and the rendered Markdown view |
| `:checktime` | Check every window's file for outside changes now |

Long forms such as `:write`, `:quit`, `:edit`, `:exit`, `:wall`, and `:wqall` work.
Append `!` to write/edit/quit commands to explicitly overwrite or discard pending changes.
`:wqa!` still saves before closing; cancelled/failed saves leave all windows open.
`:q!` and `:e!` cannot undo writes that autosave has already made to a named file.

Paths expand `~`; relative paths start beside the current file, or in your home directory
for unnamed documents. The rest of the command is treated as the literal filename, including
spaces. Unsupported commands show an error without changing the document.

## Markdown preview

`:mm`, Command-Shift-M, or **View > Rendered Markdown** shows the current text rendered in
Amber's colors: headings, lists, quotes, code blocks, tables, rules, and inline styles. The
rendered view is read-only and reflects the text at the moment you switch. In it, `j` and `k`
scroll by a line, Control-D and Control-U by half a screen, `gg` and `G` jump to the top and
bottom, and counts such as `5j` work. `:` opens the command line, so `:mm` switches back,
restoring your cursor and scroll position. Links are styled but not clickable, and images show
their alt text.

## Launch with a keyboard shortcut

Install `Amber.app` in Applications. In Apple's Shortcuts app, create a shortcut named
**Open Amber**, add **Open App**, and select Amber. In Shortcut Details, choose
**Add Keyboard Shortcut** and record a combination, such as Control-Option-Command-A.
Click elsewhere to finish recording it. This launches Amber even when it is closed.

## App icon

`Assets/Amber.icns` contains the native icon sizes; `Assets/Amber.png` is the preview.
The tile uses an 824-pixel face within a 1024-pixel canvas to match neighboring Dock icons.
Regenerate the assets with:

```sh
swift scripts/draw-icon.swift /tmp/Amber.iconset
iconutil --convert icns --output Assets/Amber.icns /tmp/Amber.iconset
cp /tmp/Amber.iconset/icon_512x512@2x.png Assets/Amber.png
```
