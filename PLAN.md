# Plan

Goal: Make `bin/test/rm-safe_test` reliably exercise the fzf fallback path when gum/fzf share a PATH directory (e.g., Nix), using symlink-only temporary PATH overlays. Done means:
- No skip for the gum/fzf shared-dir case.
- Overlay setup never copies binaries.
- Full test suites remain green.

- [x] Add helper logic to construct a symlink-only overlay PATH with `fzf` available and `gum` hidden (completed: 2026-02-19 23:36 EST)
- [x] Update fzf fallback test to use overlay and assert symlink-based setup (completed: 2026-02-19 23:36 EST)
- [x] Fix PTY-captured warning assertion to check combined output streams (completed: 2026-02-19 23:36 EST)
- [x] Run `bin/test/rm-safe_test` (completed: 2026-02-19 23:36 EST)
- [x] Run `bin/test/rm_override_test` (completed: 2026-02-19 23:36 EST)
- [x] Run `bin/rm-safe --test` (completed: 2026-02-19 23:36 EST)
- [x] Update `CODE_MINIMAP.md` (completed: 2026-02-19 23:36 EST)
