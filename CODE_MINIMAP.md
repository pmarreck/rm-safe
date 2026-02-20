# CODE_MINIMAP

- README.md: Overview, usage, and platform notes.
- PLAN.md: Active work plan and completion tracking.
- LICENSE: MIT license text.
- bin/rm-safe: Main LuaJIT rm-safe implementation.
	- CLI parser: supports rm-safe flags/options (`-f/-i/-r/-v`, `--undo`, `--undo-picker`, `--help`, `--about`, `--test`).
	- init/get_trash_base/detect_capabilities: resolves trash paths, initializes dirs/log, and detects optional helpers (`gum`, `fzf`, `gio`, `trash-put`, `lsattr`).
	- trash_item: moves files/directories to trash with protection checks, optional picker utilities, and action logging.
	- undo_with_offset/undo_picker/restore_trash_entry: restores `TRASH_MANUAL` entries from log history.
	- resolve_path/is_protected/is_immutable/url_encode_path/create_trashinfo/get_unique_name: path safety, immutability checks, and XDG trash metadata generation.
	- run_tests: integrated runner that executes external test suites.
- bin/rm-safe.bash: Preserved Bash baseline implementation for comparison benchmarks and rollback safety.
- bin/rm: Shim that routes rm -> rm-safe with fallback to system rm.
- bin/test/rm-safe_test: Undo/restore tests and picker interaction tests.
	- Includes symlink-only PATH overlay helper to force `gum`-missing/`fzf`-present behavior even when both tools share one directory (common on Nix).
- bin/test/rm_override_test: Shim behavior tests.
- bin/test/capture.bash: capture() helper to collect stdout/stderr/rc for tests.
