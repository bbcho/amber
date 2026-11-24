# Markdown Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `:mm` (or ⌘⇧M) switches an Amber window between its editable Markdown source and
a read-only, amber-themed rendered view that Vim keys scroll.

**Architecture:**
- **Renderer:** a pure `MarkdownRenderer` turns source text into an `NSAttributedString`
  using Foundation's `AttributedString(markdown:)` and the block structure it reports.
- **Display:** `TerminalView` shows that string in a second, read-only text view in place of
  the editor. The editor's text, undo stack, and autosave are never touched.
- **Triggers:** `:mm` and a View menu item both call `EditorWindow.toggleMarkdown()`.

**Tech Stack:** Swift 5.9 package, AppKit, Foundation Markdown parsing, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-24-markdown-preview-design.md`

## Global Constraints

- macOS 13 minimum; no new package dependencies; no changes under `Sources/NotepadCore/`
  except `VimCommand.swift`.
- Rendering never writes to `terminal.textView`, `DocumentSession`, or the undo manager.
- Amber palette only: `Phosphor.amber`, `Phosphor.bar`, `Phosphor.screen`. Code uses
  `Phosphor.font`.
- Lines at most 100 characters. Run tests with `./scripts/test.sh`.
- Commit after each task with a short subject and a paragraph on why. Commit messages end
  with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Opening a file with `:e` while the rendered view shows must return to the source view of
   the new document. A stale render of the old file is wrong. Test in Task 3.
2. A command line opened from the rendered view must return focus to the rendered view, and
   must not change the hidden editor's Vim mode. Test in Task 2.
3. Resizing the window while the rendered view shows must reflow the rendered text to the
   new width. Test in Task 2.
4. A pathological note, such as lists nested 40 levels deep, must render without a crash,
   and the indent must stay below half the window width. Test in Task 1.
5. With Vim keybindings off, ⌘⇧M must still toggle, and the menu item's check mark must
   follow the active window. Test in Task 3.

---

### Task 1: Markdown renderer

**Files:**
- Create: `Sources/AmberNotepad/MarkdownRenderer.swift`
- Test: `Tests/AmberNotepadTests/MarkdownRendererTests.swift`

**Interfaces:**
- Produces: `@MainActor enum MarkdownRenderer { static func render(_ source: String) ->
  NSAttributedString }`

- [ ] **Step 1: Write failing tests.** Each test calls `render` and asserts the following.
  - `test_blocks_are_separated_by_line_breaks`: `"# Title\n\nBody text"` renders as the
    string `"Title\nBody text"`.
  - `test_headings_are_larger_than_body_text`: at the offset of "Title", the font's
    `pointSize` is greater than the font's `pointSize` at "Body". An `h1` is larger than an
    `h2`.
  - `test_list_items_get_markers_and_nested_items_indent_further`: `"- one\n  - two\n1. three"`
    renders text containing `"• one"`, `"◦ two"` and `"1. three"`. The `headIndent` of the
    paragraph style at "two" is greater than at "one".
  - `test_code_blocks_are_monospaced_in_a_box`: the font at the code text has the
    `.monoSpace` symbolic trait, and `paragraphStyle.textBlocks` is not empty.
  - `test_block_quotes_get_a_left_bar`: at the quote text, `paragraphStyle.textBlocks.first`
    has a nonzero `width(for: .border, edge: .minX)`.
  - `test_thematic_break_draws_a_rule`: `"a\n\n---\n\nb"` contains a paragraph made of 40
    `"─"` characters.
  - `test_table_cells_are_tab_separated_rows`: `"| a | b |\n|---|---|\n| 1 | 2 |"` contains
    `"a\tb\n1\t2"`. The header row is bold.
  - `test_inline_styles`: in `"*em* **strong** ~~gone~~ `code`"`, "em" has the italic trait,
    "strong" is bold, "gone" has `.strikethroughStyle` set, and "code" is monospaced.
  - `test_links_are_styled_not_clickable`: in `"[site](https://example.com)"`, "site" has an
    underline and no `.link` attribute.
  - `test_malformed_and_empty_input_still_render`: `"**unclosed"` renders as
    `"**unclosed"`, and `""` renders as `""`.
  - `test_deep_nesting_caps_indent`: a list nested 40 levels deep renders, and the maximum
    `headIndent` is at most 240 points.
  - In every test, every character's foreground color is `Phosphor.amber` or
    `Phosphor.bar`. Use a helper that checks the whole string.
- [ ] **Step 2: Run and confirm the tests fail.** Run
  `./scripts/test.sh --filter MarkdownRendererTests`. Expected: compile error, because
  `MarkdownRenderer` does not exist.
- [ ] **Step 3: Implement `render`.** The code steps:
  - **Parse:** `AttributedString(markdown:options:)` with `.full` syntax and
    `.returnPartiallyParsedIfPossible`. If parsing throws, fall back to the plain source.
  - **Block breaks:** Foundation does not insert line breaks between blocks. Insert a "\n"
    whenever a run's `presentationIntent` block identity differs from the previous run's.
  - **Lists:** prepend markers, `•` or `◦` alternating by nesting depth, or `"\(ordinal). "`
    for ordered lists.
  - **Tables:** put `\t` between cells and `\n` between rows.
  - **Thematic break:** emit the 40-character rule.
  - **Indent:** 20 points per nesting level, capped at 240.
  - **Box and bar:** use `NSTextBlock` for the code box (background
    `Phosphor.amber.withAlphaComponent(0.08)`, padding 6) and for the quote bar (a 3-point
    left border in `Phosphor.amber` at 0.6 alpha).
  - **Fonts:** body text uses the 13-point system font. Headings are bold at 24, 20, 17, 15,
    13 and 13 points. Links get underline only.
- [ ] **Step 4: Run and confirm the tests pass.** Run
  `./scripts/test.sh --filter MarkdownRendererTests`. Expected: all pass.
- [ ] **Step 5: Commit** with the message `feat: render Markdown into amber-styled text`.

### Task 2: Rendered view and its keys

**Files:**
- Create: `Sources/AmberNotepad/MarkdownPreviewView.swift`
- Modify: `Sources/AmberNotepad/TerminalView.swift` (preview scroll view, layout,
  `endCommand` focus)
- Test: `Tests/AmberNotepadTests/MarkdownPreviewTests.swift`

**Interfaces:**
- Consumes: `MarkdownRenderer.render(_:)` from Task 1.
- Produces, on `MarkdownPreviewView: NSTextView`:
  - `var commandRequested: (() -> Void)?`
  - `func scroll(lines: Int)`
- Produces, on `TerminalView`:
  - `let preview: MarkdownPreviewView`
  - `private(set) var isShowingMarkdown: Bool`
  - `func showMarkdown(_ text: NSAttributedString)`
  - `func showSource()`

- [ ] **Step 1: Write failing tests.** Each test uses a real `NSWindow` hosting a
  `TerminalView`, as `EditorTests` does. Assert the following.
  - `test_round_trip_leaves_source_text_undo_and_position_unchanged`: give the editor 300
    lines, a selection at 500, scroll to the middle, and record
    `undoManager?.canUndo`. Then call `showMarkdown` and `showSource`. Afterwards the text is
    identical, the selection is `{500, 0}`, the visible rect origin is equal, `canUndo` is
    unchanged, and the editor is the first responder. Starting in Insert mode, the
    round trip ends in Normal mode.
  - `test_showing_markdown_hides_editor_and_focuses_preview`: after `showMarkdown`, the
    editor's scroll view `isHidden` is true and the first responder is `preview`.
  - `test_preview_is_read_only_and_selectable`: `preview.isEditable == false` and
    `isSelectable == true`.
  - `test_vim_keys_scroll_the_preview`: render 300 paragraphs. `j` moves
    `visibleRect.minY` by exactly one line height, and `3j` by three. `k` reverses that.
    `G` reaches the bottom, so `visibleRect.maxY == bounds.maxY`. `gg` returns to 0.
    Control-D moves by half of `visibleRect.height`, rounded to whole lines, and Control-U
    reverses it.
  - `test_colon_in_preview_opens_command_line_and_returns_focus`: `:` calls
    `commandRequested`. After Escape in the command line, the first responder is `preview`,
    and `textView.mode` is unchanged.
  - `test_preview_reflows_on_resize`: after the window width changes from 1000 to 600, the
    preview's `textContainer.size.width` is at most 600.
- [ ] **Step 2: Run and confirm the tests fail.** Run
  `./scripts/test.sh --filter MarkdownPreviewTests`. Expected: compile error.
- [ ] **Step 3: Implement `MarkdownPreviewView`.**
  - **TextKit 1:** build the view with an explicit `NSLayoutManager`/`NSTextContainer` stack,
    because `NSTextBlock` needs TextKit 1.
  - **Appearance:** not editable, selectable, clear background, the same insets as the
    editor, and width tracking on.
  - **Keys:** `keyDown` handles counts, `j`, `k`, `gg`, `G`, Control-D, Control-U and `:`.
    Command and Option chords and arrow keys go to `super`.
  - **Scrolling:** `scroll(lines:)` moves the clip view by the layout manager's default line
    height plus 3, then calls `reflectScrolledClipView`.
- [ ] **Step 4: Implement the `TerminalView` changes.**
  - **Setup:** add a second, hidden `NSScrollView` holding `preview`, configured like
    `scroll`, and lay it out in the same frame.
  - **`showMarkdown`:** save the editor's selection and clip origin, set
    `preview.textStorage` to the string, hide `scroll`, show the preview scroll view, scroll
    it to the top, and focus `preview`.
  - **`showSource`:** reverse that and restore the saved selection and origin. If Vim is
    on, set the editor to Normal mode. Calling
    `showSource` when not showing Markdown does nothing.
  - **`endCommand`:** focus `preview` when `isShowingMarkdown`, and skip `setMode` in that
    case.
  - **Command line:** wire `preview.commandRequested` to `beginCommand()`.
- [ ] **Step 5: Run and confirm the tests pass.** Run `./scripts/test.sh`. Expected: all
  tests pass, including the existing command-bar tests.
- [ ] **Step 6: Commit** with the message
  `feat: show rendered Markdown in a read-only view`.

### Task 3: `:mm`, the View menu, and status

**Files:**
- Modify: `Sources/NotepadCore/VimCommand.swift`, `Sources/AmberNotepad/AppDelegate.swift`
  (`execute`, menu, `validateMenuItem`), `Sources/AmberNotepad/EditorWindow.swift`,
  `README.md`
- Test: `Tests/NotepadCoreTests/VimCommandTests.swift`,
  `Tests/AmberNotepadTests/WorkspaceTests.swift`

**Interfaces:**
- Consumes: `TerminalView.showMarkdown`, `showSource` and `isShowingMarkdown` (Task 2), and
  `MarkdownRenderer.render` (Task 1).
- Produces:
  - `VimCommand.markdown`
  - `EditorWindow.toggleMarkdown()`
  - `EditorWindow.isShowingMarkdown: Bool`

- [ ] **Step 1: Write failing tests.**
  - **`VimCommandTests`:** `parse("mm") == .markdown` and `parse(":mm") == .markdown`.
    `parse("mm x")` throws `E488: Trailing characters: x`, and `parse("mm!")` throws E492.
  - **`WorkspaceTests.test_mm_toggles_rendered_view_and_status`:** `execute(":mm")` on a
    window with text `"# Hi"` sets `isShowingMarkdown`. The status contains `[RENDERED]`,
    the position label reads `Rendered`, and the preview text is `"Hi"`. A second
    `execute(":mm")` returns to source, and the text is still `"# Hi"`.
  - **`WorkspaceTests.test_editing_another_file_leaves_rendered_view`:** with the rendered
    view showing, `:e <path>` of a temporary file containing "new" shows the source view
    with the text "new".
  - **`WorkspaceTests.test_menu_toggle_works_with_vim_off`:** with `vimEnabled = false`,
    invoking the menu item's action toggles the view. `validateMenuItem` returns state `.on`
    while rendered and `.off` after toggling back.
- [ ] **Step 2: Run and confirm the tests fail.** Run `./scripts/test.sh`. Expected: compile
  errors for `.markdown` and `toggleMarkdown`.
- [ ] **Step 3: Implement.**
  - **`VimCommand`:** add `case markdown`, parsed from `mm` in the no-path group.
  - **`AppDelegate.execute`:** add the case `.markdown: editor.toggleMarkdown()`.
  - **View menu:** add a menu between Edit and Window with the item "Rendered Markdown",
    key `m`, modifiers `[.command, .shift]`, target `self`, and action `toggleMarkdown`,
    which calls `activeEditor?.toggleMarkdown()`.
  - **`validateMenuItem`:** set that item's state from `activeEditor?.isShowingMarkdown`.
  - **`EditorWindow.toggleMarkdown`:** render `terminal.textView.string`, or show the
    source again.
  - **`updateStatus`:** when rendered, prefix the status with `[RENDERED]  ` and show the
    position as `Rendered`.
  - **`showDocument`:** call `terminal.showSource()` first.
  - **README:** add a "Markdown preview" section, and add `:mm` to the command table.
- [ ] **Step 4: Run and confirm the tests pass.** Run `./scripts/test.sh`. Expected: all
  pass.
- [ ] **Step 5: Commit** with the message
  `feat: toggle the Markdown preview with :mm or Command-Shift-M`.

### Task 4: Verify in the app and review

- [ ] **Step 1:** Run `./scripts/build-app.sh`. Expected: `Built …/build/Amber.app`.
- [ ] **Step 2:** Open the app on a sample note with every block type. Run `:mm`, take a
  screenshot, scroll with `j`, `G`, `gg` and Control-D, run `:mm` again, and confirm the
  cursor returned to where it was. Save the screenshots to the scratchpad.
- [ ] **Step 3:** Have an independent reviewer subagent check the diff against the spec.
  Fix material findings, then rerun the suite.
