# CODE_MINIMAP

- README.md: Overview, usage, and platform notes.
- PLAN.md: Active work plan and completion tracking.
- LICENSE: MIT license text.
- bin/rm-safe: Main LuaJIT rm-safe implementation.
	- fs shim (RM_SAFE_FS_SHIM_BEGIN/END markers): FFI filesystem primitives (exists/lexists/is_link/is_dir/is_dir_nolink/mkdir/currentdir/dir) replacing luafilesystem, so any bare luajit can run it. Uses access(2)/readlink(2) rather than `struct stat` to avoid per-platform stat layouts; `dirent` is the only per-OS struct. bin/test/fs_shim_test extracts this block verbatim and diffs it against real lfs.
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
- bin/test/fs_shim_test: Proves bin/rm-safe carries no lfs dependency. Three controls: static (no lfs in live code), differential (extracted shim vs real lfs over a file-type corpus, plus oracle-free invariants like every directory yielding "." and ".."), and end-to-end trash/undo round trips under a poisoned `require` and a genuinely bare luajit. RM_SAFE_IMPL env knob points it at a mutated copy for mutation testing.
- bin/test/capture.bash: capture() helper to collect stdout/stderr/rc for tests.
