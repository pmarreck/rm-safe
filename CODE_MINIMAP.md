# CODE_MINIMAP

- README.md: Overview, usage, and platform notes.
- PLAN.md: Active work plan and completion tracking.
- LICENSE: MIT license text.
- bin/rm-safe: Main rm-safe implementation.
	- init/get_trash_base: resolve trash paths and initialize dirs/log.
	- trash_item: move items to trash with protections and logging.
	- undo_with_offset/undo_picker: restore manual trash entries via log.
	- resolve_path/is_protected/is_immutable: safety checks and path handling.
	- run_tests: built-in test harness for core behaviors.
- bin/rm: Shim that routes rm -> rm-safe with fallback to system rm.
- bin/test/rm-safe_test: Undo/restore tests and picker interaction tests.
- bin/test/rm_override_test: Shim behavior tests.
- bin/test/capture.bash: capture() helper to collect stdout/stderr/rc for tests.
