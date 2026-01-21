# Plan

Goal: `--undo-picker` warns and bails when gum is missing (with optional fzf fallback),
and tests that exercise gum/fzf interactions skip with a visible warning when deps
aren’t installed. Done means:
- Non-interactive `--undo-picker` still falls back to `--undo` (with a warning).
- Interactive `--undo-picker`:
  - Uses gum when present.
  - Warns and falls back to fzf when gum missing (and fzf present).
  - Warns and exits non-zero when neither gum nor fzf is available.
- Tests reflect new warning behavior; gum/fzf-dependent tests skip if missing.

- [x] Add/adjust tests for new warnings/behavior (TDD-first)
- [x] Implement undo-picker dependency handling and help/README updates
- [x] Run `bin/test/rm-safe_test` and fix issues
- [x] Run `bin/test/rm_override_test` and fix issues
- [x] Vendor `capture.bash` into repo and update tests to use local copy
- [x] Update `CODE_MINIMAP.md`
- [x] Clarify README sudo behavior differences across macOS and Linux
