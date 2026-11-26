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
for example after closing the last window, it opens the most recent file that still exists,
or an empty window if none do.

Each window checks its file twice a second, like Vim's `autoread`. When another program or
an agent changes the file and you have no unsaved edits, Amber reloads it, keeping your
cursor's line and column and your scroll position, and the rendered Markdown view updates
too. Amber waits until the file has stopped changing for half a second, so a file still
being written usually isn't shown half-done. If your cursor is on the last line of text and in view,
it follows new text added at the end, like `tail -f`. The reload is one undo step. Undoing it shows your earlier text again but does not
write it over the file: autosave keeps it as a draft until you press Command-S. If you have
unsaved edits, Amber keeps your text and
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
Toggle **Edit > Vim Keybindings** for conventional text editing. The engine is a Vim 9.1
port written for Amber, checked against real Vim by a test corpus.

| Keys | Action |
| --- | --- |
| `h j k l`, `gj gk`, `w b e ge`, `W B E gE` | Move by character, line, screen line, or word |
| `0 ^ $ g_`, `N\|`, `gg G`, `H M L` | Line, document, and screen positions |
| `f F t T`, `; ,`, `%`, `( )`, `{ }`, `+ - _ Enter` | Find a character, match a bracket, move by sentence, paragraph, or line |
| `/ ? n N * # g* g#` | Search with Vim patterns; offsets such as `/foo/e` work |
| `ma`, `` `a ``, `'a`, `` `` ``, `''`, `` `[ `] ``, `` `< `> ``, Control-O, Control-I | Marks and the jump list |
| `d c y < > gu gU g~ g? =` | Operators; double one (`dd`, `gUU`) for lines |
| `iw aw iW aW is as ip ap`, `i" a" i' a'`, backtick quotes, `i( a( ib ab i[ a[ i{ a{ iB aB i< a<` | Text objects, with counts such as `d2i(` |
| `x X s S r R ~ J gJ D C Y p P gp gP ]p [p` | Edit, join, and paste |
| `i a I A gi o O`, `.`, `&`, `g&` | Insert, repeat the last change, repeat the last `:s` |
| Control-A, Control-X | Add to or subtract from a decimal, hex, or binary number |
| `v`, `V`, Control-V | Visual, Visual Line, and Visual Block; `o O gv`, and `I` `A` `$` `c` `r` in a block |
| `u`, Control-R | Undo and redo; a count works |
| Control-E/Y/D/U/F/B, `zz zt zb`, `z<CR> z. z-` | Scroll, keeping the cursor visible |
| Numeric prefix | Repeat a movement or edit, such as `3j`, `2dd`, or `2d3w` |

**Registers.** `"a` to `"z` name registers and `"A` to `"Z` append. `"0` holds the last
yank, `"1` to `"9` the last deletes, `"-` small deletes, `"_` discards. `".`, `":` and `"/`
are read-only. `"+` and `"*` reach the system clipboard. Registers are shared by every
window.

**Macros.** `qa` records into register `a`, `q` stops, `@a` plays it, `@@` repeats the last
one, and `@:` repeats the last command line. A count works, a macro stops at its first
failure, and one run is one undo step. Recursion stops at 100 levels, and one run at
100,000 keys.

**Insert and Replace mode.** Typing stays native, so input methods and emoji work. Escape,
Control-[, Control-C, Backspace, Control-W, Control-U, Control-R followed by a register,
Control-T, and Control-D work. `R` enters Replace mode, where Backspace restores the old
characters.

**Search.** `/` and `?` open the footer. Up and Down browse earlier searches. Patterns use
Vim's default "magic" syntax (`\<`, `\(`, `\|`, `\+`, `\{n,m}`, `\v`, `\c`, `\d`, and so on);
an unsupported pattern is an error, not a guess. Command-F still opens the native find bar.

Standard Mac shortcuts remain available in every mode. Not built: plugins, mappings,
shell commands, Vim script, splits, folds, and insert completion. Every place where Amber
deliberately differs from Vim is listed, with its reason, in
[`Tests/VimComparisonTests/KnownDifferences.md`](Tests/VimComparisonTests/KnownDifferences.md).

### Performance

Single keys stay under 16 ms on a 1 MB document. Two known limits: `:%s` with 10,000 matches
over 1 MB takes about 0.1 s in the engine but about 0.28 s in a window, where AppKit lays
out the replaced text; and `(` or `)` across 1 MB with no sentence end scans the whole text
(about 0.1 s in a release build).

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

Tab completes file paths after `:e` and `:w`; press it again to cycle through matches, or
press it on an empty path to cycle through recent files. Paths expand `~`; relative paths start beside the current file, or in your home directory
for unnamed documents. The rest of the command is treated as the literal filename, including
spaces. Unsupported commands show an error without changing the document.

### Editing commands with ranges

Text commands take an optional range before the name: line numbers, `.`, `$`, `%`, marks
(`'a`, `'<,'>`), patterns (`/foo/`, `?foo?`), offsets (`.+1`, `$-2`), and `;` or `,`
between two addresses. In Visual mode, `:` starts the line with `'<,'>`.

| Command | Action |
| --- | --- |
| `:{range}d [x]`, `:y [x]`, `:pu[t][!] [x]` | Delete, yank, or put lines, optionally with register `x` |
| `:{range}m {address}`, `:t {address}`, `:co {address}` | Move or copy lines |
| `:{range}j[!]` | Join lines (`!` keeps the spacing) |
| `:{range}>`, `:{range}<` | Shift lines; repeat the character to shift more |
| `:{range}s/pat/rep/[flags] [count]` | Substitute; flags `g i I n e &` |
| `:&`, `:&&`, `&`, `g&` | Repeat the last substitute |
| `:{range}g/pat/cmd`, `:g!/pat/cmd`, `:v/pat/cmd` | Run a command on matching (or non-matching) lines |
| `:{range}norm[al][!] keys` | Run Normal-mode keys on each line |
| `:{range}sort[!] [i n u r] [/pat/]` | Sort lines |
| `:retab[!]` | Convert tabs and spaces to the `tabstop` and `expandtab` settings |
| `:noh`, `:u`, `:red` | Clear search highlights, undo, redo |
| `:{n}` | Go to line `n` |

Replacement strings support `&`, `\0` to `\9`, `\n`, `\r`, `\u \U \l \L \e \E`. One `:s`, `:g`,
`:norm`, or macro run is one undo step.

## Options with `:set`

`:set` uses Vim's forms: `:set ts=2`, `:set ic`, `:set noic`, `:set ic!`, `:set invic`,
`:set ts?`, `:set ts&`, `:set ts+=2`, and several options at once. A bare `:set` lists the
options that differ from their defaults. A change applies to every window until Amber quits.
Defaults are Amber's own, not Vim's.

| Option (short) | Default | Meaning |
| --- | --- | --- |
| `tabstop` (`ts`) | `4` | Width of a tab |
| `shiftwidth` (`sw`) | `4` | Indent step for `>`, `<`, Control-T, and Control-D |
| `softtabstop` (`sts`) | `0` | Width of Tab and Backspace in Insert mode; 0 turns it off |
| `expandtab` (`et`) | on | Insert spaces instead of tab characters |
| `autoindent` (`ai`) | off | A new line copies the previous line's indent |
| `textwidth` (`tw`) | `0` | Line width for `gq`; 0 formats to 79 |
| `nrformats` (`nf`) | `bin,hex` | Number kinds Control-A and Control-X recognize |
| `ignorecase` (`ic`) | off | Searches ignore case |
| `smartcase` (`scs`) | off | With `ignorecase`, a capital in the pattern makes it case-sensitive |
| `hlsearch` (`hls`) | on | Highlight every match of the last search |
| `incsearch` (`is`) | on | Move to the match while typing a search |
| `wrapscan` (`ws`) | on | Searches wrap around the ends of the document |
| `autoread` (`ar`) | on | Reload files changed outside Amber |
| `clipboard` (`cb`) | empty | `unnamed` or `unnamedplus` makes yank and put use the system clipboard |
| `scrolloff` (`so`) | `0` | Lines kept visible around the cursor |
| `showcmd` (`sc`) | on | Show pending keys in the status line |
| `timeoutlen` (`tm`) | `1000` | Accepted; has no effect until mappings exist |
| `number` (`nu`) | off | Show line numbers in a gutter |
| `relativenumber` (`rnu`) | off | Show distances from the cursor line; with `number`, a hybrid |
| `wrap` | on | Wrap long lines; off scrolls sideways |
| `list` | off | Show tabs as `>`, trailing spaces as `-`, and line ends as `$` |
| `cursorline` (`cul`) | off | Tint the cursor's line |

## amberrc

Amber reads `~/.config/amber/amberrc` once at launch. Each line is blank, a comment that
starts with `"`, or a `set` or `:set` line. A missing file is fine. A bad line is skipped
and reported in the status line with its line number; it never blocks launch.

```vim
" ~/.config/amber/amberrc
set ts=2 sw=2
set ignorecase smartcase
set number
set scrolloff=5
```

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
