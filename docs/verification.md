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
