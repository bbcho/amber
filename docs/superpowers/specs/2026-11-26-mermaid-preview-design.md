# Mermaid diagrams in the Markdown preview

Status: approved by the user 2026-11-26 ("Yes, bundle it"). Calls marked "my call" were made
on the user's behalf and listed to them.

## Intent

In the rendered view (`:mm`, ⌘⇧M), a fenced code block whose language is `mermaid` shows the
drawn diagram instead of its source, so notes with flowcharts, sequence diagrams and the like
can be checked as they will read.

## Decisions

- **Engine:** Mermaid has no native implementation and needs a DOM. Amber bundles the official
  build and renders offline in an invisible `WKWebView`.
  - The user approved reversing the "no dependencies" rule for this one vendored file.
- **Vendored file:** `Sources/AmberNotepad/Resources/Mermaid/mermaid.min.js` from npm `mermaid`
  12.3.0, with its `LICENSE` beside it.
  - Tarball integrity `sha512-4113TdXeLAsMruJ79OpFL5O8+LTFXhQqZ260rF3tgUmiNAtRm4Uume04I+65PRN6yZ69J4f8rVYWW8zRk65UYw==`,
    verified against the registry.
  - The file's SHA-256 is `336df803d87a38b70a01e736e666c8f7601d2ce42f5e47c8fafe5d721074b9a3`.
  - A test pins this hash so the file cannot change unnoticed.
- **Offline, and no network ever:** the rendering page loads only the bundled file and carries
  a Content-Security-Policy that blocks every network request (`default-src 'none'`, scripts
  and styles from the bundle or inline only, images only from `data:`). Mermaid runs with
  `securityLevel: 'strict'`.
  - The bundle contains fetch/XHR code for optional features; the policy makes those calls
    fail instead of reaching the network.
- **Theme:** Mermaid's `base` theme, with `themeVariables` set to Amber's palette. That means
  amber text and lines, a dark or transparent background, and darker amber fills. My call:
  exact colors are left to the builder within the Phosphor palette.
- **Output:** each diagram becomes an image attachment in the preview's attributed string. It
  is vector (PDF) where macOS 13 allows, scaled down to the preview width when wider, and
  never scaled up.
- **Asynchronous:** rendering is asynchronous.
  - While a diagram is being drawn, the block shows as the existing amber code box labeled
    "rendering diagram…". When the image is ready, it replaces the box in place, keeping the
    preview's scroll position.
  - Results are cached by diagram source, so live reloads and toggling the preview don't
    re-render unchanged diagrams.
- **Errors:** a diagram Mermaid rejects shows Mermaid's error message in an amber box,
  together with the source. It never breaks the rest of the preview.
- **Unchanged:** the source text, undo, autosave, files and recovery are never touched. The
  preview stays read-only. Other code blocks render exactly as today.

## Non-goals

- Rendering Mermaid in the source editor.
- Exporting diagrams.
- Choosing a Mermaid theme in settings.
- Auto-updating Mermaid.

## Verification

1. A test pins the vendored file's hash.
2. Renderer tests with a real `WKWebView`:
   - a flowchart becomes a non-empty image;
   - a syntax error yields Mermaid's error text;
   - the page's HTML carries the network-blocking policy;
   - two renders of the same source hit the cache.
3. Preview tests:
   - a `mermaid` block becomes an image attachment, in place and after rendering finishes;
   - other code blocks are unchanged;
   - live reload keeps cached diagrams;
   - the source document is unchanged.
4. Packaging: `scripts/build-app.sh` puts the resources in the app bundle, and a build check
   finds the file inside `Amber.app`.
5. The README and a third-party notice name Mermaid 12.3.0 and its MIT license.
