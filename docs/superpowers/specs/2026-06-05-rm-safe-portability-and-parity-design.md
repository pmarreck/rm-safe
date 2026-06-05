# rm-safe: portability, implementation parity, and packaging — design

Date: 2026-06-05
Status: approved (brainstorm), pending spec review

## North star

Make rm-safe trivial to adopt for anyone, **even with no Nix and no LuaJIT**.
A stock macOS box (BSD coreutils, no Homebrew) and a stock Linux box (GNU
coreutils) must both get a working `rm-safe` from `git clone` with zero
installs. LuaJIT is an optional speed upgrade; Nix is an optional managed
environment. Neither is ever required.

## Problem

1. `bin/rm-safe` is a LuaJIT script (`require("lfs")`). It only runs where
   luajit + lfs resolve. Non-luajit users are stranded.
2. **`bin/rm-safe.bash` is broken on stock macOS — the real, dangerous blocker.**
   It uses bash-4+ associative arrays (`local -A opts`, line 953) and `mapfile`
   (line 325). Apple freezes `/bin/bash` at **3.2** (GPLv3), where assoc arrays
   don't exist: under `set -u` the script dies with `force: unbound variable`,
   **exits 0, and never trashes the file** — a silent no-op in an `rm`
   replacement. (Audited: GNU-vs-BSD coreutils were NOT the blocker — BSD
   `mktemp` accepted `--tmpdir`, readlink/realpath already have BSD fallbacks.)
3. The test suite (`bin/test/rm-safe_test`) always exercises the luajit impl
   (resolves `rm-safe` from PATH). The bash impl is never tested, so the two
   can silently drift in feature or behavior. Neither bash version is tested.
4. There is no project `flake.nix`, so Nix users have no reproducible
   dev/test/CI environment and the global luajit-lfs gap (see
   `~/.config/nix/flake.nix`) is the only thing making the luajit impl work.

## Decisions (locked)

- **Single selector env var: `RM_SAFE_BIN`** (absolute path to an executable).
  No `RM_SAFE_IMPL`. Honored by both the `bin/rm` shim and the test suite. The
  three test lanes point it at small wrapper execs that pin the interpreter, so
  the one-knob design is preserved.
- **Keep bash-4+ features but gate them.** Detect the running bash early into a
  `BASH4` flag (`1` if `BASH_VERSINFO[0] >= 4`, else `0`); gate the 4+-only
  constructs with a 3.2-compatible fallback. Do **not** dumb the script down to
  3.2 unconditionally. The two 4+ constructs to gate: the `opts` associative
  array and `mapfile` (full audit confirms these are the only two).
- **Three-version test matrix:** luajit, bash-4+, bash-3.2. Each runs the full
  `rm-safe_test` suite; lanes skip gracefully when their runtime is absent
  (e.g. no bash-3.2 on Linux CI).
- **Bash impl still prefers GNU tooling by g-prefixed names** for call-site
  clarity, with fallback chain g-prefixed → detected-GNU (`--version | grep -qi
  GNU`) → BSD. (Now largely cosmetic for correctness, since BSD tools work, but
  retained per request.)
- **`rm-safe.bash` stays self-contained** (inline prelude, copy-and-go single
  file) rather than sourcing a shared lib.
- **Degraded-setup warnings, suppressible.** Warn once to stderr when (a)
  running under bash 3.2, or (b) luajit is unavailable so the bash impl is used.
  Both are silenced by a single env var **`RM_SAFE_QUIET`** (truthy = no warn).
  Warnings go to stderr only and never change exit codes or stdout.
- **flake.nix scope: devShell + checks + packages.** Convenience only.

## Components

### 1. `rm-safe.bash` — universal, self-contained, zero-dependency

**Bash-version gating (the real portability fix).** Early in the script, set
`BASH4=1` when `${BASH_VERSINFO[0]} -ge 4`, else `BASH4=0`. Gate the two 4+-only
constructs:

- **`opts` associative array** → reach it through accessors `opt_get <name>` /
  `opt_set <name> <val>`. Internally: assoc array when `BASH4=1`, four scalar
  vars (`__opt_force` …) when `BASH4=0`. The ~19 call sites use the accessors,
  so the 4+ feature is kept where available and 3.2 still works.
- **`mapfile -t arr < <(...)`** (line 325) → `if BASH4: mapfile; else: while
  IFS= read -r line; do arr+=("$line"); done`.

**Degraded-setup warning.** If `BASH4=0` and `RM_SAFE_QUIET` is not truthy, emit
one stderr line: `rm-safe: note: running under bash ${BASH_VERSION%%(*}; install
bash 4+ or luajit for full speed/features (set RM_SAFE_QUIET=1 to silence)`.
stderr only; does not affect exit code or stdout.

**Tool-resolution prelude.** Inline near the top. For each resolved tool, pick a
binary and (where it matters) record the detected flavor (gnu|bsd):

Resolution order per tool:
1. g-prefixed name if present (`gsed`, `gmktemp`, …) → flavor `gnu`.
2. else plain name **verified GNU**: `"$plain" --version 2>/dev/null | grep -qiE 'GNU|coreutils'` → flavor `gnu`.
3. else plain name present → flavor `bsd`.

Command vars (the body never calls bare names): `GSED GAWK GGREP GFIND GMKTEMP
GREADLINK GREALPATH GDATE GMKDIR GMV GID`. Resolving to g-prefixed names when
present satisfies the "GNU intent is explicit at the call site" goal even
though most of these tools are used portably.

**Actual GNU/BSD divergence surface (audited against current call sites) is
narrow** — most usages are already portable:

- `sed` (line 177): stdin→stdout filter, POSIX BRE, no `-i`. Portable.
- `find` (`--test` runner): `-name -exec + -delete -print -quit -type`. Portable on BSD find.
- `date`: `date -u "+FMT"`. Portable. No `-d` arithmetic used.
- `awk grep cat id mkdir mv uname`: portable as used.

So only **two** things need real GNU/BSD handling, expressed as wrapper
functions so the body is platform-blind:

- `_mktemp_dir <prefix>` — GNU `mktemp -d --tmpdir "$1.XXXXXX"` vs BSD
  `mktemp -d -t "$1"`. (The single genuine GNU-only call, at line 760 and in
  the test harness at line 9.)
- `_realpath <p>` / `_readlink_f <p>` — **formalize the detection the bash impl
  already has** (lines 80–81 probe `readlink -f`; lines 382–393 try `realpath`
  then `readlink -f`). Prefer `grealpath`/GNU when present, BSD fallback
  (`realpath`, then a `cd`+`pwd -P` loop) otherwise.

The body is updated to call these vars/functions exclusively. Optional runtime
helpers (`gum`/`fzf` picker, `gio`/`trash-put` backends) stay optional and
continue to degrade gracefully when absent.

Outcome: `bin/rm-safe.bash <file>` works on vanilla macOS or Linux, no installs.
(The accessibility gap today is effectively the one `mktemp --tmpdir` call plus
the implicit GNU assumption in tooling; this closes it and makes the g-prefix
preference explicit.)

### 2. `bin/rm-safe` (LuaJIT) — optional fast path

Unchanged in behavior; same flag/UX surface as the bash impl. Used
automatically when luajit (+lfs) is available; never required.

### 3. `bin/rm` shim — accessibility dispatch

Selection order (recursion guards from current shim preserved):
1. `RM_SAFE_BIN` set & executable → use it.
2. else luajit present (`command -v luajit`) and luajit `rm-safe` resolvable → use it (fast).
3. else → `rm-safe.bash` (universal).
4. else → system `rm` fallback (existing behavior).

A non-Nix/non-luajit user automatically gets the bash impl with no config.

When the shim falls back to the bash impl **because luajit was unavailable**
(case 3 reached due to no luajit, not because `RM_SAFE_BIN` forced it), and
`RM_SAFE_QUIET` is not truthy, warn once to stderr:
`rm-safe: note: luajit not found; using slower bash implementation (set
RM_SAFE_QUIET=1 to silence)`. Never warn when the user explicitly selected an
impl via `RM_SAFE_BIN`.

### 4. `RM_SAFE_BIN` selector + run-both harness

- `bin/test/rm-safe_test` honors `RM_SAFE_BIN`: drops a `BIN_DIR/rm-safe`
  symlink (BIN_DIR is already first on `PATH_BASE`) pointing at the selected
  impl, so every `run_cmd` hits it. Unset → default `$REPO_ROOT/bin/rm-safe`
  (luajit), so `rm-safe --test` and current behavior are unchanged.
- `bin/test/run-all` runs the suite across **three lanes**, each pinned via a
  tiny wrapper exec it generates in a temp dir (so `RM_SAFE_BIN` stays the one
  knob): **luajit** (`bin/rm-safe`), **bash-4+** (`<bash4> bin/rm-safe.bash`),
  **bash-3.2** (`<bash3.2> bin/rm-safe.bash`). It detects available runtimes
  (`luajit`, a bash ≥4, a bash 3.2 e.g. `/bin/bash` on macOS) and **skips a lane
  with a logged note** when its runtime is absent (e.g. no 3.2 on Linux CI).
  Prints a per-lane summary, exits non-zero if any run lane fails. Accepts
  narrowing (`--lane luajit|bash4|bash32`) for fast iteration.
- `rm_override_test` runs **once** (it uses a fake `rm-safe`, so it is
  implementation-agnostic) **plus a new test-first case** asserting the shim
  routes to the bash impl when `RM_SAFE_BIN=.../rm-safe.bash`.
- The suite's own scaffolding (currently `mktemp -d --tmpdir`, `awk`, `find`)
  gets a tiny portable-tool resolution at the top so it runs on stock
  macOS/Linux, not only inside Nix.

### 5. `flake.nix` — convenience for Nix users (optional)

- `luajitWithLfs = luajit.withPackages (ps: [ ps.luafilesystem ])` (mirrors the
  nix-darwin fix so lfs resolves without env vars).
- **g-prefix bundle** reproduced from `~/.config/nix/flake.nix`: `coreutils-prefixed`
  + a `gnu-prefixed-tools` runCommand (`gnused`→`gsed`, `gnugrep`→`ggrep`,
  `findutils`→`gfind`) + `gawk`.
- **devShell**: above + `bashInteractive gum fzf expect glib trash-cli`.
- **packages**: `rm-safe` (luajit+lfs; gum/fzf/glib/trash-cli on PATH) and
  `rm-safe-bash` (bash + g-prefix bundle on PATH). Each wrapper sets its own
  `RM_SAFE_BIN`. `packages.default = rm-safe`.
- **checks.tests**: runs `bin/test/run-all` + `rm_override_test` with all deps
  present. Garnix (org-wide) auto-runs it on every push → continuous parity guard.

### 6. README install story

Lead with the zero-dependency path: copy `bin/rm` + `bin/rm-safe.bash` onto
PATH; that is the whole install. Present luajit (speed) and Nix (managed env)
as optional upgrades below it.

## Data flow: tool resolution (bash impl)

```
startup → for each tool: try g-prefix → try verified-GNU plain → BSD
        → set GTOOL var + flavor
        → wrapper funcs branch on flavor for divergent flags
body    → calls only $GTOOL vars and _wrapper functions (platform-blind)
```

## Error handling / degradation

- Missing optional runtime tool (gum/fzf/gio/trash-put): existing graceful
  fallbacks retained (fzf→gum order, internal trash dir, etc.).
- No GNU and no BSD candidate for a *required* tool: fail fast with a clear
  message naming the missing tool (should be unreachable on a real system).
- Shim: if no impl is usable, fall back to system `rm` (current behavior).

## Testing strategy

- Parity is the headline test: `run-all` runs the full suite across **all three
  lanes** (luajit, bash-4+, bash-3.2) every invocation; any divergence fails.
  The bash-3.2 lane is the regression guard for the silent-no-op bug.
- The g-prefix→GNU→BSD resolver is validated implicitly by running the bash
  suite under different toolchains (stock macOS BSD tools; GNU/Linux; nix
  g-prefixed). The Nix `checks.tests` covers the GNU/g-prefixed lane in CI.
- TDD: the shim's `RM_SAFE_BIN` support lands test-first (failing
  `rm_override_test` case → shim code → green). BSD wrapper functions are
  covered by the bash-impl suite run; where a unit is tricky (e.g.
  `_realpath`/`_readlink_f` on a symlink chain), add a focused assertion.

## Known risks

- gum/fzf picker tests drive a pty via `expect`; may be flaky headless in
  Garnix. The suite already skips when gum/fzf are absent; fallback is to drop
  gum/fzf from `checks` deps so only those two skip — undo/restore parity (the
  core) still runs fully.
- Only the operations rm-safe actually uses are normalized (`mktemp -d`,
  `realpath`/`readlink -f`); we do not aim for general GNU↔BSD shims. If future
  edits introduce a divergent flag (`sed -i`, `stat`, `date -d`, `find -printf`),
  add a wrapper at the same seam.

## Out of scope / deferred

- General-purpose GNU↔BSD compatibility beyond the tools rm-safe uses.
- A one-line network installer / package-manager distribution.
- Extracting the resolver into a shared sourced lib (kept inline for
  copy-and-go; revisit only if a third consumer appears).
```
