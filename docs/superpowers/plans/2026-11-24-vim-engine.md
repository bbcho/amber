# Vim Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Amber's ad hoc Vim key handler with a pure, tested Vim engine covering the
"everyday plus power" command set, plus Vim-style `:set` options and an `amberrc` file.

**Architecture:**
- **Core:** a value-type engine in `Sources/NotepadCore/Vim/`. It takes one key plus the
  state and returns text edits, selections and effects, and it never touches AppKit.
- **Adapter:** `TerminalTextView` becomes a thin AppKit layer. It turns events into keys,
  applies edits as undoable changes, performs effects, and drives every key replay (`.`,
  macros, `:norm`, `:g`) through the engine.
- **Shared state:** registers, last search and options live in one app-wide session value
  owned by `AppDelegate`.

**Tech Stack:** Swift 5.9 package, AppKit, Foundation (`NSString`, `NSRegularExpression`),
XCTest. `/usr/bin/vim` 9.1 is used by tests only.

**Spec:** `docs/superpowers/specs/2026-11-24-vim-engine-design.md`. Read it before any task,
including its "Decisions from the builder review" and "Changes since approval" sections.

## Global Constraints

- **Platform:** macOS 13 minimum. No new package dependencies. Real Vim is used only in
  tests.
- **Text offsets:** offsets at every boundary are UTF-16 (`NSRange`). Motions step by
  grapheme cluster. Lines are `NSString` logical lines. Edits keep the document's line
  breaks.
- **Purity and copying:** the core never imports AppKit and never copies the whole document
  per key. Read through `VimBuffer`.
- **Option defaults (Amber's):**
  - `tabstop` 4, `shiftwidth` 4, `softtabstop` 0, `expandtab` on, `autoindent` off,
    `textwidth` 0, `nrformats` `bin,hex`.
  - `ignorecase` off, `smartcase` off, `hlsearch` on, `incsearch` on, `wrapscan` on.
  - `clipboard` empty, `scrolloff` 0, `showcmd` on, `timeoutlen` 1000.
  - `number` off, `relativenumber` off, `wrap` on, `list` off, `cursorline` off,
    `autoread` on.
- **Limits:** macros and `:g` stop at the first failure, at 100 levels of recursion, or at
  100,000 replayed keys.
- **Speed:** a single-key command on a 1 MB document takes under 16 ms. `:%s` over 1 MB with
  10,000 matches takes under 250 ms and produces one text replacement and one undo step.
- **Code shape:** lines at most 100 characters. Exhaustive `switch` statements over the
  engine's own enums have no `default` case.
- **Tests:** run with `./scripts/test.sh`, which runs two XCTest bundles, so sum both. With
  the screen locked, the 11 tests that read recovery files fail with "Operation not
  permitted"; that is environmental, not a defect.
- **Commits:** commit after each task, staging files explicitly. Messages end with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Keep passing:** every existing test, including the Vim key tests in `EditorTests` and
  `CommandBarTests`, and the reload, preview and workspace tests.

## Review Focus

1. **Insert mode:** IME, dead keys and emoji must work, and a typed insert must replay
   exactly with `.` and in macros. Tested in Task 7.
2. **Undo:** an engine change applied during a replay must stay one undo step per Vim
   change, and must never leave the document dirty without autosave firing. Tested in
   Task 7.
3. **Live reload:** a reload during Visual, Operator Pending or recording must leave the
   engine in Normal mode with no stale offsets. Tested in Task 7.
4. **CRLF and Unicode:** CRLF files and emoji must survive `dd`, `p`, `J`, `:s`, block
   insert and `>>` unchanged. Tested in Tasks 3, 4 and 6.
5. **Bad config:** a malformed `amberrc` line or an unknown `:set` option must never block
   launch or change other options. Tested in Tasks 1 and 7.

---

### Task 1: Core foundations: keys, buffer, options, registers, patterns

**Files:**
- Create in `Sources/NotepadCore/Vim/`: `VimKey.swift`, `VimBuffer.swift`,
  `VimOptions.swift`, `VimRegisters.swift`, `VimPattern.swift`
- Tests in `Tests/NotepadCoreTests/Vim/`: one file per source file

**Interfaces (Produces):**
- **`VimKey`:** `public struct VimKey: Hashable`.
  - `enum Base` has the cases `character(Character)`, `escape`, `enter`, `backspace`,
    `tab`, `up`, `down`, `left`, `right`, `home`, `end`, `pageUp`, `pageDown` and `delete`.
  - Properties are `base` and `control: Bool`.
  - `static func parse(_ notation: String) throws -> [VimKey]` understands `<Esc>`, `<CR>`,
    `<BS>`, `<Tab>`, `<C-x>`, `<lt>` and the arrow names. `var notation: String` turns a key
    back into notation.
- **`VimBuffer`:** `public struct VimBuffer` with `init(_ text: NSString)`.
  - **Lines:** `lineCount`, `lineIndex(of:)`, `lineRange(at:)` (including the break),
    `contentRange(at:)` (excluding it).
  - **Steps and positions:** `nextGrapheme(after:)`, `previousGrapheme(before:)`,
    `firstNonBlank(line:)`, and `displayColumn(of:tabstop:)` / `offset(line:displayColumn:tabstop:)`.
  - **Words:** `wordClass(at:bigWord:) -> WordClass` with the cases `.blank`, `.word` and
    `.punctuation`.
- **`VimOptions`:** `public struct VimOptions: Equatable`, holding the defaults listed above.
  - `mutating func set(_ arguments: String) throws -> String?` handles every `:set` form in
    the spec and returns a message for queries. Errors are `E518: Unknown option: x`,
    `E521: Number required after =: ts=x` and `E474: Invalid argument`.
  - `static func load(rc text: String) -> (options: VimOptions, errors: [String])`. Each
    error includes `line N:`, and a bad line is skipped without affecting the others.
  - `var changedSummary: String` is the text shown by a bare `:set`.
- **`VimRegisters`:** `public struct VimRegisters: Equatable`. A `RegisterValue` holds
  `text: String` and `kind`, which is `.characterwise`, `.linewise` or `.blockwise([String])`.
  - Functions: `value(_ name: Character, clipboard: () -> String?) -> RegisterValue?`,
    `mutating func yank(_:into:)`, `mutating func delete(_:into:small:)` and
    `mutating func setReadOnly(_:_:)` for `.`, `:` and `/`.
  - These follow Vim's rules for `"`, `0`, `1`–`9` shifting, `-`, `a`–`z`, `A`–`Z`
    appending, and `_`.
- **`VimPattern`:** `public enum VimPattern`.
  - `static func regex(_ pattern: String, ignoreCase: Bool, smartCase: Bool) throws ->
    NSRegularExpression` translates exactly the subset listed in the spec.
  - `static func template(_ replacement: String, previous: String?) throws -> String`
    produces an `NSRegularExpression` template plus case-conversion markers, which Task 6
    applies.
  - Anything unsupported throws `E486`- or `E33`-style errors. It never guesses.

- [ ] **Step 1:** Write failing tests for each type. At minimum, cover these cases with
  exact values:
  - Key notation round trips.
  - CRLF line ranges and emoji graphemes.
  - Word classes on `foo-bar baz`.
  - Every `:set` form, applied to `ts`, `et`, `ic`, `so`, `clipboard` and `list`.
  - An `amberrc` file with a bad middle line, where lines 1 and 3 still apply.
  - Register rules: a yank leaves `"1` alone, two deletes shift `1` to `2`, a small delete
    goes to `-`, `A` appends, and `_` keeps everything unchanged.
  - Pattern translations: `\<foo\>` becomes `\bfoo\b`; `\(a\|b\)\+` becomes `(a|b)+`;
    `\v(a|b)+` stays as is; a literal `(` is escaped; `\c` sets case-insensitive. Smart
    case: `ic scs` with `Foo` is case-sensitive, while `foo` is not.
- [ ] **Step 2:** Run `./scripts/test.sh` and confirm the failures.
- [ ] **Step 3:** Implement the types.
- [ ] **Step 4:** Run the suite. All tests pass.
- [ ] **Step 5:** Commit with the message `feat: add Vim keys, buffer, options, registers, and patterns`.

### Task 2: Engine core and motions

**Files:** create `Sources/NotepadCore/Vim/VimEngine.swift`, `VimState.swift`,
`Motions.swift` and `ScreenGeometry.swift`. Add the engine test-case helper and motion
tests under `Tests/NotepadCoreTests/Vim/`.

**Interfaces:**
- **Consumes:** Task 1.
- **`VimMode`:** `public enum VimMode` with the cases `normal`, `insert`, `replace`, `visual`,
  `visualLine`, `visualBlock`, `operatorPending` and `commandLine(Character)`.
- **`VimWindowState`:** `public struct VimWindowState: Equatable` holds `mode`, the pending
  keys, the count and the chosen register, plus:
  - `cursor: Int` and `desiredColumn: Int?`;
  - `visualAnchor: Int?` and `lastVisual`;
  - `marks: [Character: Mark]`, where `Mark` stores a line and column;
  - `jumpList` and `jumpIndex`;
  - `insertSession` and `recordingKeys`.
- **`VimSession`:** `public struct VimSession: Equatable` holds `registers`, `options`,
  `lastSearch: (pattern: String, forward: Bool)?`, `lastSubstitute`,
  `lastFind: (Character, FindKind)?`, `lastChange: [VimKey]?` and
  `recording: (register: Character, keys: [VimKey])?`.
- **`ScreenGeometry`:** `public struct ScreenGeometry` holds `firstVisibleLine`,
  `lastVisibleLine` and `linesPerPage`, plus `moveScreenLines: (Int, Int) -> Int`, which
  moves an offset by screen lines. `static func fake(lines:)` serves tests.
- **Results:**
  - `TextEdit` is `public struct TextEdit: Equatable { range: NSRange; replacement: String }`.
  - `VimEffect` is an `Equatable` enum with these cases: `scroll(ScrollRequest)`,
    `openCommandLine(Character)`, `undo(Int)`, `redo(Int)`, `replay([VimKey])`,
    `message(String)`, `failure`, `setClipboard(String)`, `highlightSearch(String?)`,
    `ex(String)`.
  - `VimResult` holds `window`, `session`, `edits: [TextEdit]`,
    `selections: [NSRange]` and `effects: [VimEffect]`.
- **Entry point:** `public enum VimEngine { static func handle(_ key: VimKey, window:
  VimWindowState, session: VimSession, text: NSString, screen: ScreenGeometry, clipboard:
  () -> String?) -> VimResult }`.
- **Test helper:** in tests, `assertVim("hel|lo", "w", "hello|")` writes the cursor as `|`
  and a selection as `[...]`.

- [ ] **Step 1:** Write failing tests for every motion in the spec's list. Each needs at
  least one case, plus cases with counts. Cover:
  - **Vertical:** `j` and `k` keep the desired column across short lines, and `gj` moves by
    the fake geometry.
  - **Words:** `w` across punctuation and emoji.
  - **Line ends:** `$` rests on the last character, and `2$` goes to the end of the next line.
  - **Find:** `f`/`t`/`;`/`,` repeating.
  - **Sentences, paragraphs and pairs:** `( ) { }` on blank-line paragraphs, and `%` on
    nested brackets.
  - **Screen:** `H M L` from the geometry.
  - **Marks and jumps:** marks and `''` after `G`; Control-O and Control-I.
  - **Normal mode never rests on a line break:** checked after `l`, `$`, `j` and a count.
  - **Scroll effects:** Control-E/Y/D/U/F/B and `zz zt zb z<CR> z. z-` return the right
    effect and cursor, with `scrolloff` 0 and with 3.
- [ ] **Step 2:** Run the suite and confirm the failures.
- [ ] **Step 3:** Implement the engine and motions.
- [ ] **Step 4:** Run the suite. All tests pass.
- [ ] **Step 5:** Commit with the message `feat: add the Vim engine core and motions`.

### Task 3: Operators, text objects, and Normal-mode edits

**Files:** create `Operators.swift`, `TextObjects.swift` and `Edits.swift` in
`Sources/NotepadCore/Vim/`, with matching tests.

**Interfaces:**
- **Consumes:** Task 2.
- **Produces:** operator-pending handling inside `VimEngine.handle`, and the recording of
  `lastChange`.
- **`.` (repeat):** returns `.replay(keys)`, with a new count replacing the recorded one.
- **`u` and Control-R:** return `.undo(n)` and `.redo(n)`.

- [ ] **Step 1:** Write failing tests for each item. Add CRLF and emoji cases to `dd`, `p`,
  `J` and `>>`.
  - **Operators:** `d c y < > gu gU g~ g? =` combined with a motion, with a text object, and
    doubled.
  - **Text objects:** every one in the spec, including counts such as `2i(`, and quotes on
    lines with escaped quotes.
  - **Normal-mode edits:** `x X s S r R ~ J gJ D C Y p P gp gP ]p [p`, Control-A and
    Control-X on decimal numbers, hex and binary under `nrformats`, `i a I A gi o O`, and
    `gq` with `textwidth`.
  - **Registers:** `"a`/`"A` with each operator, `"_d`, and `"+y` producing
    `.setClipboard`.
  - **`.`:** after `dw`, `ciwfoo<Esc>`, `3x`, `>>` and `p`, with a new count.
  - **`=`:** copies the previous line's indentation.
- [ ] **Step 2:** Run the suite and confirm the failures.
- [ ] **Step 3:** Implement operators, text objects and edits.
- [ ] **Step 4:** Run the suite. All tests pass.
- [ ] **Step 5:** Commit with the message `feat: add Vim operators, text objects, and edits`.

### Task 4: Visual, Visual Line, and Visual Block

**Files:** create `Visual.swift` with tests.

**Interfaces:**
- **Consumes:** Task 3.
- **Selections:** `VimResult.selections` holds one range per line in block mode.

- [ ] **Step 1:** Write failing tests for each item. Include ragged lines, tabs measured in
  `tabstop` columns, and CRLF.
  - **Modes:** `v V <C-v>`, switching between them, `o` and `O`, and `gv` after an edit.
  - **Operators:** every operator in each mode.
  - **Block commands:** `I` and `A` repeating text on every line, `$A`, `c`, `r`, `x`, and
    putting a blockwise register.
- [ ] **Step 2:** Run the suite and confirm the failures.
- [ ] **Step 3:** Implement the Visual modes.
- [ ] **Step 4:** Run the suite. All tests pass.
- [ ] **Step 5:** Commit with the message `feat: add Vim visual modes`.

### Task 5: Insert and Replace keys, search, and macros

**Files:** create `Insert.swift`, `Search.swift` and `Macros.swift` with tests.

**Interfaces:**
- **Consumes:** Tasks 1–4.
- **Insert recording:** `VimEngine.recordTyped(_ text: String, window: VimWindowState) ->
  VimWindowState` records text that AppKit inserted while typing live.
- **Search:** `VimEngine.search(_ pattern: String, forward: Bool, ...) -> VimResult` runs a
  submitted `/` or `?` prompt.
- **Macros:** `q{a-z}` and `q{A-Z}` record into `session.recording`, and `@x`, `@@` and `@:`
  return `.replay`.

- [ ] **Step 1:** Write failing tests for each item.
  - **Insert keys:** in Insert and Replace modes, Escape, Control-[, Control-C, Backspace,
    Control-W, Control-U, Control-R with a register, Control-T and Control-D. Replace-mode
    Backspace restores the original characters.
  - **Replay:** a replayed insert of `foo<BS>x` gives `fox`.
  - **Search:** `/`, `?`, `n`, `N` with `wrapscan` on and off, `* # g* g#`, and `ic scs`.
    `hlsearch` emits `.highlightSearch(pattern)`.
  - **Macros:** a recording captures the keys typed live, including inserts, and `@q` replays
    them.
- [ ] **Step 2:** Run the suite and confirm the failures.
- [ ] **Step 3:** Implement insert keys, search and macros.
- [ ] **Step 4:** Run the suite. All tests pass.
- [ ] **Step 5:** Commit with the message `feat: add Vim insert keys, search, and macros`.

### Task 6: Ex commands with ranges, `:set`, `:g`, and `:norm`

**Files:** create `Sources/NotepadCore/Vim/Ex.swift` and `ExRunner.swift`. Fold
`VimCommand.swift` into `Ex.swift`, keeping the existing file commands' cases and error
wording. Move or keep `VimCommandTests` so they still pass, and add `ExTests`.

**Interfaces:**
- **Parsing:** `ExCommand.parse(_ line: String) throws -> ExCommand` returns one of:
  - `.file(VimCommand)` for the existing file commands;
  - `.set(String)`, `.markdown` and `.checkTime`;
  - `.text(range: ExRange?, command: ExTextCommand)` for text commands.
- **Running:** `ExRunner.run(_ command: ExTextCommand, range:, window:, session:, text:) ->
  VimResult`. The `:norm` and `:g` commands return `.replay` effects carrying the line
  numbers.

- [ ] **Step 1:** Write failing tests for each item.
  - **Ranges:** every range form in the spec.
  - **Commands:** every command in the spec.
  - **`:s` flags:** `g i I n e &`, a count, `~`, and case markers.
  - **`:g`:** `:g/pat/d`, `:g!/pat/norm Ax`, and `:v`.
  - **`:sort` options:** `!`, `i`, `n`, `u`, `r` and a `/pat/`.
  - **`:retab`:** with `et` and `noet`.
  - **Undo:** one `:%s` over 10,000 matches is a single edit.
  - **Speed:** the speed test from the global constraints.
  - **Errors:** wording for an unknown command, a trailing argument and an invalid range.
- [ ] **Step 2:** Run the suite and confirm the failures.
- [ ] **Step 3:** Implement the parser and runner.
- [ ] **Step 4:** Run the suite. All tests pass.
- [ ] **Step 5:** Commit with the message `feat: add Vim ex commands, ranges, :set, :g, and :norm`.

### Task 7: AppKit adapter and session wiring

**Files:** rewrite `Sources/AmberNotepad/VimTextView.swift` as the adapter. Modify
`TerminalView.swift` (the `/` and `?` prompts, history, search highlighting, and reload
integration), `EditorWindow.swift` (status, ex dispatch for text commands, the `autoread`
gate), `AppDelegate.swift` (the shared `VimSession`, loading `amberrc` from an explicit
path, ex dispatch), `AmberNotepad.swift` (passing `~/.config/amber/amberrc`), and
`MarkdownPreviewView.swift` (scroll keys through the engine). Update the matching tests.

**Interfaces:**
- **Consumes:** Tasks 1–6.
- **Keeps:** the existing `TerminalTextView` API (`mode`, `setMode`, `vimEnabled`,
  `modeDidChange`, `commandRequested`). `Mode` adds the new cases.
- **Produces:** `AppDelegate.vimSession` (one per app), `AppDelegate(recoveryURL:rcURL:)`,
  and `TerminalTextView.feed(_ keys: [VimKey])`. That function is the replay loop, which
  enforces the limits.

- [ ] **Step 1:** Write failing adapter tests, using real windows, for each item.
  - **Undo grouping:** one undo step per change, including inside `@q` and `:norm`.
  - **Autosave:** it fires after engine edits.
  - **Insert recording:** text arriving through `insertText(_:replacementRange:)` (IME)
    reaches `.` and macros.
  - **Shared registers:** a yank in window A can be put in window B.
  - **Option chords:** they're swallowed in Normal mode and type in Insert mode.
  - **Mouse:** a click lands on a character, and a drag enters Visual mode.
  - **Vim off:** with the toggle off, AppKit handles every event.
  - **Reload:** a reload during Visual mode or a recording leaves Normal mode.
  - **Settings:** `:set ts=2` applies to every window.
  - **Bad `amberrc`:** a bad line shows a status error and launch continues.
  - **Search:** `/` submits a search, and `n` repeats it.
  - **`autoread`:** with `:set noautoread`, the background check doesn't reload.
  - **Preview:** its `j`, `gg` and `G` behavior is unchanged.
  - **Existing tests:** all keep passing.
- [ ] **Step 2:** Run the suite and confirm the failures.
- [ ] **Step 3:** Implement the adapter and session wiring.
- [ ] **Step 4:** Run the suite. All tests pass.
- [ ] **Step 5:** Commit with the message `feat: drive Amber's editor with the Vim engine`.

### Task 8: Display options

**Files:** modify `TerminalView.swift` and the adapter. You may create
`Sources/AmberNotepad/LineNumberGutter.swift`.

**Interfaces:**
- **Consumes:** the options from Task 7.
- **Produces:**
  - `number` and `relativenumber`: an amber gutter, using hybrid numbering when both are on.
  - `list`: shows tabs as `>`, trailing spaces as `-`, and line ends as `$`, drawn without
    changing the text.
  - `cursorline`: a faint band behind the cursor's line.
  - `nowrap`: horizontal scrolling.
  - `tabstop`: the tab width on screen.

- [ ] **Step 1:** Write failing tests for each item.
  - **Gutter:** the right numbers for the visible lines, in absolute, relative and hybrid
    modes.
  - **List markers:** drawn, checked by sampling pixels, while the document text is
    unchanged.
  - **Cursor band:** it follows the cursor.
  - **`nowrap`:** a long line doesn't wrap.
  - **`ts=8`:** the tab width changes.
- [ ] **Step 2:** Run the suite and confirm the failures.
- [ ] **Step 3:** Implement the display options.
- [ ] **Step 4:** Run the suite. All tests pass.
- [ ] **Step 5:** Commit with the message `feat: add Vim display options`.

### Task 9: Comparison with real Vim, speed tests, and docs

**Files:**
- Add the test target `VimComparisonTests` (depending on `NotepadCore`) in `Package.swift`.
- Create `Tests/VimComparisonTests/Corpus.swift`, `VimRunner.swift` and
  `KnownDifferences.md`.
- Update the README's Vim section, adding a `:set` table and `amberrc`.

**Interfaces:**
- **Runner:** `/usr/bin/vim -u NONE -N -i NONE -es` with `-c 'set ts=4 sw=4 et so=0 ...'`
  plus `-c 'exe "norm! ..."'`. It writes the resulting text and cursor to a temporary file.
- **Missing Vim:** the target skips with a clear message when `/usr/bin/vim` is absent.

- [ ] **Step 1:** Build a corpus of at least 150 cases, covering every command family in the
  spec. Each is compared for text and cursor. The only exceptions are those listed in
  `KnownDifferences.md`, each with its reason.
- [ ] **Step 2:** Run the comparison. Fix engine differences that aren't in the known list.
- [ ] **Step 3:** Run the speed tests and the full suite.
- [ ] **Step 4:** Update the README.
- [ ] **Step 5:** Commit with the message `test: compare the Vim engine against real Vim`.
