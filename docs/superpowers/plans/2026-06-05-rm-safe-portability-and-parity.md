# rm-safe Portability, Parity & Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rm-safe work for everyone — stock macOS (bash 3.2, BSD tools), Linux (GNU), and luajit users — with a test harness that runs all three implementations/versions so they can't silently drift, plus an optional Nix flake.

**Architecture:** `bin/rm` shim dispatches to the luajit fast path or the universal bash impl, honoring a single `RM_SAFE_BIN` override. `rm-safe.bash` detects bash version into a `BASH4` flag and gates its two bash-4+ constructs with 3.2 fallbacks, prefers g-prefixed GNU tools with a detected-GNU→BSD fallback chain, and warns (suppressibly) on degraded setups. `bin/test/run-all` runs the suite across three lanes (luajit/bash4/bash3.2). `flake.nix` packages it all for Nix users and feeds Garnix parity CI.

**Tech Stack:** Bash (3.2 and 4+), LuaJIT + LuaFileSystem, Nix flakes (nix-darwin-style), expect/gum/fzf for picker tests.

**SCM note:** This repo uses **jj**, not git. All commit steps use `jj commit -m "…"` (snapshots the whole working copy into the current change). Never run raw `git`.

---

## File Structure

- `bin/rm` — **modify**: shim dispatch (RM_SAFE_BIN → luajit → bash → system rm) + suppressible luajit-missing warning.
- `bin/rm-safe.bash` — **modify**: `BASH4` detection, `opt_get`/`opt_set` accessors (gated assoc-array vs scalars), `mapfile` gating, g-prefix tool resolver + `_mktemp_dir`, bash-3.2 warning.
- `bin/rm-safe` — **unchanged** (luajit fast path).
- `bin/test/rm-safe_test` — **modify**: honor `RM_SAFE_BIN` via a `BIN_DIR/rm-safe` symlink; portable temp-dir creation.
- `bin/test/rm_override_test` — **modify**: portable temp-dir; new cases for `RM_SAFE_BIN` override + luajit-missing warning + `RM_SAFE_QUIET`.
- `bin/test/run-all` — **create**: three-lane runner (luajit/bash4/bash3.2) with runtime detection, wrapper generation, `--lane`, skip-with-note, per-lane summary.
- `flake.nix` — **create**: devShell + packages (`rm-safe`, `rm-safe-bash`) + `checks.tests`.
- `README.md` — **modify**: lead with the zero-dependency install path.

---

## Phase 1 — `bin/rm` shim: RM_SAFE_BIN + dispatch + warning

### Task 1: Shim honors `RM_SAFE_BIN` and warns on luajit fallback

**Files:**
- Modify: `bin/rm`
- Test: `bin/test/rm_override_test`

- [ ] **Step 1: Write the failing tests** — append before the `=== Test Summary ===` block in `bin/test/rm_override_test`:

```bash
# Test 4: RM_SAFE_BIN override takes precedence
((tests++))
override_fake="$test_dir/override-impl"
cat >"$override_fake" <<'EOF'
#!/usr/bin/env bash
echo "override invoked" >"$TMPDIR/override-called"
EOF
chmod +x "$override_fake"
TMPDIR="$test_dir" PATH="$test_dir:$PATH_SAFE" RM_SAFE_BIN="$override_fake" "$RM_SHIM" >/dev/null 2>&1
if [[ -f "$test_dir/override-called" ]]; then
	echo "✓ RM_SAFE_BIN override is honored"
else
	echo "✗ RM_SAFE_BIN override not honored" >&2
	((fails++))
fi

# Test 5: luajit absent -> bash impl used + warning; RM_SAFE_QUIET silences it
((tests++))
bash_impl_fake="$test_dir/rm-safe.bash"
cat >"$bash_impl_fake" <<'EOF'
#!/usr/bin/env bash
echo "bash impl invoked" >"$TMPDIR/bash-impl-called"
EOF
chmod +x "$bash_impl_fake"
# Shim resolves its sibling rm-safe.bash relative to its own dir, so point a
# copy of the shim next to the fake bash impl, with NO luajit on PATH.
cp "$RM_SHIM" "$test_dir/rm"
chmod +x "$test_dir/rm"
TMPDIR="$test_dir" PATH="$test_dir/empty:$PATH_SAFE_NO_LUAJIT" "$test_dir/rm" foo >/dev/null 2>"$test_dir/warn.txt"
if [[ -f "$test_dir/bash-impl-called" ]] && grep -q "luajit not found" "$test_dir/warn.txt"; then
	echo "✓ Falls back to bash impl with warning when luajit absent"
else
	echo "✗ bash fallback/warning failed" >&2
	((fails++))
fi
rm -f "$test_dir/bash-impl-called"
TMPDIR="$test_dir" RM_SAFE_QUIET=1 PATH="$test_dir/empty:$PATH_SAFE_NO_LUAJIT" "$test_dir/rm" foo >/dev/null 2>"$test_dir/warn2.txt"
if [[ -f "$test_dir/bash-impl-called" ]] && ! grep -q "luajit not found" "$test_dir/warn2.txt"; then
	echo "✓ RM_SAFE_QUIET suppresses the warning"
else
	echo "✗ RM_SAFE_QUIET did not suppress warning" >&2
	((fails++))
fi
```

Also add, just after the existing `PATH_SAFE=` setup near line 53–54:

```bash
# A PATH that has bash but definitely NOT luajit, for fallback tests.
PATH_SAFE_NO_LUAJIT="$PATH_SAFE"
```

(If `/run/current-system/sw/bin` is on `PATH_SAFE` and contains luajit, strip it: `PATH_SAFE_NO_LUAJIT=$(printf '%s' "$PATH_SAFE" | tr ':' '\n' | grep -v '/run/current-system/sw/bin' | paste -sd: -)`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/test/rm_override_test`
Expected: FAIL — Tests 4 and 5 fail (current shim ignores `RM_SAFE_BIN`, has no bash-impl fallback/warning).

- [ ] **Step 3: Rewrite `bin/rm`** with this content:

```bash
#!/usr/bin/env bash

# rm override shim: routes to the luajit rm-safe (fast) or rm-safe.bash
# (universal), honoring an explicit RM_SAFE_BIN override; falls back to system rm.

REAL_RM=${REAL_RM:-/bin/rm}
SELF_PATH=${BASH_SOURCE[0]:-$0}
HERE=$(cd "$(dirname "$SELF_PATH")" 2>/dev/null && pwd || echo "")

# Warn unless RM_SAFE_QUIET is truthy.
quiet=false
case "${RM_SAFE_QUIET:-}" in 1|true|yes|on) quiet=true ;; esac
warn() { [[ $quiet == true ]] || echo "rm override: $*" >&2; }

# 1. Explicit override wins; never warns (user chose it).
if [[ -n ${RM_SAFE_BIN:-} ]]; then
	if [[ -x $RM_SAFE_BIN ]]; then
		exec "$RM_SAFE_BIN" "$@"
	fi
	echo "rm override: RM_SAFE_BIN=$RM_SAFE_BIN is not executable; ignoring" >&2
fi

# 2. luajit fast path: a real rm-safe on PATH AND a luajit interpreter present.
SAFE_RM=$(command -v rm-safe 2>/dev/null || true)
if [[ -n $SAFE_RM ]] && { [[ $SAFE_RM == "$SELF_PATH" ]] || [[ $SAFE_RM == "$REAL_RM" ]]; }; then
	echo "rm override: detected recursive SAFE_RM; ignoring" >&2
	SAFE_RM=""
fi
if [[ -x $SAFE_RM ]] && command -v luajit >/dev/null 2>&1; then
	exec "$SAFE_RM" "$@"
fi

# 3. Universal bash implementation (sibling of this shim).
BASH_IMPL="$HERE/rm-safe.bash"
if [[ -x $BASH_IMPL ]]; then
	warn "luajit not found; using slower bash implementation (set RM_SAFE_QUIET=1 to silence)"
	exec "$BASH_IMPL" "$@"
fi

# 4. Last resort: system rm.
echo "rm override: rm-safe not found in PATH; using system rm" >&2
if [[ -n $REAL_RM && -x $REAL_RM && $REAL_RM != "$SELF_PATH" ]]; then
	exec "$REAL_RM" "$@"
elif [[ -x /usr/bin/rm ]]; then
	exec /usr/bin/rm "$@"
elif [[ -x /bin/rm ]]; then
	exec /bin/rm "$@"
else
	exec command -p rm "$@"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/test/rm_override_test`
Expected: PASS — all tests including 4 and 5; summary `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat(rm): honor RM_SAFE_BIN, dispatch luajit->bash, warn on luajit fallback"
```

---

## Phase 2 — Test suite honors `RM_SAFE_BIN`; portable temp dirs

### Task 2: `rm-safe_test` selects the impl via `RM_SAFE_BIN`; portable mktemp

**Files:**
- Modify: `bin/test/rm-safe_test`
- Modify: `bin/test/rm_override_test`

- [ ] **Step 1: Write the failing test** — at the top of `bin/test/rm-safe_test`, after the `BIN_DIR="$TEST_DIR/bin"` line area (around line 15–20), add an impl-selection block and a portable temp helper. First add the helper near the top (after `set`/shebang, before `mktemp` on line 9):

```bash
# Portable temp-dir creation (GNU --tmpdir is unavailable on BSD mktemp).
_mk_tmpdir() { # $1 = name prefix
	mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"
}
```

Change line 9 from:

```bash
TEST_DIR=$(mktemp -d --tmpdir rm-safe-test.XXXXXX)
```
to:
```bash
TEST_DIR=$(_mk_tmpdir rm-safe-test)
```

Then, right after `mkdir -p "$HOME_DIR" "$XDG_DIR" "$WORK_DIR" "$BIN_DIR"` (line 20), add:

```bash
# Select the implementation under test. RM_SAFE_BIN (absolute path) wins;
# default is the luajit impl. We expose it as $BIN_DIR/rm-safe, and $BIN_DIR
# is first on PATH_BASE, so every `rm-safe` invocation hits the selected impl.
RM_SAFE_BIN=${RM_SAFE_BIN:-"$REPO_ROOT/bin/rm-safe"}
if [[ ! -x $RM_SAFE_BIN ]]; then
	echo "rm-safe_test: RM_SAFE_BIN=$RM_SAFE_BIN is not executable" >&2
	exit 2
fi
ln -sf -- "$RM_SAFE_BIN" "$BIN_DIR/rm-safe"
```

To prove selection works, add this assertion just before `# Test 1:` (line 138):

```bash
# Test 0: the selected impl is the one being exercised
((tests++))
if [[ "$(readlink "$BIN_DIR/rm-safe")" == "$RM_SAFE_BIN" ]]; then
	echo "OK exercising impl: $RM_SAFE_BIN"
else
	echo "FAIL impl selection wrong" >&2
	((fails++))
fi
```

Also make `rm_override_test` temp creation portable — change line 12 from `mktemp -d --tmpdir rm-override-test.XXXXXX` to:

```bash
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rm-override-test.XXXXXX")
```

- [ ] **Step 2: Run to verify it works against the default (luajit) and an override**

Run: `bin/test/rm-safe_test`
Expected: PASS — Test 0 prints `OK exercising impl: <repo>/bin/rm-safe`; existing tests still pass.

Run: `RM_SAFE_BIN="$PWD/bin/rm-safe.bash" bin/test/rm-safe_test`
Expected: Test 0 prints `OK exercising impl: <repo>/bin/rm-safe.bash`. (Some later tests may currently fail against bash — that is expected and fixed in Phase 4; this step only verifies selection plumbing.)

- [ ] **Step 3: Commit**

```bash
jj commit -m "test: rm-safe_test selects impl via RM_SAFE_BIN; portable temp dirs"
```

---

## Phase 3 — `bin/test/run-all`: three-lane parity runner

### Task 3: Create `bin/test/run-all`

**Files:**
- Create: `bin/test/run-all`

- [ ] **Step 1: Write the runner**

```bash
#!/usr/bin/env bash
# Run the rm-safe test suite across three lanes: luajit, bash-4+, bash-3.2.
# Each lane pins its interpreter via a generated wrapper exec that RM_SAFE_BIN
# points at, so the suite's single RM_SAFE_BIN knob is preserved. Lanes whose
# runtime is unavailable are SKIPPED with a logged note (e.g. no bash-3.2 on
# Linux CI). Exits non-zero if any RUN lane fails.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE="$REPO_ROOT/bin/test/rm-safe_test"
OVERRIDE_SUITE="$REPO_ROOT/bin/test/rm_override_test"
LUAJIT_IMPL="$REPO_ROOT/bin/rm-safe"
BASH_IMPL="$REPO_ROOT/bin/rm-safe.bash"

WANT_LANE="${1:-}"; [[ $WANT_LANE == --lane ]] && WANT_LANE="${2:-}"

WRAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rm-safe-lanes.XXXXXX")
trap '/bin/rm -rf "$WRAP_DIR"' EXIT

# Find a bash whose major version matches $1 (4 means ">=4"). Echo its path or "".
find_bash() {
	local want=$1 c ver major
	for c in /bin/bash /usr/bin/bash /usr/local/bin/bash /opt/homebrew/bin/bash \
	         /run/current-system/sw/bin/bash "$(command -v bash 2>/dev/null)"; do
		[[ -x $c ]] || continue
		ver=$("$c" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
		major=$ver
		if [[ $want == 4 && $major -ge 4 ]]; then echo "$c"; return 0; fi
		if [[ $want == 3 && $major -eq 3 ]]; then echo "$c"; return 0; fi
	done
	echo ""
}

make_wrapper() { # $1 = wrapper path, $2 = interpreter ("" = none), $3 = impl
	local w=$1 interp=$2 impl=$3
	if [[ -n $interp ]]; then
		printf '#!/bin/sh\nexec %q %q "$@"\n' "$interp" "$impl" >"$w"
	else
		printf '#!/bin/sh\nexec %q "$@"\n' "$impl" >"$w"
	fi
	chmod +x "$w"
}

declare -i lanes_run=0 lanes_failed=0

run_lane() { # $1 = lane name, $2 = RM_SAFE_BIN wrapper
	local name=$1 bin=$2
	[[ -n $WANT_LANE && $WANT_LANE != "$name" ]] && return 0
	echo
	echo "########## LANE: $name  ($bin) ##########"
	lanes_run+=1
	if ! RM_SAFE_BIN="$bin" "$SUITE"; then
		lanes_failed+=1
		echo ">>> LANE $name FAILED" >&2
	fi
}

skip_lane() { echo; echo "########## LANE: $1 — SKIPPED ($2) ##########"; }

# luajit lane
if [[ -x $LUAJIT_IMPL ]] && command -v luajit >/dev/null 2>&1 \
	&& luajit -e 'require("lfs")' >/dev/null 2>&1; then
	make_wrapper "$WRAP_DIR/luajit" "" "$LUAJIT_IMPL"
	run_lane luajit "$WRAP_DIR/luajit"
else
	skip_lane luajit "luajit+lfs not available"
fi

# bash-4+ lane
B4=$(find_bash 4)
if [[ -n $B4 ]]; then
	make_wrapper "$WRAP_DIR/bash4" "$B4" "$BASH_IMPL"
	run_lane bash4 "$WRAP_DIR/bash4"
else
	skip_lane bash4 "no bash >= 4 found"
fi

# bash-3.2 lane
B3=$(find_bash 3)
if [[ -n $B3 ]]; then
	make_wrapper "$WRAP_DIR/bash32" "$B3" "$BASH_IMPL"
	run_lane bash32 "$WRAP_DIR/bash32"
else
	skip_lane bash32 "no bash 3.x found (expected on Linux)"
fi

# shim tests run once (implementation-agnostic)
if [[ -z $WANT_LANE ]]; then
	echo; echo "########## rm_override_test (shim) ##########"
	lanes_run+=1
	if ! "$OVERRIDE_SUITE"; then lanes_failed+=1; echo ">>> shim tests FAILED" >&2; fi
fi

echo
echo "==================== run-all summary ===================="
echo "lanes run: $lanes_run   lanes failed: $lanes_failed"
exit $(( lanes_failed > 0 ? 1 : 0 ))
```

- [ ] **Step 2: Make it executable and run it**

Run: `chmod +x bin/test/run-all && bin/test/run-all`
Expected: luajit and bash4 lanes run; the bash32 lane runs on macOS (`/bin/bash`). The **bash32 lane will FAIL right now** (Phase 4 not done) — that is the expected failing state proving the lane exercises the bug. luajit + bash4 lanes should pass.

- [ ] **Step 3: Commit**

```bash
jj commit -m "test: add run-all three-lane parity runner (luajit/bash4/bash3.2)"
```

---

## Phase 4 — `rm-safe.bash`: bash 3.2 compatibility (the real fix)

### Task 4: `BASH4` detection + `opt_get`/`opt_set` accessors

**Files:**
- Modify: `bin/rm-safe.bash`

- [ ] **Step 1: Write the failing test** — confirm the bash32 lane fails on a real removal. Create `bin/test/_bash32_smoke` (temporary scratch check):

Run:
```bash
T=$(mktemp -d "${TMPDIR:-/tmp}/b32.XXXXXX"); echo hi >"$T/victim"; \
env HOME="$T/home" PATH="/usr/bin:/bin" /bin/bash bin/rm-safe.bash "$T/victim"; \
echo "exit=$?"; [[ -e "$T/victim" ]] && echo "BUG: victim NOT trashed" || echo "OK trashed"; \
/bin/rm -rf "$T"
```
Expected: prints `bin/rm-safe.bash: line 953: force: unbound variable` and `BUG: victim NOT trashed`.

- [ ] **Step 2: Add `BASH4` detection + accessors.** In `bin/rm-safe.bash`, immediately after line 12 (`readonly PICKER_DELIM=...`), insert:

```bash
# --- Bash version gating ---------------------------------------------------
# Apple ships /bin/bash 3.2 (no associative arrays). Detect once; keep bash-4+
# features where present, fall back on 3.2.
if [[ ${BASH_VERSINFO[0]} -ge 4 ]]; then
	BASH4=1
else
	BASH4=0
fi

# Option storage, accessed via opt_get/opt_set so the body is version-blind.
if [[ $BASH4 -eq 1 ]]; then
	declare -A __opts=( [force]=false [interactive]=false [recursive]=false [verbose]=false )
	opt_get() { printf '%s' "${__opts[$1]}"; }
	opt_set() { __opts[$1]=$2; }
else
	__opt_force=false; __opt_interactive=false; __opt_recursive=false; __opt_verbose=false
	opt_get() { local __v="__opt_$1"; printf '%s' "${!__v}"; }
	opt_set() { printf -v "__opt_$1" '%s' "$2"; }
fi
```

- [ ] **Step 3: Replace the assoc array in `main()` and all `opts[...]` sites.** In `main()` (line 952), delete:

```bash
	local -A opts=(
		[force]=false
		[interactive]=false
		[recursive]=false
		[verbose]=false
	)
```

(The accessors above already initialize storage.) Then replace every `opts[...]` usage:

| From | To |
|------|----|
| `opts[force]=true` | `opt_set force true` |
| `opts[interactive]=true` | `opt_set interactive true` |
| `opts[recursive]=true` | `opt_set recursive true` |
| `opts[verbose]=true` | `opt_set verbose true` |
| `${opts[force]}` | `$(opt_get force)` |
| `${opts[interactive]}` | `$(opt_get interactive)` |
| `${opts[recursive]}` | `$(opt_get recursive)` |
| `${opts[verbose]}` | `$(opt_get verbose)` |

Specifically the lines to edit are 965–968, 999–1002, 1012–1015, 1067–1070, 1079, 1088, 1098. After editing, the `[[ ... ]]` comparisons read e.g.:

```bash
			if [[ "$(opt_get force)" != true ]]; then
```
```bash
		if [[ -d $item && ! -L $item && "$(opt_get recursive)" == false ]]; then
```
```bash
		if [[ -d $item && ! -L $item && "$(opt_get recursive)" == true ]]; then
```
and the `--test`/exec exports become:
```bash
				export FORCE=$(opt_get force)
				export INTERACTIVE=$(opt_get interactive)
				export RECURSIVE=$(opt_get recursive)
				export VERBOSE=$(opt_get verbose)
```

Verify none remain: `grep -n 'opts\[' bin/rm-safe.bash` must return nothing.

- [ ] **Step 4: Re-run the smoke check from Step 1**

Run: (same command as Step 1)
Expected: `exit=0` and `OK trashed` (file moved to trash, no `unbound variable`).

- [ ] **Step 5: Run the full three-lane suite**

Run: `bin/test/run-all`
Expected: bash32 lane now PASSES the undo/restore tests (mapfile-dependent `--undo` may still fail — fixed next task). Note which tests remain red.

- [ ] **Step 6: Commit**

```bash
jj commit -m "fix(bash): bash 3.2 compat — gate assoc-array via opt_get/opt_set accessors"
```

### Task 5: Gate `mapfile` for bash 3.2

**Files:**
- Modify: `bin/rm-safe.bash:325`

- [ ] **Step 1: Write the failing test** — verify `--undo` works under bash 3.2. After Task 4, run:

```bash
T=$(mktemp -d "${TMPDIR:-/tmp}/b32u.XXXXXX"); echo a >"$T/f"; \
env HOME="$T/home" PATH="/usr/bin:/bin" /bin/bash bin/rm-safe.bash "$T/f"; \
env HOME="$T/home" PATH="/usr/bin:/bin" /bin/bash bin/rm-safe.bash --undo; \
echo "exit=$?"; [[ -e "$T/f" ]] && echo "OK restored" || echo "BUG: not restored"; \
/bin/rm -rf "$T"
```
Expected: FAIL — `mapfile: command not found` (line 325) and `BUG: not restored`.

- [ ] **Step 2: Gate the mapfile call.** Replace line 325:

```bash
	mapfile -t manual_lines < <(reverse_log_lines "$LOG_FILE" | awk -F'\t' -v action="$action_name" '$3==action')
```
with:
```bash
	manual_lines=()
	if [[ $BASH4 -eq 1 ]]; then
		mapfile -t manual_lines < <(reverse_log_lines "$LOG_FILE" | awk -F'\t' -v action="$action_name" '$3==action')
	else
		while IFS= read -r __line; do manual_lines+=("$__line"); done \
			< <(reverse_log_lines "$LOG_FILE" | awk -F'\t' -v action="$action_name" '$3==action')
	fi
```

Ensure `manual_lines` is declared (a `local manual_lines` likely exists earlier in the function; if it is `local manual_lines` keep it, the `manual_lines=()` reset is harmless).

- [ ] **Step 3: Re-run the Step 1 check**

Expected: `exit=0` and `OK restored`.

- [ ] **Step 4: Run the full suite**

Run: `bin/test/run-all`
Expected: all three lanes (luajit, bash4, bash32) PASS; shim tests pass; summary `lanes failed: 0`.

- [ ] **Step 5: Commit**

```bash
jj commit -m "fix(bash): bash 3.2 compat — gate mapfile with read-loop fallback"
```

### Task 6: Suppressible bash-3.2 warning

**Files:**
- Modify: `bin/rm-safe.bash`
- Test: `bin/test/rm-safe_test`

- [ ] **Step 1: Write the failing test** — append before `=== Test Summary ===` in `bin/test/rm-safe_test`:

```bash
# Test 6: bash 3.2 emits a suppressible degraded-setup warning
((tests++))
B32=""
for c in /bin/bash; do v=$("$c" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null); [[ $v == 3 ]] && B32=$c; done
if [[ -z $B32 ]]; then
	skip_test "bash32 warning" "no bash 3.x present"
else
	warn_out=$(env HOME="$HOME_DIR" PATH="$PATH_BASE" "$B32" "$REPO_ROOT/bin/rm-safe.bash" --about 2>&1 >/dev/null)
	quiet_out=$(env HOME="$HOME_DIR" PATH="$PATH_BASE" RM_SAFE_QUIET=1 "$B32" "$REPO_ROOT/bin/rm-safe.bash" --about 2>&1 >/dev/null)
	if printf '%s' "$warn_out" | grep -qi "running under bash" && ! printf '%s' "$quiet_out" | grep -qi "running under bash"; then
		echo "OK bash 3.2 warning emitted and suppressible"
	else
		echo "FAIL bash 3.2 warning behavior wrong" >&2
		((fails++))
	fi
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/test/rm-safe_test`
Expected: FAIL — no warning is emitted yet.

- [ ] **Step 3: Emit the warning.** In `bin/rm-safe.bash`, right after the `BASH4` detection block from Task 4, add:

```bash
# Degraded-setup nudge (stderr only; never affects stdout or exit code).
__rm_safe_quiet=false
case "${RM_SAFE_QUIET:-}" in 1|true|yes|on) __rm_safe_quiet=true ;; esac
if [[ $BASH4 -eq 0 && $__rm_safe_quiet == false ]]; then
	printf 'rm-safe: note: running under bash %s; install bash 4+ or luajit for full speed/features (set RM_SAFE_QUIET=1 to silence)\n' \
		"${BASH_VERSION%%(*}" >&2
fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/test/rm-safe_test`
Expected: PASS — `OK bash 3.2 warning emitted and suppressible`.

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `bin/test/run-all`
Expected: all lanes pass, `lanes failed: 0`.

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat(bash): suppressible bash-3.2 degraded-setup warning (RM_SAFE_QUIET)"
```

---

## Phase 5 — `rm-safe.bash`: g-prefix GNU tool preference

### Task 7: Tool resolver prelude + `_mktemp_dir` wrapper

**Files:**
- Modify: `bin/rm-safe.bash`

- [ ] **Step 1: Write the failing test** — assert the script prefers a g-prefixed tool when present. Append before `=== Test Summary ===` in `bin/test/rm-safe_test`:

```bash
# Test 7: bash impl prefers a g-prefixed tool when available
((tests++))
shimdir="$TEST_DIR/gshim"; mkdir -p "$shimdir"
cat >"$shimdir/gmktemp" <<EOF
#!/usr/bin/env bash
echo "GMKTEMP_USED" >>"$TEST_DIR/gmktemp.trace"
exec mktemp "\$@"
EOF
chmod +x "$shimdir/gmktemp"
env HOME="$HOME_DIR" PATH="$shimdir:$PATH_BASE" "$REPO_ROOT/bin/rm-safe.bash" --test >/dev/null 2>&1 || true
if [[ -f "$TEST_DIR/gmktemp.trace" ]]; then
	echo "OK bash impl used g-prefixed gmktemp when present"
else
	echo "FAIL g-prefixed tool not preferred" >&2
	((fails++))
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/test/rm-safe_test`
Expected: FAIL — current code calls bare `mktemp`, never `gmktemp`.

- [ ] **Step 3: Add the resolver + `_mktemp_dir`.** In `bin/rm-safe.bash`, after the warning block from Task 6, add:

```bash
# --- GNU tool resolution ---------------------------------------------------
# Prefer g-prefixed GNU tools (macOS coreutils-prefixed), else a plain binary
# verified as GNU, else the plain (BSD) binary. Body calls $G* vars so intent
# is explicit and the few flag-divergent ops are centralized in wrappers.
_resolve_tool() { # $1 = g-name, $2 = plain name -> echoes a usable binary
	local g=$1 plain=$2 p
	if p=$(command -v "$g" 2>/dev/null); then printf '%s' "$p"; return; fi
	printf '%s' "$plain"
}
GMKTEMP=$(_resolve_tool gmktemp mktemp)
GREALPATH=$(_resolve_tool grealpath realpath)
GMV=$(_resolve_tool gmv mv)
GMKDIR=$(_resolve_tool gmkdir mkdir)

# mktemp -d: GNU accepts --tmpdir; BSD wants a full template path. Detect by
# probing the resolved binary once.
if "$GMKTEMP" --version >/dev/null 2>&1; then
	_mktemp_dir() { "$GMKTEMP" -d --tmpdir "${1:-tmp}.XXXXXX"; }   # GNU
else
	_mktemp_dir() { "$GMKTEMP" -d "${TMPDIR:-/tmp}/${1:-tmp}.XXXXXX"; }  # BSD
fi
```

- [ ] **Step 4: Route the divergent call site.** Replace the `--test` mktemp (line ~762):

```bash
	TEST_DIR=$(mktemp --tmpdir -d rm_safe_test.XXXXXX) || {
```
with:
```bash
	TEST_DIR=$(_mktemp_dir rm_safe_test) || {
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/test/rm-safe_test`
Expected: PASS — `OK bash impl used g-prefixed gmktemp when present`.

- [ ] **Step 6: Full suite + a BSD-only sanity run**

Run: `bin/test/run-all`
Expected: all lanes pass.

Run: `env PATH="/usr/bin:/bin:$(dirname "$(command -v bash)")" bin/rm-safe.bash --test`
Expected: exit 0 (BSD `_mktemp_dir` branch works with stock coreutils).

- [ ] **Step 7: Commit**

```bash
jj commit -m "feat(bash): prefer g-prefixed GNU tools with GNU/BSD-aware _mktemp_dir"
```

---

## Phase 6 — `flake.nix`: devShell + packages + checks

### Task 8: Create the flake (inputs, luajit+lfs, g-prefix bundle, devShell)

**Files:**
- Create: `flake.nix`

- [ ] **Step 1: Write `flake.nix`**

```nix
{
  description = "rm-safe: a safer rm that moves files to the trash (luajit + portable bash)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        luajitWithLfs = pkgs.luajit.withPackages (ps: [ ps.luafilesystem ]);

        # g-prefixed GNU tools (mirrors ~/.config/nix/flake.nix): coreutils-prefixed
        # gives g* coreutils; this adds gsed/ggrep/gfind/gawk.
        gnuPrefixed = pkgs.runCommand "rm-safe-gnu-prefixed" { } ''
          mkdir -p $out/bin
          ln -s ${pkgs.gnused}/bin/sed     $out/bin/gsed
          ln -s ${pkgs.gnugrep}/bin/grep   $out/bin/ggrep
          ln -s ${pkgs.findutils}/bin/find $out/bin/gfind
          ln -s ${pkgs.gawk}/bin/awk       $out/bin/gawk
        '';

        # Runtime tools both impls may shell out to.
        runtimeDeps = [
          pkgs.coreutils-prefixed gnuPrefixed pkgs.gawk
          pkgs.gum pkgs.fzf pkgs.glib pkgs.trash-cli
        ];

        testDeps = runtimeDeps ++ [ pkgs.bashInteractive pkgs.expect pkgs.coreutils ];
      in {
        devShells.default = pkgs.mkShell {
          packages = [ luajitWithLfs ] ++ testDeps;
          shellHook = ''
            echo "rm-safe dev shell: luajit($(luajit -v 2>&1 | head -1)) + bash $BASH_VERSION"
            echo "run tests: bin/test/run-all"
          '';
        };
      });
}
```

- [ ] **Step 2: Verify the dev shell evaluates and resolves lfs**

Run: `nix develop --command luajit -e 'print(require("lfs") and "lfs OK")'`
Expected: `lfs OK`.

- [ ] **Step 3: Run the suite inside the shell**

Run: `nix develop --command bin/test/run-all`
Expected: luajit + bash4 lanes pass; bash32 lane SKIPPED (nixpkgs has no bash 3.x); `lanes failed: 0`.

- [ ] **Step 4: Commit**

```bash
jj commit -m "feat(nix): add flake with luajit+lfs and g-prefix dev shell"
```

### Task 9: Package both implementations

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Add packages.** Inside the `in { ... }`, alongside `devShells`, add:

```nix
        packages = rec {
          rm-safe = pkgs.stdenv.mkDerivation {
            pname = "rm-safe"; version = "5.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            installPhase = ''
              mkdir -p $out/bin
              cp bin/rm-safe $out/bin/rm-safe-luajit
              cp bin/rm-safe.bash $out/bin/rm-safe.bash
              cp bin/rm $out/bin/rm
              makeWrapper ${luajitWithLfs}/bin/luajit $out/bin/rm-safe \
                --add-flags $out/bin/rm-safe-luajit \
                --prefix PATH : ${lib.makeBinPath runtimeDeps}
              wrapProgram $out/bin/rm-safe.bash \
                --prefix PATH : ${lib.makeBinPath (runtimeDeps ++ [ pkgs.bashInteractive ])}
            '';
          };
          rm-safe-bash = pkgs.stdenv.mkDerivation {
            pname = "rm-safe-bash"; version = "5.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            installPhase = ''
              mkdir -p $out/bin
              cp bin/rm-safe.bash $out/bin/rm-safe-bash-impl
              makeWrapper ${pkgs.bashInteractive}/bin/bash $out/bin/rm-safe-bash \
                --add-flags $out/bin/rm-safe-bash-impl \
                --prefix PATH : ${lib.makeBinPath (runtimeDeps ++ [ pkgs.bashInteractive ])}
            '';
          };
          default = rm-safe;
        };
```

- [ ] **Step 2: Build and run the packaged tools**

Run: `nix build .#rm-safe && ./result/bin/rm-safe --about`
Expected: prints the one-line about text, exit 0.

Run: `T=$(mktemp -d); echo hi >$T/f; HOME=$T ./result/bin/rm-safe.bash $T/f; [[ -e $T/f ]] && echo BUG || echo trashed; rm -rf $T`
Expected: `trashed`.

- [ ] **Step 3: Commit**

```bash
jj commit -m "feat(nix): package rm-safe (luajit) and rm-safe-bash with wrapped PATHs"
```

### Task 10: `checks.tests` for Garnix parity CI

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Add a check.** Alongside `packages`, add:

```nix
        checks.tests = pkgs.runCommand "rm-safe-tests"
          { nativeBuildInputs = testDeps ++ [ luajitWithLfs ]; }
          ''
            cp -r ${./.} src && chmod -R u+w src && cd src
            export HOME=$TMPDIR
            bin/test/run-all
            touch $out
          '';
```

- [ ] **Step 2: Verify the check builds**

Run: `nix flake check 2>&1 | tail -20`
Expected: completes without error (the luajit + bash4 lanes run in-sandbox; bash32 lane skips). If gum/fzf picker tests prove flaky headless, see Known Risks in the spec — drop `pkgs.gum pkgs.fzf` from `testDeps` so those two tests skip.

- [ ] **Step 3: Commit**

```bash
jj commit -m "feat(nix): checks.tests runs three-lane parity suite (Garnix CI)"
```

---

## Phase 7 — README: lead with the zero-dependency path

### Task 11: Rewrite the install section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README install/usage sections**

Run: `sed -n '1,60p' README.md`

- [ ] **Step 2: Insert a "Quick install (no dependencies)" section** near the top, before any Nix/luajit instructions:

```markdown
## Quick install (no dependencies)

rm-safe runs on a stock macOS or Linux box with nothing to install:

```sh
git clone <repo> rm-safe
# put the shim + universal bash implementation on your PATH
ln -s "$PWD/rm-safe/bin/rm"          ~/.local/bin/rm
ln -s "$PWD/rm-safe/bin/rm-safe.bash" ~/.local/bin/rm-safe.bash
```

That's the whole install. `rm` now moves files to the trash instead of deleting
them. It works on the bash that ships with macOS (3.2) and on Linux.

### Optional upgrades

- **Speed:** install **luajit** (with LuaFileSystem) and the shim automatically
  uses the faster `bin/rm-safe`. Without luajit you'll see a one-time note
  (silence it with `RM_SAFE_QUIET=1`).
- **Nix:** `nix develop` for a managed dev/test environment, or
  `nix build .#rm-safe` / `.#rm-safe-bash` for packaged builds.

### Choosing an implementation

Set `RM_SAFE_BIN=/path/to/rm-safe.bash` (or the luajit `rm-safe`) to force a
specific implementation for both `rm` and the tests.
```

- [ ] **Step 3: Verify the doc renders and links are right**

Run: `grep -n "RM_SAFE_BIN\|RM_SAFE_QUIET\|Quick install" README.md`
Expected: the new section and env-var references are present.

- [ ] **Step 4: Commit**

```bash
jj commit -m "docs: README leads with zero-dependency install; luajit/Nix optional"
```

---

## Final verification

- [ ] Run the whole matrix locally on macOS: `bin/test/run-all` → all three lanes pass.
- [ ] Run inside Nix: `nix develop --command bin/test/run-all` and `nix flake check` → pass (bash32 lane skips).
- [ ] Sanity: `grep -n 'opts\[' bin/rm-safe.bash` returns nothing; `grep -n 'mapfile' bin/rm-safe.bash` shows only the gated branch.
- [ ] Confirm a stock removal works under bash 3.2: file is trashed, exit 0, with the degraded-setup note on stderr.
```
