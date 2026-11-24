# Markdown preview

Status: approved 2026-11-24.

## Intent

The user writes notes in Markdown and wants to check how a note renders without leaving
Amber. This reverses the original design's "no rendered Markdown" non-goal, at the user's
request.

## Goals

- `:mm` switches the window between the editable source and a read-only rendered view.
  Typing `:mm` in the rendered view switches back.
- View menu item "Rendered Markdown" (⌘⇧M) does the same, so the preview also works with
  Vim keybindings off.
- Amber-themed rendering: amber on the existing dark screen.
- Vim keys scroll the rendered view: `j k`, Control-D/U, `gg G`, counts. `:` opens the
  command line.

## Non-goals and anti-goals

- Not live or side-by-side. The render reflects the text when you switch.
- Not GitHub-faithful. Links are styled but not clickable. Images show their alt text.
- No new packages. No change to `NotepadCore`, files, recovery, autosave, or undo.
- Failure even if it renders: the rendered text reaching the document, autosave, or undo
  history, or the source cursor and scroll position being lost by a round trip.

## Approaches

- **Chosen:** a second, read-only `NSTextView` that holds an attributed string built from
  Foundation's `AttributedString(markdown:)` with full syntax, styled by walking its
  `presentationIntent` and inline intents.
- **Rejected:** reusing the editor view. Its text is wired to undo and autosave, so rendered
  text could overwrite the file.
- **Rejected:** a web view with CSS. That only pays off for GitHub-faithful output, and it
  needs a Markdown-to-HTML converter and JavaScript scrolling.

## Design

- **Renderer:** `MarkdownRenderer.render(_ source: String) -> NSAttributedString`, a pure
  function in the app target, because it needs AppKit fonts and colors.
  - Headings use larger proportional fonts. Lists are indented with bullets or numbers,
    and nested lists indent further.
  - Quotes get a left bar, code blocks a box in monospace, and horizontal rules a line.
  - Tables are tab-aligned columns. Emphasis, strikethrough and inline code are styled.
  - The parser runs with `.returnPartiallyParsedIfPossible`, so a malformed note still
    renders.
- **`:mm` command:** `VimCommand.markdown` is parsed from `mm`, and `EditorWindow` toggles
  the preview. Today's file commands are unchanged.
- **Window state:** `TerminalView` owns the preview view and shows either it or the editor.
  The source text view is never written to. The status shows `[RENDERED]`.
- **Returning to source:** this restores the saved selection and scroll position, Vim mode
  returns to Normal, and focus goes back to the editor.
- **Preview key handling:** a small key handler covers scrolling, counts, `gg`, `G` and `:`.
  It moves onto the planned Vim engine later.

## Verification

- **Renderer tests:** headings, list markers and indentation, code block font, quote,
  table, emphasis, and a malformed input.
- **Toggle tests:** a round trip leaves the source text byte-identical and the undo stack
  unchanged, and restores the cursor and scroll position.
- **Command tests:** `:mm` parses, and a trailing argument is rejected.
- **Key tests:** the scroll keys move the rendered view.
- **Final checks:** the full suite and a built app with a visual check, then an
  independent review.
