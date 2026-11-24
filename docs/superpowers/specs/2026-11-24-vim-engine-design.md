# Vim engine

Status: draft for approval. Date: 2026-11-24.

## Intent

Amber is a Vim-first note editor. Its current Vim layer is a 370-line `NSTextView` subclass
that maps keys to AppKit cursor methods, and it keeps diverging from Vim: `j` recentered the
view, `C` did nothing, `D` left the cursor on the line break. The user asked to fix every Vim
command and add the missing ones, at the "everyday plus power" level: a daily Vim user should
be able to edit notes with their normal habits, including macros, Visual block, and `:g`.

Success: the commands listed below behave as Vim 9.1 does with `vim --clean`, proven by tests
that run the same keys through real Vim and through Amber and compare text and cursor.

## Goals

1. Replace the ad hoc key handler with a pure Vim engine in `NotepadCore`.
2. Make every command Amber already supports behave like Vim.
3. Add the command set in "Command scope" below.
4. Keep Amber's existing behavior outside Vim: Mac shortcuts, autosave, recovery, multiple
   windows, file commands, and the Vim Keybindings toggle.

## Non-goals

- A full vimrc: `~/.config/amber/amberrc` accepts only `:set` lines and `"` comments.
- `:map` and other mappings, plugins, Vim script, `:!` shell commands.
- Splits, tabs, buffers lists, folds, spell checking, insert completion (Control-N/P).
- Uppercase file marks (`mA`) and other commands that open files implicitly.
- Insert-mode Control-O, Select mode, `q:` command-line window, `:s` confirm flag `c`.
- Markdown rendering. It is a separate approved-in-principle feature that follows this one
  and will reuse the engine's scroll motions.

## Anti-goals

These would count as failure even if the listed commands work:
- Losing or corrupting text: an engine edit that autosave writes but undo cannot reverse.
- Breaking IME, dead-key, or emoji input in Insert mode.
- A keystroke that visibly lags on an ordinary note (target below 16 ms for a 1 MB document).
- Vim behavior leaking when the Vim Keybindings toggle is off.

## Constraints

- Swift, AppKit, Swift Package Manager, macOS 13 minimum. No new package dependencies.
  Real Vim is used only by tests, never by the shipped app.
- Text offsets at the boundary are UTF-16 (`NSRange`), matching `NSTextView`. Motions move by
  grapheme cluster, so the cursor never lands inside an emoji or combining sequence.
- Lines are logical lines split by `NSString` line breaks (LF, CRLF, CR, U+2028), as `dd`
  does today. Edits keep the document's existing line-break style.
- The engine must not copy the whole document per keystroke.

## Approaches

The user picked A.

- **A. Pure engine plus thin adapter (chosen).** A value-type engine takes keys and a buffer
  snapshot and returns edits, a new cursor or selection, and effects. The text view applies
  them. Macros, `.` and `:norm` all replay keys through the engine. Almost all behavior is
  testable without a window. Cost: rewriting `VimTextView.swift`.
- **B. Extend the existing AppKit subclass.** Rejected: replaying keys through AppKit for
  macros and `.`, window-bound tests, and AppKit behavior leaking into Vim semantics.
- **C. Embed Neovim.** Rejected: breaks the no-dependency rule and the original "not an
  embedded Vim runtime" decision, and needs a second synchronized buffer.

## Architecture

### Pure core: `Sources/NotepadCore/Vim/`

- `VimKey`: a key with modifiers (character, Escape, Return, Backspace, Tab, arrows, Home,
  End, Page Up/Down, Delete, Control-letter). Parsed from Vim key notation (`<Esc>`, `<C-r>`)
  for tests, `:norm`, and macro registers.
- `VimBuffer`: a read-only view over the text (an `NSString`-backed snapshot, no copy) with
  line indexing, grapheme stepping, and character classes for words.
- `VimState`: mode (Normal, Insert, Replace, Visual, Visual Line, Visual Block, Operator
  Pending, Command Line), pending keys, count, chosen register, visual anchor, last `f`/`t`,
  last search and direction, last change for `.`, last `:s`, buffer marks, jump list, macro
  recording, and the desired column for vertical motions (Vim's `curswant`).
- `VimRegisters`: unnamed, `a`–`z` with `A`–`Z` appending, `0` yank, `1`–`9` delete shift,
  `-` small delete, `_` black hole, read-only `.` `:` `/`, and `+`/`*`. Each value records
  whether it is characterwise, linewise, or blockwise. Registers are shared by all windows,
  as in one Vim process. The clipboard registers go through an injected pasteboard function,
  so the core never touches `NSPasteboard`.
- `VimEngine.handle(_ key:, state:, buffer:, registers:, screen:) -> VimResult`, a pure
  function. `VimResult` holds the new state and registers, text edits (range plus
  replacement, in order), the new selection or selections, and effects: scroll request,
  open the command line (`:`, `/`, `?`), run an ex command, a status message, or failure.
  A failure aborts the rest of a count, macro, or `:norm`, as in Vim.
- `ScreenGeometry`: supplied by the adapter, for the few commands that depend on wrapping
  and the visible area. It holds the first and last fully visible logical lines, lines per
  page, and a function that moves an offset up or down by screen lines (`gj`, `gk`). Tests
  pass a fake.
- `VimPattern`: translates Vim's default "magic" pattern syntax into ICU syntax for
  `NSRegularExpression`. Supported: `\<` `\>` `\(` `\)` `\|` `\+` `\?` `\=` `\{n,m}` `~`
  (previous substitute string, as in Vim), `\c` `\C`, `\v` very magic, `\V` very nomagic,
  and the character classes `\s \S \d \D \w \W \a \l \u \x`. Replacement strings support `&`,
  `\0`–`\9`, `\n`, `\r`, `\u \U \l \L \e \E`. Anything else is an error, not a guess.
- `Ex/`: the parser grows from today's `VimCommand` into ranges plus commands. File commands
  (`:w`, `:q`, `:e` and the rest) keep their current behavior and are still executed by
  `EditorWindow`. Text commands run in the core on the buffer.

### Native shell

- `TerminalTextView` becomes an adapter of about 150 lines.
  - It turns `NSEvent`s into `VimKey`s, calls the engine, and applies edits through
    `shouldChangeText`/`replaceCharacters`/`didChangeText`, so undo and the autosave
    delegate keep working.
  - It applies selections, draws the block cursor, and builds `ScreenGeometry` from the
    layout manager.
  - It performs scroll effects with the minimal-scroll logic from commit `7e73ad2`.
- Insert mode stays native. AppKit inserts typed text, so IME, dead keys and emoji work. The
  adapter reports each committed insertion to the engine, so `.`, macros and the `.` register
  see what was typed. When the engine replays keys (`.`, `@q`, `:norm`), it produces the
  insert edits itself.
- Undo: one Vim change is one undo step. An insert session from `i` to Escape is one step.
  `u`, Control-R and a count on them use the window's `NSUndoManager`. One `:s`, `:g`, `:norm`,
  or macro run is one undo step.
- `TerminalView`'s footer command line handles `:`, `/` and `?`. Up and Down browse the
  history for that kind of prompt, which lasts for the app session.
- `EditorWindow` keeps the file commands and status. The status shows pending keys, as Vim's
  `showcmd` does, `recording @q`, and errors in Vim's `E…` wording.
- `AppDelegate` owns the single shared `VimRegisters` value and the command histories.
- With the Vim toggle off, the adapter passes every event to AppKit, as it does today.

### Options (`:set`)

The user asked for a Vim-like settings system, reversing the original design's "no
settings" decision.

- **Syntax:** `:set` uses Vim's forms: `:set ts=2`, `:set ic`, `:set noic`, `:set ic!`,
  `:set invic`, `:set ts?`, `:set ts&`, `:set ts+=2`, several options in one command, and
  short and long names. A bare `:set` lists options changed from their defaults. Errors use
  Vim's wording (`E518: Unknown option`, `E521: Number required`).
- **Config file:** `~/.config/amber/amberrc` is read at launch. Blank lines, lines starting
  with `"`, and `set …` or `:set …` lines are accepted; anything else is an error.
  - The file path is passed in explicitly at launch and never read from an environment
    variable.
  - Errors show in the status line with the file's line number. A bad line is skipped and
    never blocks launch.
- **Scope:** `:set` in the app changes every window for the rest of the session, as
  `:set` does for Vim's global options. `:setlocal` is out of scope.
- **Options and Amber's defaults:**
  - **Editing:** `tabstop` 4, `shiftwidth` 4, `softtabstop` 0, `expandtab` on,
    `autoindent` off, `textwidth` 0. `gq` formats to `textwidth`, or to 79 when it is 0.
    `nrformats` is `bin,hex`.
  - **Search:** `ignorecase` off, `smartcase` off, `hlsearch` on, `incsearch` on,
    `wrapscan` on.
  - **Clipboard:** `clipboard` empty, as in Vim; it also accepts `unnamed` and
    `unnamedplus`. With it empty, yank and put use Vim registers only, `"+` and `"*` reach
    the system clipboard, and Command+C and Command+V work as they do today.
  - **Screen and timeouts:** `scrolloff` 0, `showcmd` on, `timeoutlen` 1000 (accepted,
    with no effect until mappings exist).
  - **Display:** `number` off and `relativenumber` off, which add an amber line-number
    gutter (both on shows hybrid numbering, as in Vim). `wrap` on: Amber wraps today, and
    `nowrap` adds horizontal scrolling. `list` off: on shows tabs as `>`, trailing spaces
    as `-`, and the end of a line as `$`, following Vim's `listchars` defaults. `cursorline`
    off: on adds a faint amber band behind the cursor's line.
- **Why these defaults:** they are Amber's, not Vim's, wherever Amber already behaved
  differently. A tab is 4 wide, and `scrolloff` is 0, the minimal scrolling the user
  accepted in commit `7e73ad2`. Users who want Vim's values put them in `amberrc`.
- **Visual Block columns:** a tab reaches the next multiple of `tabstop`, and every other
  grapheme counts as one column.

## Command scope

### Fixes to existing behavior

- `j`/`k` move by logical line and keep the desired column. `gj`/`gk` move by screen line.
- `^` goes to the first non-blank character. `$` rests on the last character, and `$` with a
  count goes to the end of a later line.
- Normal mode never rests on a line break, except on an empty line.
- Control-D/U scroll half a page and move the cursor with the view. A count sets the scroll
  amount.
- `dd` and Visual `D` on the last line also remove the preceding line break.
- Arrow keys, Home, End, Backspace and Space in Normal and Visual modes go through the engine
  instead of AppKit, so they don't recenter the view.
- Counts work on every command that accepts one in Vim.
- `/`, `n` and `N` become Vim search through the footer. Command+F stays the native find bar.

### Motions

`h j k l`, `gj gk`, `w b e ge W B E gE`, `0 ^ $ g_ |`, `gg G` with counts, `f F t T ; ,`,
`( ) { }`, `%`, `H M L`, `/ ? n N * # g* g#`, marks `` `a 'a `` `` `` `` and `''`, `` `[ `] ``,
`` `< `> ``, Control-O and Control-I (jump list), `+ - _ Enter`.

### Text objects

`iw aw iW aW is as ip ap`, `i" a" i' a' i` a``, `i( a( ib ab`, `i[ a[`, `i{ a{ iB aB`,
`i< a<`. With counts where Vim supports them (`2i(`).

### Operators and edits

- Operators `d c y < > gu gU g~ g? =`, each combinable with any motion or text object,
  doubled to act on lines (`dd`, `gUU`), or applied in any Visual mode. `=` reindents by
  copying the previous line's indentation, a documented simplification.
- `x X s S r R ~ J gJ D C Y p P gp gP ]p [p`, `.`, `&`, `g&`, Control-A/Control-X on decimal
  numbers, `i a I A gi o O`, `u` and Control-R with counts, `"x` register prefix on all of
  these.

### Visual modes

- `v`, `V`, and Control-V block mode. `o` and `O` in Visual swap ends. `gv` reselects.
- Every operator works in each Visual mode.
- Block mode adds `I` and `A`, which insert on every line, `$`, `c`, `r` and `x`. Pasting a
  blockwise register works.

### Scrolling

Control-E/Y, Control-D/U, Control-F/B, `zz zt zb`, `z<CR> z. z-`. All use minimal scrolling
and keep the cursor visible.

### Insert and Replace mode keys

Escape, Control-[, Control-C, Backspace, Control-W, Control-U, Control-R `{reg}`, Control-T,
Control-D. Replace mode (`R`) Backspace restores the original characters.

### Macros

`q{a-z}` records and `q{A-Z}` appends. `q` stops recording. `@{a-z}`, `@@` and `@:` play,
with counts. A macro stops at the first failure. Recursion is limited to a depth of 100, and
one run is limited to 100,000 keys, so a runaway macro can't hang the app.

### Ex commands

- Ranges: line numbers, `.`, `$`, `%`, `'a`, `'<,'>`, `/pat/`, `?pat?`, `+n`, `-n`, `;`.
- Commands: `:{range}d [x]`, `y`, `m`, `t`/`co`, `j`, `>`, `<`, `s`, `&`, `g`, `g!`/`v`, `norm[al]`,
  `sor[t] [!] [i] [n] [u] [r] [/pat/]`, `ret[ab][!]` (no new tabstop), `noh`, `u`, `red`,
  `pu[t] [x]`, `{n}`. The existing file commands continue to work.
- `:s` flags `g`, `i`, `I`, `n`, `e`, `&`, plus a count.
- `:g` runs ex commands only, including `:norm`. It is limited to the same key budget as
  macros.

## Verification

1. **Engine unit tests:** table-driven cases written as text with a cursor marker, then keys,
   then the expected text and cursor. Every command in scope gets at least one case. Counts,
   registers, Unicode and CRLF get dedicated cases. No window is needed.
2. **Comparison with real Vim:** a test target runs a shared corpus of cases through
   `/usr/bin/vim -u NONE -N -i NONE -es` and through the engine, then compares text and
   cursor. Vim runs with `-c 'set …'` for Amber's option defaults, so it doesn't use
   defaults.vim's `scrolloff=5` or `tabstop=8`. Engine cases with other options pass the same
   options to Vim. It skips
   with a clear message when Vim is missing. Every case where Amber intentionally differs is
   listed in one file with a reason.
3. **Adapter integration tests:** a real window. They cover undo grouping, autosave firing
   after engine edits, minimal scrolling, Insert-mode IME text reaching `.`, register sharing
   across two windows, and the Vim toggle off sending everything to AppKit.
4. **Performance:** a timed test on a 1 MB document for `j`, `dd`, `:%s` and `.`.
5. **Options:** a parser test for every `:set` form. Engine tests run with non-default
   options (`ts=8 sw=2 et`, `ic scs`, `so=5`). Real-file tests of `amberrc` cover a good file, a
   bad line, and a missing file.
6. **Native UI:** an in-app check of a scripted session in a built `Amber.app`. Before any
   claim of completion, the existing test suite passes, plus an independent code review.

## Change budget

- **Allowed:** `Sources/NotepadCore/Vim/` (new), `Sources/NotepadCore/VimCommand.swift`
  (folded into `Vim/Ex`), `Sources/AmberNotepad/VimTextView.swift`, `TerminalView.swift`
  (command line, line-number gutter, `list` and `cursorline` drawing, `nowrap`),
  `EditorWindow.swift` status, `AppDelegate.swift` (`execute` ex dispatch, the shared
  Vim session state, and loading `amberrc`), `MarkdownPreviewView.swift` (moving its
  scroll keys onto the engine), the `amberrc` reader, the matching tests, a new test target for the comparison with Vim, the README
  Vim section, and `docs/`.
- **Forbidden:** `DocumentSession`, `TextFile`, recovery format, file ownership rules, window
  lifecycle, the visual theme, and Markdown rendering.
- **New moving parts:** the engine, the shared session state, the pattern translator, the
  extended command line, and options with `amberrc`. That is five, two over the usual limit
  of three. It is justified
  because the user explicitly chose the full scope, and each part is needed by several
  commands.
- **Delivery:** in stages on `feat/vim-engine`. Each stage passes all tests and is committed.
  The stage list belongs to the plan.

## Decisions from the builder review

- **Global Vim state:** these are app-wide, as in one Vim process: registers, the last
  search and its direction, the last `:s`, the last `f`/`t`, the last change for `.`, macro
  recording, command histories, and options. They live in one `VimSession` value owned by
  `AppDelegate`. These are per window: mode, pending keys, the Visual anchor, marks, the jump
  list, and the desired column.
- **Mouse and trackpad:** these follow Vim's `mouse=a`.
  - **Click:** in Normal mode the cursor lands on the clicked character, never on a line
    break.
  - **Drag:** a drag enters Visual mode, with the anchor where the drag started.
  - **Double- and triple-click:** a double-click selects a word, and a triple-click enters
    Visual Line.
  - **Scrolling:** scrolling moves the view only, but a Normal-mode command first brings the
    cursor back into view under `scrolloff`.
  - **Adapter:** the adapter treats a selection change it didn't make as input and sends it
    to the engine. This has its own integration tests.
- **Mac shortcuts in Normal and Visual mode:**
  - **Command shortcuts:** they keep working. Edits from Command+V, Command+X, menu
    Undo/Redo and the find bar's Replace are outside Vim: the engine records no change for
    `.` and fills no register, then resynchronizes the cursor and mode.
  - **Option chords:** these type characters, so Normal and Visual mode swallow them
    without inserting text, as Vim does with keys it has no command for. Insert mode passes
    them to AppKit unchanged.
- **Performance targets:** any single-key command on a 1 MB document finishes in under
  16 ms. `:%s` and `:g` over 1 MB with 10,000 matches finish in under 250 ms. Each produces a
  single text replacement, one undo step, and one autosave notification. `updateStatus` stops
  splitting the whole prefix into lines on every keystroke and computes line and column from
  the engine's line index.

## Left to the builder

- Internal file split inside `Vim/`, the exact representation of pending keys, and the
  internals of the undo grouping.
- Which Vim behaviors in each area need more comparison cases, beyond one per command.
- How status messages are worded, where Vim has no wording.
