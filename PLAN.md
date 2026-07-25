# Plan

Goal (done): remove the `luafilesystem` (lfs) dependency from `bin/rm-safe` so
the LuaJIT implementation runs under ANY luajit — bare or stocked. It used to
die with `module 'lfs' not found` inside any flake dev shell that puts a bare
luajit first on PATH, i.e. inside project directories, which is where agents do
most of their work.

## Consumed lfs API surface (verified against 45d28f9)

| lfs call | sites | replacement |
|---|---|---|
| `attributes(p)` / `attributes(p,"mode")` | 3 | `access(2)` |
| `symlinkattributes(p)` | 3 | `readlink(2)` + `access(2)` |
| `mkdir(p)` | 1 | `mkdir(2)` |
| `currentdir()` | 2 | `getcwd(3)` |
| `dir(p)` | 1 | `opendir`/`readdir`/`closedir` |

`lfs.dir` was NOT in the kickoff brief — it arrived in `1167cc2`
(fragment-per-action log). The working copy was on a detached HEAD 3 commits
behind, so building on that base would have missed it entirely.

Key design call: only three distinctions are ever consumed — *exists?*,
*is-directory?*, *is-symlink?*. None require reading `struct stat`, so the shim
uses `access`/`readlink` and the `struct stat` layout minefield (Linux x86_64 vs
aarch64 vs Darwin, `stat64`/`__xstat`/`$INODE64` symbol variants) is avoided
entirely. `dirent` is the one platform-divergent struct left, and the test pins
it: a wrong `d_name` offset cannot produce the "." and ".." every directory has.

- [x] Reconcile repo state: detached HEAD `fab9134`, 3 commits behind; fast-forwarded `yolo` to `45d28f9` (2026-07-24 21:44 EST)
- [x] Witness RED under both a poisoned-`require` harness and a genuinely bare luajit (2026-07-24 21:47 EST)
- [x] `bin/test/fs_shim_test`: static + differential-vs-lfs + end-to-end no-lfs controls (2026-07-24 22:00 EST)
- [x] FFI shim implemented inline in `bin/rm-safe`; all 10 call sites rewritten (2026-07-24 21:55 EST)
- [x] Mutation battery: 7/7 semantic corruptions killed on Linux, Darwin dirent offset killed on macOS (2026-07-24 22:10 EST)
- [x] Wire the new suite into `run-all`, `--test`, and the flake check; drop the `require("lfs")` gate that silently skipped the luajit lane (2026-07-24 22:03 EST)
- [x] macOS verification on peters-macbook-pro-m4-max (arm64): 5 lanes / 0 failed, incl. bash-3.2 lane 9/9 (2026-07-24 22:12 EST)
- [x] `flake.nix`: package uses bare `pkgs.luajit`; lfs kept ONLY as the test oracle (2026-07-24 22:02 EST)
- [x] README / CODE_MINIMAP / dirtree updated (2026-07-24 22:15 EST)

## Found and fixed en route (separate commits)

- [x] `pb_encode` fallback returned the raw path when `printable-binary` was absent, so fragment names kept their slashes, the write failed silently, and **`--undo` could never restore anything**. `printable-binary` is not a documented dependency, so this was the default experience for most installs. Both impls fixed + regression test. This was why `checks.tests` was red in the sealed sandbox. (2026-07-24 22:05 EST)
- [x] `rm_override_test` built its no-luajit PATH by dropping whole directories, which on NixOS also dropped `bash`, so the shim never ran and 2 assertions failed for unrelated reasons. Symlink-overlay instead; also stopped its cleanup trap using a bare `rm`. (2026-07-24 22:08 EST)

## Open / not addressed (deliberately out of scope)

- [ ] `sha256_hex_short` shells out to `shasum`, which is absent in the nix
      sandbox (coreutils provides `sha256sum`). Only reachable for paths whose
      encoded fragment name exceeds 200 chars, so it did not surface here — but
      the same silent-fallback shape as the pb_encode bug. Worth a look.
- [ ] `bin/rm` dispatches to the luajit impl on `command -v luajit` alone. That
      is now correct (any luajit works), but it is worth an explicit test.
