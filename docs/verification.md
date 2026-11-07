# Current verification — multiple windows and Vim file commands

| Acceptance criterion | Result | Evidence |
| --- | --- | --- |
| One independent document per window; no tabs | PASS | Native Cmd-N and Window menu; independent buffers and undo/session ownership |
| :w, :wq, :wqa, :q, :x, :e | PASS | Native command entry, file writes and window effects; parser and workspace tests |
| Cancelled/failed saves keep windows open | PASS | Native Save/Close/:wqa cancellation; forced write-all failure regression |
| All open drafts survive application quit | PASS | Native quit/relaunch restored legacy scratchpad plus second draft separately |
| Protect named/unnamed edits and file ownership | PASS | E37 gates, symlink/hardlink reuse, forced cross-window save/edit refusal, duplicate recovery preservation |
| Old header alignment, fonts and margins | PASS | Same prior label geometry; layout reapplied after showing each window; independent UI review A- |
| Build, signature and regression suite | PASS | Release bundle installed in /Applications; 44 tests pass |
| Independent review | PASS | Code A- and UI A-, no unresolved material findings |

The native success checks for :w/:e/:wqa/:x used the exact production core/window/view/app
sources with a separate injected recovery directory in an isolated validation bundle, so the
user's scratchpad was not saved, replaced, or closed by those checks. Native :wq was also
verified in a second real-app test window, closing only that window. The original scratchpad
remained byte-for-byte intact in its legacy recovery file; private backups stay in ignored build/.

Current scope supersedes the original one-window limit at the user's explicit request.
Changes remain within app/core modules, matching tests, README and design/verification docs.
The only runtime additions are the pure command parser, footer command entry, and per-window
ownership/lifecycle. No tabs, split panes, external commands, or settings system were added.

---

# Amber verification — 2026-11-07

| Acceptance criterion | Result | Evidence |
| --- | --- | --- |
| Native Mac single-document app | PASS | Release bundle built; Finder cold-launch opened ColdLaunch.txt in one window |
| Amber terminal styling, smaller body | PASS | Native rendered window inspected; body12/header12/footer11; independent UI review A-, PASS |
| Temporary draft autosave and restart recovery | PASS | Untitled text restored after quit/relaunch; recovery JSON matched latest text after immediate Save/Cancel |
| Save, Save As, named autosave, Markdown opening | PASS | Native dialogs saved Smoke.md; editing updated actual UTF-8 bytes; native Open restored exact Markdown |
| Unsaved replacement/cancellation | PASS | New Save/Discard/Cancel; cancelled New/Open preserved buffer; Discard reset to empty |
| Safe file handling | PASS | Ten real codec/filesystem tests, including Unicode/BOM/newline round trips, conflicts, deletion, failed open/write |
| Vim-style bindings and long documents | PASS | Seven AppKit component tests, including cw edge cases, Unicode visual delete, modes, dd/P and 500-line resize |
| Independent code review | PASS | Reviewer A-, no unresolved material findings; native undo checked independently |

Final suite: 17 tests, zero failures. Build: release, local ad-hoc signature validated.
App has no third-party packages or services. Files changed only in Sources, Tests, scripts,
docs, Package.swift, README.md, and .gitignore. No remote repository was configured.

Scope additions were explicitly requested: autosave, smaller editor body, Vim keybindings,
and app display name Amber. Internal executable/bundle identifier and recovery location
remain stable to avoid invalidating existing recovery data. Vim is a documented subset.

## Compact layout follow-up

User requested removal of wasted margins before installation. Removed the 16-point outer
bezel, reduced editor inset from 22 to 8 points, and removed extra line-fragment padding.
Header and footer are 28 and 22 points high; their fonts remain 12 and 11 points, with
12-point body text. The amber header shares the native title-bar row, reserving 84 points on the left for
window controls instead of adding a separate row. The CRT texture
continues to exclude the footer. Only TerminalView.swift and this verification note changed.

PASS: release build and signature; all 17 tests, including long-document resizing.
PASS: running native app inspected with edge-to-edge header/editor and compact text inset.
Installation is paused at the user's request; the updated bundle is build/Amber.app.

## Icon, header alignment, and launch shortcut follow-up

The icon uses a full amber tile with a dark terminal prompt and block cursor. After the
user compared its Dock size to neighboring apps, its face was reduced to 824 pixels within
the 1024-pixel canvas. It has the transparent outer safe area needed to match those tiles,
without additional padding inside the face. The build bundles all native icon sizes.
Amber explicitly loads the bundled icon at launch; the user confirmed it now appears.

Header labels now use their intrinsic 15-point height and align to the actual native
window-control center. Native component measurement changed from label706.5/button704.0
to label704.0/button704.0. Body/header/footer fonts are unchanged.

PASS: release build, local signature, and 17 existing tests. The image renderer ran at all
10 native sizes and produced a valid ICNS container. Installed in /Applications/Amber.app.
PASS: user physically confirmed Control-Option-Command-A opens Amber through the native
Open Amber shortcut. This OS-level shortcut is configured locally, not embedded in the app.

## First Insert-mode caret regression

Reproduced on a fresh native launch: first i entered Insert mode while the caret stayed
invisible until a click. Focus diagnostics showed the window was key, the app active,
and the text view already first responder. Refreshing only the insertion timer did not fix it.

Reapplying the current selection on mode change, then refreshing insertion-point state,
made the caret appear on the first i without clicking. Selection length is preserved outside
Normal mode. Native UI verified after installation; focused independent review PASS, A.
Temporary diagnostics were removed. All 17 regression tests pass.
