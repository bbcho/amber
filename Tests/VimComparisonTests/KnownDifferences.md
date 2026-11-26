# Known differences from Vim

The comparison test (`VimComparisonTests`) runs every case in `Corpus.swift` through
`/usr/bin/vim -u NONE -N -i NONE -es` (Vim 9.1) and through the engine, and compares the
resulting text and cursor. This file lists every place where Amber intentionally differs
from Vim. The test fails for any mismatch not named under "Corpus exceptions", and for any
listed case that now matches, so the list cannot go stale.

## How the comparison works

- Vim runs the keys with `:normal!`, which drops the rest of the keys after one that fails.
  The runner stops feeding the engine after a key that reports a failure, so both sides do
  the same. Cases avoid failing keys unless the failure is the point.
- `:normal!` trims whitespace in front of its keys, so no case starts with `<Space>`.
- Vim records macros only from typed keys, and `:normal!` keys are not typed. Macro cases
  therefore preload the register (`let @a = ...` in Vim, `storeMacro` in the engine).
  Recording itself (`q{reg}`) is covered by the engine's own tests.
- Undo and redo (`u`, Control-R) run through the window's `NSUndoManager` in the app, so
  they are covered by the adapter tests, not by the corpus.
- Scrolling and cursor commands that depend on the window (`H M L`, Control-D/U/F/B/E/Y,
  `z` commands, `gj gk`) are covered by the engine's tests with a fake screen. A headless
  Vim has no real window to compare against.
- Texts always end with a line break. A Vim buffer with no lines at all counts as the empty
  text.

## Engine simplifications

- `%` ignores quote and comment context.
- `( )` and `{ }` ignore nroff macros.
- `gj` and `gk` fail only when they cannot move.
- `M` and the scroll commands estimate the wrapped view in logical lines.
- A document without a final line break cannot hold an empty last line. After `S`, `C` or
  `x` on a one-character last line the cursor lands one line up, and `O` on an empty
  document gives `foo\n`.
- `=` copies the previous line's indent; Vim uses C indenting.
- `gq` ignores comment leaders and list markers.
- `joinspaces` is fixed on, as in Vim's default.
- Emoji clusters are never split. Vim 9.1 splits skin-tone modifiers.
- Case operators on empty text change nothing. Vim's `gUh` or `gU0` in column 0 changes a
  character or the line.
- A failed counted text object keeps the cursor where it was.
- `d<BS>` at a line start also deletes the previous line's last character.
- Hex case after Control-A comes from the number, not from Vim's remembered `hexupper`.
- Block columns count each non-tab grapheme as one column, so wide characters count as one.
- A `.` repeat of a block computes its end column from the start position's screen column.
- After `D` or `C` in block mode with reversed corners, `gv` keeps the earlier `$` state.
- A count on Visual `<` and `>` is capped at 1000.
- `:retab` counts wide characters as one column.

## Not built (the key beeps)

- `I` and `A` in `v` and `V` modes; `r<CR>` in Visual; Visual Control-A and Control-X;
  Visual `gp` and `gP`.
- Forced motions (`dvj`, `dVl`, `d<C-v>j`), insert-mode `0<C-d>` and `^<C-d>`, Control-R
  variants other than `Control-R {register}`, and Insert-mode Control-O.
- `gI`, `gR`, and the tag objects `it` and `at`.
- `nrformats` accepts `alpha`, `octal`, `unsigned` and `blank` but Control-A and Control-X
  honour only `bin` and `hex` (and decimal).
- `:set` options not in the table in the README, `:s` flags `c p # l r`, `:sort` options
  `b f l o x`, `:retab N`, `:u N`, `:~`, two-letter forms such as `:sg`, and the `|`
  command separator.
- Patterns never cross line breaks (`\n` and `\_x` are rejected). `;` chaining in searches
  (`/foo/;/bar`) is not supported, and a `/` inside `[...]` ends the pattern.

## Registers, macros, and insert mode

- The `.` register holds the net typed text, not the raw keys, and Control-T and Control-D
  are dropped from it.
- Macro registers hold key notation (`ifoo<Esc>`), so `"qp` puts the notation. Only
  `q{a-zA-Z}` records.
- A replayed `q` starts or stops recording; Vim ignores `q` while it runs a register.
- Control-C with a count acts as Escape; typed in Vim it skips the count's repeats.
- Backspace at the start of the text and Control-R with an invalid register beep without
  failing, as in Vim; a count of Backspace cannot join lines past the first pass.
- Control-R inserts literally, without `autoindent` or `textwidth`. In Replace mode,
  multi-line register text overwrites only its first line.
- Insert-mode arrows move the cursor natively and restart the insert session.
- Replace mode through an input method inserts the composed text instead of overwriting.
- After Undo from the Edit menu in Insert mode, each further typed character is its own undo
  step until the next key the engine handles.
- The Markdown preview's private session can stay recording after `qa`.
- `@` in Visual mode replays with the selection still active; Visual `@:` and `:` fail.
- Visual `r` over a tab does not split the tab.
- A block put over lines with mixed line breaks gives them all the first line's break.
- A paragraph object extending a selection at the buffer edge keeps the selection.

## Ex commands

- A backwards range is an error (E493) where Vim offers to swap it. Error messages leave out
  the `: <command>` suffix Vim 9 adds to some errors.
- `:g` runs a text command only; `:normal` with an inner range or inside a nested `:g` is
  not supported; `:g/pat/` lists lines without numbers, in one message.
- Ex edits do not adjust marks. `:s` and `:d` do not set `'[` and `']`; `:d`, `:>` and `:<`
  do not set `''`. The jump `:g` leaves is the cursor before it.
- A no-op `:2j 1` does not move the cursor to line 2.
- `:s` never splits emoji ZWJ clusters.

## Adapter and display

- A reload always sets Normal mode, and marks are not shifted for lines inserted by a reload.
- In the Markdown preview `H`, `M` and `L` scroll.
- `hlsearch` is capped at 10,000 matches and is not refreshed after AppKit typing.
- `list` draws `>` only in a tab's first cell, with no `listchars` option.
- Native non-typing edits (forward delete and similar) are not recorded for `.`.

## Performance limits

- `:%s` over 1 MB with 10,000 matches takes 73 ms (release) to 105 ms (debug) in the engine,
  under the 250 ms target, but 272 to 285 ms in a real window (debug build), because
  AppKit lays out the glyphs of the replaced megabyte.
- `(` and `)` across 1 MB with no sentence end scan the whole text: 93 to 134 ms in a
  release build and 474 to 539 ms in a debug build. Text with ordinary sentences takes 3 ms.
- A 1 MB document on one line takes minutes to lay out in AppKit.
- `:g/foo/normal Ax` over 10,000 lines of a 1 MB, 20,000-line document takes about 4.3 s in a
  window (debug build), and `u` of it 0.85 s, mostly AppKit's per-edit text storage and
  selection work. Replays, macros and undo defer the display, status and autosave work to
  their end.

## Corpus exceptions

Cases where the engine's result differs from Vim's. Format: the case name in backticks, then
the reason.

- `register/colon-register-after-an-ex-command`: Vim sets the `:` register only for typed command
  lines; Amber also sets it for lines run through `:normal` or a macro.
- `macro/colon-register-replay`: the same difference; `@:` has nothing to repeat in Vim
  when the command line was not typed.
- `insert/textwidth-wraps-while-typing`: Insert mode is native text input, so `textwidth`
  does not wrap lines as they are typed; it applies to `gq` only. Found by this comparison.
- `ex/retab-from-a-leading-tab`: after `:retab`, Vim puts the cursor at the same screen
  column (`curswant`); Amber keeps the same text offset. Found by this comparison.
- `option/nrformats-alpha`: Control-A does not step letters under `nrformats=alpha`. Found
  by this comparison.
- `option/nrformats-octal`: Control-A reads a leading-zero number as decimal under
  `nrformats=octal`. Found by this comparison.
