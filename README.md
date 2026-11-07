# Amber

A small native Mac editor for text and Markdown. One window, one document, amber text.

## Run

Double-click `build/Amber.app`. Build it locally with:

```sh
./scripts/build-app.sh
open "build/Amber.app"
```

Requires macOS 13 or newer and Apple's Swift tools to build. The bundle is signed locally,
not notarized for distribution. It is built for the Mac's current processor architecture.

## Use

- Command-N: new document. Command-O: open a text or Markdown file.
- Command-S: choose a location for a draft, or save the current file.
- Command-Shift-S: save a separate copy.
- Command-F: find. Option-Command-F: find and replace.
- Standard Mac undo, redo, selection, and clipboard shortcuts work.

Markdown is edited as source text. Word wrap is always on. No tabs or additional windows.

## Autosave and recovery

Text autosaves 0.6 seconds after you stop typing. Until you choose Save, it goes only to
`~/Library/Application Support/Amber Notepad/Recovery.json`. This is a temporary working
copy kept outside the system's disposable temporary directory so it survives a restart.
After saving, autosave updates your chosen file and keeps a recovery copy too.

Closing or quitting preserves your current document for the next launch. New/Open asks
before replacing unsaved text. Discard Changes replaces the current recovery copy.
Autosave stops short of replacing a file changed or deleted outside this app. Press
Command-S to save a separate copy or explicitly replace the external version.

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
external edits/deletion, failed writes, failed opens, and reset behavior. Running tests
requires full Xcode because Apple's command-line-tools installation lacks XCTest.

## Vim-style keybindings

Vim bindings start in Normal mode. Press `i` to type and Escape to return to Normal.
Toggle **Edit > Vim Keybindings** for conventional text editing.

| Keys | Action |
| --- | --- |
| `h j k l`, `w b e` | Move by character, visual line, or word |
| `0`, `^`, `$`, `gg`, `G` | Start/end of line or document (`^` currently uses line start) |
| `i a I A`, `o O` | Insert, append, or open a line |
| `x`, `dd`, `D`, `dw`, `cw`, `cc` | Delete/change character, line, or word |
| `yy`, `yw`, `p P` | Yank and paste |
| `v`, then movement and `d`, `x`, `y`, or `c` | Select and edit in Visual mode |
| `u`, Control-R | Undo and redo |
| `/`, `n`, `N` | Native find, next, previous match |
| Numeric prefix | Repeat a movement or supported edit, such as `3j` or `2dd` |

This is a focused Vim-style subset, not an embedded Vim runtime. There are no ex commands,
macros, plugins, or vimrc. Standard Mac shortcuts remain available in every mode.
