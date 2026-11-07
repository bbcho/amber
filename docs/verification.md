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
