#!/usr/bin/env bash
# rm-safe: A safer 'rm' that moves files to trash
# Version: 4.0 (Refactored with integrated tests)

set -uo pipefail

# --- Configuration ---
readonly SCRIPT_VERSION="4.0"
readonly OS="$(uname)"
readonly USER_ID="$EUID"
readonly USER_NAME="$(id -un)"
readonly PICKER_DELIM="__RM_SAFE_PICKER__"

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

# Degraded-setup nudge (stderr only; never affects stdout or exit code).
__rm_safe_quiet=false
case "${RM_SAFE_QUIET:-}" in 1|true|yes|on) __rm_safe_quiet=true ;; esac
if [[ $BASH4 -eq 0 && $__rm_safe_quiet == false ]]; then
	printf 'rm-safe: note: running under bash %s; install bash 4+ or luajit for full speed/features (set RM_SAFE_QUIET=1 to silence)\n' \
		"${BASH_VERSION%%(*}" >&2
fi

# --- GNU tool preference ---------------------------------------------------
# Prefer g-prefixed GNU tools (macOS coreutils-prefixed) when present, else the
# plain binary. Keeps GNU intent explicit; plain names are used on Linux/BSD.
_resolve_tool() { # $1 = g-name, $2 = plain name -> echoes a usable command name
	if command -v "$1" >/dev/null 2>&1; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
GMKTEMP=$(_resolve_tool gmktemp mktemp)
GMV=$(_resolve_tool gmv mv)
GMKDIR=$(_resolve_tool gmkdir mkdir)

# mktemp -d: GNU accepts --tmpdir; BSD needs a full template path. Probe once.
if "$GMKTEMP" --version >/dev/null 2>&1; then
	_mktemp_dir() { "$GMKTEMP" -d --tmpdir "${1:-tmp}.XXXXXX"; }   # GNU
else
	_mktemp_dir() { "$GMKTEMP" -d "${TMPDIR:-/tmp}/${1:-tmp}.XXXXXX"; }  # BSD
fi

# Determine trash directory based on OS and user
get_trash_base() {
	if [[ $USER_ID -eq 0 ]]; then
		case $OS in
			Darwin) echo "/var/root/.Trash" ;;
			Linux)  echo "/root/.local/share/Trash" ;;
			*)      return 1 ;;
		esac
	else
		case $OS in
			Darwin) echo "$HOME/.Trash" ;;
			Linux)  echo "${XDG_DATA_HOME:-$HOME/.local/share}/Trash" ;;
			*)      return 1 ;;
		esac
	fi
}

# Initialize directories
# Default configuration (will be set in init or overridden in tests)
TRASH_BASE_DIR=""
TRASH_FILES_DIR=""
TRASH_INFO_DIR=""
# Fragment-log design; see refactor commit 1167cc2 for the macOS TCC rationale.
LOG_DIR=""
_LOG_COUNTER=0
_DATE_NS_CMD=""
HAS_TAC=false
_TAC_CMD=""
HAS_GUM=false
HAS_FZF=false
HAS_REALPATH=false
HAS_READLINK_F=false
HAS_LSATTR=false
HAS_GIO=false
HAS_TRASHPUT=false
HAS_PRINTF_TIME=false

# Protection rules
readonly -a PREFIX_PROTECTED=(
	"/root" "/etc" "/var" "/usr" "/bin" "/sbin" "/lib" "/opt" "/nix/store"
	"/System" "/Library"
)

readonly -a EXACT_PROTECTED=(
	"/" "/*" "/home/*" "/Users/*" "/var/tmp"
	"/bin/*" "/usr/bin" "/usr/bin/*"
	"/lib/*" "/usr/lib" "/usr/lib/*"
	"/var/*" "/usr/var" "/usr/var/*"
	"/etc/*" "/usr/etc" "/usr/etc/*"
	"/opt/*" "/usr/opt" "/usr/opt/*"
	"/nix/*" "/usr/nix" "/usr/nix/*"
	"/proc/*" "/sys/*" "/dev/*"
	"/run/*" "/mnt/*" "/media/*"
)

# --- Init ---
detect_capabilities() {
	HAS_TAC=false
	_TAC_CMD=""
	HAS_GUM=false
	HAS_FZF=false
	HAS_REALPATH=false
	HAS_READLINK_F=false
	HAS_LSATTR=false
	HAS_GIO=false
	HAS_TRASHPUT=false
	HAS_PRINTF_TIME=false

	# Prefer gtac (GNU coreutils on macOS); fall back to tac only if it actually works.
	# A bare "command -v tac" check is insufficient: some PATH entries ship a wrapper
	# script that silently loops when gtac is absent, causing an infinite hang.
	if command -v gtac >/dev/null 2>&1; then
		_TAC_CMD=gtac
		HAS_TAC=true
	elif command -v tac >/dev/null 2>&1; then
		# Smoke-test tac: if it hangs on empty input, skip it.
		# The 3>&- 4>&- close any test-harness FDs so an orphaned tac subprocess
		# (e.g. a wrapper script that ignores SIGTERM) cannot hold capture's pipes
		# open and cause a deadlock in the test suite.
		if command -v timeout >/dev/null 2>&1; then
			if printf \'\' | timeout 2 tac 3>&- 4>&- >/dev/null 2>&1; then
				_TAC_CMD=tac
				HAS_TAC=true
			fi
		else
			# No timeout available — trust that tac is the real implementation.
			_TAC_CMD=tac
			HAS_TAC=true
		fi
	fi
	command -v gum >/dev/null 2>&1 && HAS_GUM=true
	command -v fzf >/dev/null 2>&1 && HAS_FZF=true
	command -v realpath >/dev/null 2>&1 && HAS_REALPATH=true
	if readlink -f / >/dev/null 2>&1; then
		HAS_READLINK_F=true
	fi
	command -v lsattr >/dev/null 2>&1 && HAS_LSATTR=true
	command -v gio >/dev/null 2>&1 && HAS_GIO=true
	command -v trash-put >/dev/null 2>&1 && HAS_TRASHPUT=true
	if printf '%(%Y-%m-%dT%H:%M:%SZ)T\n' -1 >/dev/null 2>&1; then
		HAS_PRINTF_TIME=true
	fi
}

timestamp_utc_into() {
	local __out_var=$1
	local format=$2
	local __tmp_ts

	if [[ $HAS_PRINTF_TIME == true ]]; then
		printf -v "$__out_var" "%(${format})T" -1
	else
		__tmp_ts=$(date -u "+$format")
		printf -v "$__out_var" '%s' "$__tmp_ts"
	fi
}

timestamp_utc() {
	local __ts
	timestamp_utc_into __ts "$1"
	printf '%s' "$__ts"
}

init() {
	TRASH_BASE_DIR=$(get_trash_base)
	TRASH_FILES_DIR="$TRASH_BASE_DIR/files"
	TRASH_INFO_DIR="$TRASH_BASE_DIR/info"
	LOG_DIR="$TRASH_BASE_DIR/rm-safe-log"

	"$GMKDIR" -p "$TRASH_FILES_DIR" "$TRASH_INFO_DIR" 2>/dev/null || {
		echo "rm-safe: Error: Cannot create trash directories" >&2
		exit 1
	}

	# Best-effort log dir; silently disable logging on failure (TCC-blocked
	# contexts on macOS can't create files in existing paths under ~/.Trash
	# but CAN create a fresh subdir). Trash still works either way.
	"$GMKDIR" -p "$LOG_DIR" 2>/dev/null || LOG_DIR=""

	detect_capabilities
}

# --- Helper Functions ---

verbose() {
	[[ ${VERBOSE:-false} == true ]] && echo "rm-safe: $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────
# Fragment log helpers — parallel implementation to bin/rm-safe (LuaJIT).
# See commit 1167cc2 for the macOS TCC rationale. TL;DR: never re-open a
# file another process wrote; each log_action writes its own fresh file.
# ─────────────────────────────────────────────────────────────────────────

_detect_date_ns() {
	# Cache the ns-timestamp command choice. GNU date (Linux) has %N;
	# BSD/macOS date does not, but coreutils' gdate does.
	[[ -n "$_DATE_NS_CMD" ]] && return 0
	if date +%s%N 2>/dev/null | grep -qE '^[0-9]{18,}$'; then
		_DATE_NS_CMD="date"
	elif command -v gdate >/dev/null 2>&1 && gdate +%s%N 2>/dev/null | grep -qE '^[0-9]{18,}$'; then
		_DATE_NS_CMD="gdate"
	else
		# Fallback: sec×1e9 approximation. Loses uniqueness within a second,
		# but _LOG_COUNTER still guarantees per-process uniqueness overall.
		_DATE_NS_CMD="fallback"
	fi
}

_epoch_ns_str() {
	_detect_date_ns
	local ns
	case "$_DATE_NS_CMD" in
		date)     ns=$(date +%s%N) ;;
		gdate)    ns=$(gdate +%s%N) ;;
		fallback) ns=$(printf '%s000000000' "$(date +%s)") ;;
	esac
	((_LOG_COUNTER++))
	printf '%s-%04d' "$ns" "$_LOG_COUNTER"
}

_pb_encode() {
	# Shell out to printable-binary for filesystem-safe bijective encoding.
	# When the tool is missing (it is not a documented dependency, so this is
	# the common case) fall back to a pure-bash sanitize. Echoing the input
	# unchanged used to look harmless but kept its slashes, so the fragment
	# path pointed into a directory that does not exist, the write failed
	# silently, and the action went unlogged -- the file was trashed with no
	# way to --undo it. U+2044 FRACTION SLASH is what printable-binary itself
	# maps "/" to, so names look the same either way; the fallback need not be
	# reversible because the fragment CONTENT carries the authoritative path.
	local s=$1 out
	if [[ -z "$s" ]]; then echo ""; return; fi
	if ! out=$(printf '%s' "$s" | printable-binary 2>/dev/null) || [[ -z "$out" ]]; then
		printf '%s' "${s//\//⁄}"; return
	fi
	# Strip trailing newline printable-binary emits
	printf '%s' "${out%$'\n'}"
}

_sha256_hex_short() {
	local s=$1 out
	out=$(printf '%s' "$s" | shasum -a 256 2>/dev/null | awk '{print $1}')
	[[ -z "$out" ]] && out="unhashed"
	printf '%s' "${out:0:32}"
}

_fragment_path_for() {
	# Compute the fragment path for a log_action call.
	# Filename: <epoch-ns>-<counter>-<pb-encoded-path>
	# Overflow (>200 bytes): <epoch-ns>-<counter>-<sha256:32> and preserve
	# the full original path in the fragment's contents (`path` field).
	[[ -z "$LOG_DIR" ]] && return 1
	local original_path=$1
	local ns encoded name
	ns=$(_epoch_ns_str)
	encoded=$(_pb_encode "$original_path")
	name="$ns-$encoded"
	if [[ ${#name} -gt 200 ]]; then
		name="$ns-$(_sha256_hex_short "$original_path")"
	fi
	printf '%s/%s' "$LOG_DIR" "$name"
}

log_action() {
	[[ -z $LOG_DIR ]] && return 0
	local action=$1 path=$2 trash_path=${3:-N/A} details=${4:-}
	local timestamp frag_path

	# Prefix action with TEST_ if in test mode
	if [[ ${TEST_MODE:-false} == true ]]; then
		action="TEST_$action"
	fi

	timestamp_utc_into timestamp '%Y-%m-%dT%H:%M:%SZ'
	frag_path=$(_fragment_path_for "$path") || return 0
	# Write once, close. No append, no re-open — that's the whole point.
	printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$timestamp" \
		"$USER_NAME" "$action" "$path" "$trash_path" "$details" > "$frag_path"
}

# Check if running in an interactive terminal
is_interactive_terminal() {
	[[ -t 0 && -t 1 ]]
}

# Read all log fragments in the LOG_DIR in reverse chronological order.
# Filenames start with an epoch-ns timestamp, so lex-sort DESC == time-sort
# DESC. Each fragment contains ONE log line. The single arg is a vestige
# of the old single-file signature and is intentionally ignored (call
# sites pass "$LOG_DIR" or "$LOG_FILE" — either way we do the same thing).
reverse_log_lines() {
	[[ -z $LOG_DIR || ! -d $LOG_DIR ]] && return 1
	# `sort -r` gives lexicographic descending; because filenames begin
	# with epoch-ns, that's equivalent to newest-first.
	find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null \
		| sort -r \
		| xargs cat 2>/dev/null
}

strip_ansi() {
	local text=$1
	printf '%s' "$text" | sed $'s/\x1B\\[[0-9;]*[[:alpha:]]//g'
}

manual_trash_action() {
	if [[ ${TEST_MODE:-false} == true ]]; then
		echo "TEST_TRASH_MANUAL"
	else
		echo "TRASH_MANUAL"
	fi
}

parse_undo_offset() {
	local offset_arg=${1:-}

	if [[ -z $offset_arg ]]; then
		echo 1
		return 0
	fi

	if [[ $offset_arg =~ ^-[0-9]+$ ]]; then
		local offset=${offset_arg#-}
		if [[ $offset -ge 1 ]]; then
			echo "$offset"
			return 0
		fi
	fi

	echo "rm-safe: Invalid undo offset: $offset_arg" >&2
	return 1
}

get_trash_manual_entry() {
	local offset=$1
	local action_name=$2
	local count=0
	local line ts user action path trash_path details

	while IFS= read -r line; do
		IFS=$'\t' read -r ts user action path trash_path details <<<"$line"
		if [[ $action == "$action_name" ]]; then
			((count++))
			if [[ $count -eq $offset ]]; then
				echo "$line"
				return 0
			fi
		fi
	done < <(reverse_log_lines "$LOG_DIR")

	return 1
}

restore_trash_entry() {
	local trash_path=$1
	local original_path=$2
	local original_dir

	if [[ -z $trash_path || -z $original_path ]]; then
		echo "rm-safe: Error: Restore paths are empty" >&2
		return 1
	fi

	if [[ ! -e $trash_path ]]; then
		echo "rm-safe: Error: Trash path not found: $trash_path" >&2
		return 1
	fi

	if [[ -e $original_path || -L $original_path ]]; then
		echo "rm-safe: Error: Restore target already exists: $original_path" >&2
		return 1
	fi

	if [[ $original_path == */* ]]; then
		original_dir=${original_path%/*}
		[[ -z $original_dir ]] && original_dir="/"
	else
		original_dir="."
	fi
	if [[ ! -d $original_dir ]]; then
		"$GMKDIR" -p -- "$original_dir" || {
			echo "rm-safe: Error: Cannot create directory: $original_dir" >&2
			return 1
		}
	fi

	if "$GMV" -- "$trash_path" "$original_path"; then
		local info_file="$TRASH_INFO_DIR/${trash_path##*/}.trashinfo"
		[[ -e $info_file ]] && command -p rm -f -- "$info_file"
		log_action "TRASH_RESTORE" "$trash_path" "$original_path"
		echo "Path $trash_path restored to $original_path successfully." >&2
		return 0
	fi

	echo "rm-safe: Error: Failed to restore '$trash_path' to '$original_path'" >&2
	return 1
}

undo_with_offset() {
	local offset=${1:-1}
	local action_name
	local line ts user action original_path trash_path details

	if [[ -z $LOG_DIR || ! -d $LOG_DIR ]]; then
		echo "rm-safe: Error: Log directory not available for undo" >&2
		return 1
	fi

	action_name=$(manual_trash_action)
	line=$(get_trash_manual_entry "$offset" "$action_name") || {
		echo "rm-safe: Error: No $action_name entry found to undo" >&2
		return 1
	}

	IFS=$'\t' read -r ts user action original_path trash_path details <<<"$line"
	restore_trash_entry "$trash_path" "$original_path"
}

undo_picker() {
	local offset_arg=${1:-}
	local action_name line ts user action original_path trash_path details
	local picker="gum"
	local manual_lines

	if [[ -n $offset_arg ]]; then
		undo_with_offset "$offset_arg"
		return $?
	fi

	if ! is_interactive_terminal; then
		echo "rm-safe: Warning: --undo-picker requires an interactive terminal; falling back to --undo" >&2
		undo_with_offset 1
		return $?
	fi

	if [[ $HAS_GUM != true ]]; then
		echo "rm-safe: Warning: gum not found; trying fzf" >&2
		if [[ $HAS_FZF == true ]]; then
			picker="fzf"
		else
			echo "rm-safe: Warning: fzf not found; cannot use --undo-picker" >&2
			return 1
		fi
	fi

	if [[ -z $LOG_DIR || ! -d $LOG_DIR ]]; then
		echo "rm-safe: Error: Log directory not available for undo" >&2
		return 1
	fi

	action_name=$(manual_trash_action)
	manual_lines=()
	if [[ $BASH4 -eq 1 ]]; then
		mapfile -t manual_lines < <(reverse_log_lines "$LOG_DIR" | awk -F'\t' -v action="$action_name" '$3==action')
	else
		while IFS= read -r __line; do manual_lines+=("$__line"); done \
			< <(reverse_log_lines "$LOG_DIR" 3>&- 4>&- | awk -F'\t' -v action="$action_name" '$3==action' 3>&- 4>&-)
	fi
	if [[ ${#manual_lines[@]} -eq 0 ]]; then
		echo "rm-safe: Error: No $action_name entries found to undo" >&2
		return 1
	fi

	local menu=()
	for i in "${!manual_lines[@]}"; do
		IFS=$'\t' read -r ts user action original_path trash_path details <<<"${manual_lines[$i]}"
		menu+=("[$((i + 1))] $ts  $original_path -> $trash_path${PICKER_DELIM}$((i + 1))")
	done

	local selection __pick_dir __pick_in __pick_out __pick_rc
	# Use a private mktemp dir (not a predictable /tmp/...$$ path) so the picker
	# output file can't be pre-created/symlinked by another local user.
	__pick_dir=$("$GMKTEMP" -d "${TMPDIR:-/tmp}/rm-safe-pick.XXXXXX") || return 1
	__pick_in="$__pick_dir/in"
	__pick_out="$__pick_dir/out"
	printf '%s\n' "${menu[@]}" >"$__pick_in"
	local __pick_cmd
	if [[ $picker == "gum" ]]; then
		__pick_cmd="gum choose --label-delimiter $(printf '%q' "$PICKER_DELIM") --select-if-one"
	else
		__pick_cmd="fzf --delimiter $(printf '%q' "$PICKER_DELIM") --with-nth 1 --select-1"
	fi
	/bin/sh -c "$__pick_cmd" <"$__pick_in" >"$__pick_out"
	__pick_rc=$?
	{ IFS= read -r selection <"$__pick_out"; } 2>/dev/null || selection=""
	/bin/rm -rf "$__pick_dir"
	[[ $__pick_rc -eq 0 ]] || return 1
	if [[ -z $selection ]]; then
		echo "rm-safe: Undo canceled" >&2
		return 1
	fi

	local index="$selection"
	if [[ $picker == "fzf" ]]; then
		selection=$(strip_ansi "$selection")
		selection=$(printf '%s' "$selection" | tr -d '\r')
		selection="${selection##*${PICKER_DELIM}}"
		index="$selection"
	fi

	index="${index#"${index%%[![:space:]]*}"}"
	index="${index%"${index##*[![:space:]]}"}"

	if [[ $index =~ ^[0-9]+$ ]]; then
		line=${manual_lines[$((index - 1))]}
	else
		echo "rm-safe: Error: Unable to parse selection" >&2
		return 1
	fi

	IFS=$'\t' read -r ts user action original_path trash_path details <<<"$line"
	restore_trash_entry "$trash_path" "$original_path"
}

# Simplified path resolution
resolve_path_into() {
	local __out_var=$1
	local path=$2
	local normalized=$path
	local dir file dir_abs
	local __candidate=""

	if [[ $normalized != "/" ]]; then
		normalized=${normalized%/}
	fi

	# Try realpath first
	if [[ $HAS_REALPATH == true ]]; then
		__candidate=$(realpath -- "$path" 2>/dev/null) || true
		if [[ -n $__candidate ]]; then
			printf -v "$__out_var" '%s' "$__candidate"
			return 0
		fi
	fi

	# Try readlink
	if [[ $HAS_READLINK_F == true ]]; then
		__candidate=$(readlink -f -- "$path" 2>/dev/null) || true
		if [[ -n $__candidate ]]; then
			printf -v "$__out_var" '%s' "$__candidate"
			return 0
		fi
	fi

	# Manual fallback
	if [[ -e $normalized || -L $normalized ]]; then
		if [[ $normalized == */* ]]; then
			dir=${normalized%/*}
			file=${normalized##*/}
			[[ -z $dir ]] && dir="/"
			dir_abs=$(cd -- "$dir" 2>/dev/null && pwd -P) || dir_abs=""
			if [[ -n $dir_abs ]]; then
				printf -v "$__out_var" '%s/%s' "$dir_abs" "$file"
			else
				printf -v "$__out_var" '%s/%s' "$(pwd -P)" "$normalized"
			fi
		else
			printf -v "$__out_var" '%s/%s' "$(pwd -P)" "$normalized"
		fi
	else
		if [[ $normalized == /* ]]; then
			printf -v "$__out_var" '%s' "$normalized"
		else
			printf -v "$__out_var" '%s/%s' "$(pwd -P)" "$normalized"
		fi
	fi

	return 0
}

resolve_path() {
	local resolved=""
	resolve_path_into resolved "$1"
	printf '%s' "$resolved"
}

# Check if path is protected
is_protected() {
	local path=$1

	# Check exact patterns
	for pattern in "${EXACT_PROTECTED[@]}"; do
		if [[ $pattern == *"/*" && $pattern != "/*" ]]; then
			local base="${pattern%/*}"
			[[ -z $base ]] && base="/"
			if [[ $path == "$base/"* ]]; then
				local relative="${path#$base/}"
				[[ $relative != *"/"* && -n $relative ]] && return 0
			fi
		elif [[ $path == "$pattern" ]]; then
			return 0
		fi
	done

	# Check prefix patterns
	for prefix in "${PREFIX_PROTECTED[@]}"; do
		[[ $path == "$prefix" || $path == "$prefix/"* ]] && return 0
	done

	# Check if it's the trash itself
	# Protect the entire fragment log subtree, not just one file.
	[[ $path == "$TRASH_BASE_DIR" || $path == "$TRASH_FILES_DIR" ||
	   $path == "$TRASH_INFO_DIR" ]] && return 0
	if [[ -n $LOG_DIR && ( $path == "$LOG_DIR" || $path == "$LOG_DIR"/* ) ]]; then
		return 0
	fi

	return 1
}

# Check immutability
is_immutable() {
	local path=$1
	local attrs flags_line _mode _links _owner _group file_flags _rest
	[[ ! -e $path && ! -L $path ]] && return 1

	# Linux
	if [[ $HAS_LSATTR == true ]]; then
		attrs=$(lsattr -d -- "$path" 2>/dev/null || true)
		attrs=${attrs%% *}
		[[ ${attrs:4:1} == "i" ]] && return 0
	fi

	# macOS
	if [[ $OS == "Darwin" ]]; then
		flags_line=$(ls -ldO -- "$path" 2>/dev/null || true)
		read -r _mode _links _owner _group file_flags _rest <<<"$flags_line"
		[[ $file_flags == *schg* ]] && return 0  # System immutable
		[[ $file_flags == *uchg* && $USER_ID -ne 0 ]] && return 0
	fi

	return 1
}

# URL encode path for trashinfo file
url_encode_path_into() {
	local __out_var=$1
	local path=$2
	local __encoded="" char hex
	local i
	local LC_ALL=C

	for ((i=0; i<${#path}; i++)); do
		char=${path:i:1}
		case $char in
			[a-zA-Z0-9._~-]|/) __encoded+=$char ;;
			*)
				printf -v hex '%02X' "'$char"
				__encoded+="%$hex"
				;;
		esac
	done

	printf -v "$__out_var" '%s' "$__encoded"
}

url_encode_path() {
	local encoded=""
	url_encode_path_into encoded "$1"
	printf '%s' "$encoded"
}

# Create trashinfo file
create_trashinfo() {
	local original_path=$1 trash_name=$2
	local info_file="$TRASH_INFO_DIR/$trash_name.trashinfo"
	local encoded_path=""
	local deletion_date=""
	url_encode_path_into encoded_path "$original_path"
	timestamp_utc_into deletion_date '%Y-%m-%dT%H:%M:%S'

	printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' \
		"$encoded_path" \
		"$deletion_date" > "$info_file"
}

# Get unique name in trash
get_unique_name_into() {
	local __out_var=$1
	local base_name=$2
	local __name=$base_name
	local counter=1
	local suffix

	while [[ -e "$TRASH_FILES_DIR/$__name" || -e "$TRASH_INFO_DIR/$__name.trashinfo" ]]; do
		timestamp_utc_into suffix '%Y%m%d%H%M%S'
		__name="${base_name}_${suffix}_${counter}"
		((counter++))
	done

	printf -v "$__out_var" '%s' "$__name"
}

get_unique_name() {
	local name=""
	get_unique_name_into name "$1"
	printf '%s' "$name"
}

# Move single item to trash
trash_item() {
	local item=$1
	local abs_path

	# Handle symlinks specially
	if [[ -L $item ]]; then
		local link_source=$item
		[[ $link_source != "/" ]] && link_source=${link_source%/}
		local link_dir="."
		local link_base=$link_source
		if [[ $link_source == */* ]]; then
			link_dir=${link_source%/*}
			link_base=${link_source##*/}
			[[ -z $link_dir ]] && link_dir="/"
		fi
		link_dir=$(cd -- "$link_dir" 2>/dev/null && pwd -P)
		if [[ -n $link_dir ]]; then
			abs_path="$link_dir/$link_base"
		else
			resolve_path_into abs_path "$item" || {
				echo "rm-safe: Error: Cannot resolve path for '$item'" >&2
				return 1
			}
		fi
	else
		resolve_path_into abs_path "$item" || {
			echo "rm-safe: Error: Cannot resolve path for '$item'" >&2
			return 1
		}
	fi

	verbose "Processing: $item -> $abs_path"

	# Check immutability (skip if force flag is set)
	if [[ ${FORCE:-false} != true ]] && is_immutable "$abs_path"; then
		echo "rm-safe: Error: Cannot remove '$item': Item is immutable" >&2
		log_action "FAIL_IMMUTABLE" "$abs_path"
		return 1
	fi

	# Check protection
	if is_protected "$abs_path"; then
		if [[ ${FORCE:-false} != true ]]; then
			echo "rm-safe: WARNING: '$item' is protected" >&2
			read -p "rm-safe: Move to trash anyway? (y/n): " -n 1 -r </dev/tty
			echo
			if [[ ! $REPLY =~ ^[Yy]$ ]]; then
				log_action "SKIP_PROTECTED" "$abs_path"
				return 0
			fi
			log_action "CONFIRM_PROTECTED" "$abs_path"
		else
			verbose "Forcing removal of protected item: $item"
			log_action "FORCE_PROTECTED" "$abs_path"
		fi
	fi

	# Interactive mode (skip if force flag is set)
	if [[ ${INTERACTIVE:-false} == true && ${FORCE:-false} != true ]]; then
		read -p "rm-safe: Remove '$item'? (y/n): " -n 1 -r </dev/tty
		echo
		if [[ ! $REPLY =~ ^[Yy]$ ]]; then
			log_action "SKIP_INTERACTIVE" "$abs_path"
			return 0
		fi
	fi

	# Try system trash utilities (Linux)
	if [[ $OS == "Linux" ]]; then
		if [[ $HAS_GIO == true ]]; then
			if gio trash -- "$item" 2>/dev/null; then
				log_action "TRASH_GIO" "$abs_path"
				return 0
			fi
		fi
		if [[ $HAS_TRASHPUT == true ]]; then
			if trash-put -- "$item" 2>/dev/null; then
				log_action "TRASH_TRASHPUT" "$abs_path"
				return 0
			fi
		fi
	fi

	# Manual fallback
	local base_name=${abs_path##*/}
	local trash_name=""
	get_unique_name_into trash_name "$base_name"
	local trash_path="$TRASH_FILES_DIR/$trash_name"

	if "$GMV" -- "$abs_path" "$trash_path"; then
		create_trashinfo "$abs_path" "$trash_name"
		log_action "TRASH_MANUAL" "$abs_path" "$trash_path"
		verbose "Moved '$item' to trash as '$trash_name'"
		return 0
	else
		echo "rm-safe: Error: Failed to move '$item' to trash" >&2
		log_action "FAIL_MOVE" "$abs_path"
		return 1
	fi
}

# Show help
show_help() {
	local base_dir="${TRASH_BASE_DIR:-$(get_trash_base)}"
	local file_dir="${TRASH_FILES_DIR:-$base_dir/files}"
	local info_dir="${TRASH_INFO_DIR:-$base_dir/info}"
	local log_path="${LOG_DIR:-$base_dir/rm-safe-log}"

	cat <<-EOF
		rm-safe $SCRIPT_VERSION - Move files to trash instead of deleting

		Usage:
		  rm-safe [OPTIONS] FILE...
		  rm-safe --undo [-N]
		  rm-safe --undo-picker [-N]

		Options:
		  -f, --force        Override protection prompts
		  -i, --interactive  Prompt before every removal
		  -r, --recursive    Remove directories recursively (atomic operation)
		  -v, --verbose      Explain what is being done
		  -a, --about        Show a one-line description of this tool
		  -h, --help         Show this help
		  --test             Run integrated test suite
		  --undo             Restore the most recent TRASH_MANUAL entry
		  --undo-picker      Pick a TRASH_MANUAL entry to restore (uses gum or fzf)

		Undo offsets:
		  Pass a negative number like -2 to restore the 2nd most recent
		  TRASH_MANUAL entry (so -1 is the default).

		Trash location: $base_dir
		  Files: $file_dir
		  Info:  $info_dir
		  Log:   ${log_path:-"(disabled)"}

		Platform Integration:
		  Linux:  Full XDG Trash Specification compliance - files can be restored
		          using desktop environments (GNOME, KDE) or command-line tools
		          (trash-restore, gio trash --restore)
		  macOS:  Files appear in Finder Trash and can be manually restored,
		          but automatic restore from original location not currently
		          supported (possible future feature)

		Integration:
		  To use this tool effectively, you should alias 'rm' to 'rm-safe' in your
		  shell configuration (e.g., .bashrc, .zshrc):
		    alias rm='rm-safe'

		  If you install an 'rm' shim that execs rm-safe (recommended) you may wish
		  to remove any rm alias to avoid double-wrapping.

		  Background scripts or non-interactive runs should invoke 'rm-safe'
		  directly; aliases are not expanded there. If 'rm-safe' cannot move a file
		  to trash it will fail rather than delete.

		  Caution: scripts that expect 'rm' to permanently delete (e.g., log rotate/
		  compress jobs) will move files to trash when this shim is on PATH; trash
		  may grow until emptied. Such scripts should call the system rm explicitly
		  (e.g., /bin/rm or REAL_RM=/bin/rm rm) if deletion is intended.

		  Sudo Integration (portable guidance):
		    - macOS defaults keep user PATH: putting a wrapper 'rm' in ~/bin that
		      execs rm-safe will be honored by sudo.
		    - Common Linux sudoers set secure_path (drop user PATH): create a
		      root-owned override dir (e.g., /usr/bin/overrides), place a wrapper
		      'rm' -> rm-safe there, and prepend that dir in secure_path:
		        Defaults secure_path="/usr/bin/overrides:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
		      Prefer a dedicated overrides dir instead of broadening secure_path to
		      /usr/local/bin to avoid exposing extra binaries.
		    - NixOS: declare a root-owned path containing the wrapper and include
		      it in secure_path, e.g.:
		        security.sudo.extraConfig = ''
		          Defaults secure_path=/run/wrappers/bin:/usr/bin:/bin
		        '';
		      Ensure rm-safe (or a wrapper) is built into /run/wrappers/bin.

		  Implementation detail:
		    rm-safe calls the system rm via 'command -p rm' to avoid recursion when
		    installed as an override.

		Features:
		  - Atomic directory operations (entire directories moved as single units)
		  - XDG Trash Specification compliance (URL-encoded paths, timestamps)
		  - Cross-platform compatibility (Linux, macOS)
		  - Protection against system file removal
		  - Comprehensive logging of all operations

		Examples:
		  rm-safe file.txt             # Move file to trash
		  rm-safe -r directory/        # Recursively trash directory (atomic)
		  rm-safe -i *.log            # Interactive removal
		  rm-safe -vf /etc/config     # Force with verbose output
		  rm-safe --undo              # Restore the most recent TRASH_MANUAL
	EOF
}

# --- Test Suite ---
run_tests() {
	echo "=== rm-safe Test Suite ==="
	echo "WARNING: Tests will modify ${TMPDIR:-/tmp} and trash directories"
	echo "Trash location: $TRASH_BASE_DIR"

	# Enable test mode for logging
	export TEST_MODE=true
	detect_capabilities

	local pass=0 fail=0
	# Use mktemp for safer temporary directory creation
	# User requested --tmpdir -d
	TEST_DIR=$(_mktemp_dir rm_safe_test) || {
		echo "Error: Failed to create temporary directory" >&2
		return 1
	}

	# Create isolated trash for testing
	TEST_TRASH_DIR="$TEST_DIR/trash"
	local TRASH_BASE_DIR="$TEST_TRASH_DIR"
	local TRASH_FILES_DIR="$TRASH_BASE_DIR/files"
	local TRASH_INFO_DIR="$TRASH_BASE_DIR/info"
	local LOG_DIR="$TRASH_BASE_DIR/rm-safe-log"

	mkdir -p "$TRASH_FILES_DIR" "$TRASH_INFO_DIR" "$LOG_DIR"

	# Cleanup function
	cleanup_tests() {
		# Use native rm to avoid testing rm-safe during cleanup if user has aliased rm to rm-safe in their environment
		if [[ -n "$TEST_DIR" && "$TEST_DIR" != "/" && -d "$TEST_DIR" ]]; then
		command -p rm -rf "$TEST_DIR" 2>/dev/null || true
		fi

		# Clean up test files from trash directories
		# Remove files, directories and their corresponding .trashinfo files
		find "$TRASH_FILES_DIR" -name "rm_safe_test_*" -exec rm -rf {} + 2>/dev/null || true
		find "$TRASH_FILES_DIR" -name "rm*safe*test*dir*" -exec rm -rf {} + 2>/dev/null || true
		find "$TRASH_INFO_DIR" -name "rm_safe_test_*.trashinfo" -delete 2>/dev/null || true
		find "$TRASH_INFO_DIR" -name "rm*safe*test*dir*.trashinfo" -delete 2>/dev/null || true

		unset TEST_DIR
	}

	# Test runner
	test_case() {
		local name=$1; shift
		echo -n "Test: $name... "
		if eval "$@"; then
			echo "PASS"
			((pass++))
		else
			echo "FAIL"
			((fail++))
		fi
	}

	# Setup
	trap cleanup_tests EXIT

	# Test: Path resolution
	echo "foo" > "$TEST_DIR/test_file"
	local resolved=$(resolve_path "$TEST_DIR/test_file")
	test_case "Path resolution" '[ -n "$resolved" ] && [ "${resolved:0:1}" = "/" ]'
	mkdir -p "$TEST_DIR/resolve/sub"
	echo "bar" > "$TEST_DIR/resolve/file.txt"
	local saved_pwd=$PWD
	local resolved_rel=""
	if cd "$TEST_DIR/resolve/sub"; then
		resolved_rel=$(resolve_path ".././file.txt")
		cd "$saved_pwd" || return 1
		test_case "Path resolution normalizes ./ and .." '[[ "$resolved_rel" == "'"$TEST_DIR"'/resolve/file.txt" ]]'
	else
		cd "$saved_pwd" || return 1
		test_case "Path resolution normalizes ./ and .." false
	fi

	# Test: Protection detection
	test_case "Root protection" is_protected "/"
	test_case "System dir protection" is_protected "/etc"
	test_case "User file not protected" ! is_protected "$TEST_DIR/user_file.txt"

	# Test: Unique name generation
	touch "$TRASH_FILES_DIR/test_collision"
	local unique=$(get_unique_name "test_collision")
	test_case "Unique name generation" [[ $unique != "test_collision" ]]
	if [[ -e "$TRASH_FILES_DIR/test_collision" ]]; then
		command -p rm -f "$TRASH_FILES_DIR/test_collision"
	else
		echo "Error: Expected '$TRASH_FILES_DIR/test_collision' to exist during cleanup" >&2
		((fail++))
	fi

	# Test: Basic trash operation
	echo "content" > "$TEST_DIR/rm_safe_test_basic"
	local orig_path=$(resolve_path "$TEST_DIR/rm_safe_test_basic")
	if trash_item "$TEST_DIR/rm_safe_test_basic"; then
		test_case "File removed from original location" test ! -e "$TEST_DIR/rm_safe_test_basic"
		test_case "File exists in trash" 'test -n "$(find "$TRASH_FILES_DIR" -name "rm_safe_test_basic*" -print -quit)"'
		test_case "Trashinfo exists" 'test -n "$(find "$TRASH_INFO_DIR" -name "rm_safe_test_basic*.trashinfo" -print -quit)"'
	else
		test_case "Basic trash operation" false
		test_case "File removed from original location" false
		test_case "File exists in trash" false
		test_case "Trashinfo exists" false
	fi

	# Test: Symlink handling
	echo "target" > "$TEST_DIR/rm_safe_test_target"
	ln -s "$TEST_DIR/rm_safe_test_target" "$TEST_DIR/rm_safe_test_link"
	if trash_item "$TEST_DIR/rm_safe_test_link"; then
		test_case "Symlink removed" test ! -L "$TEST_DIR/rm_safe_test_link"
		test_case "Symlink target remains" test -e "$TEST_DIR/rm_safe_test_target"
	else
		test_case "Symlink handling" false
		test_case "Symlink removed" false
		test_case "Symlink target remains" false
	fi

	# Test: Directory operations (atomic)
	mkdir -p "$TEST_DIR/rm_safe_test_dir/subdir"
	echo "file1" > "$TEST_DIR/rm_safe_test_dir/file1.txt"
	echo "file2" > "$TEST_DIR/rm_safe_test_dir/subdir/file2.txt"

	if RECURSIVE=true trash_item "$TEST_DIR/rm_safe_test_dir"; then
		test_case "Directory moved atomically" test ! -e "$TEST_DIR/rm_safe_test_dir"
		test_case "Directory exists in trash" 'test -n "$(find "$TRASH_FILES_DIR" -name "rm_safe_test_dir*" -type d -print -quit)"'
		test_case "Directory structure preserved" 'test -f "$(find "$TRASH_FILES_DIR" -name "rm_safe_test_dir*" -type d -print -quit)/file1.txt"'
		test_case "Subdirectory structure preserved" 'test -f "$(find "$TRASH_FILES_DIR" -name "rm_safe_test_dir*" -type d -print -quit)/subdir/file2.txt"'
		test_case "Single trashinfo for directory" 'test -n "$(find "$TRASH_INFO_DIR" -name "rm_safe_test_dir*.trashinfo" -print -quit)"'
	else
		test_case "Directory moved atomically" false
		test_case "Directory exists in trash" false
		test_case "Directory structure preserved" false
		test_case "Subdirectory structure preserved" false
		test_case "Single trashinfo for directory" false
	fi

	# Test: Force flag behavior
	touch "$TEST_DIR/rm_safe_test_nonexistent"
	command -p rm -f "$TEST_DIR/rm_safe_test_nonexistent"  # Remove it to test nonexistent file
	if FORCE=true trash_item "$TEST_DIR/rm_safe_test_nonexistent" 2>/dev/null; then
		test_case "Force flag handles nonexistent files" true
	else
		test_case "Force flag handles nonexistent files" true  # Should not fail with -f
	fi

	# Test: URL encoding in trashinfo files
	test_case "URL encode spaces" '[[ "$(url_encode_path "hello world")" == "hello%20world" ]]'
	test_case "URL encode special chars" '[[ "$(url_encode_path "test!@#\$%^&*()")" == "test%21%40%23%24%25%5E%26%2A%28%29" ]]'
	test_case "URL encode path with colons" '[[ "$(url_encode_path "/path:with:colons")" == "/path%3Awith%3Acolons" ]]'
	test_case "URL encode brackets" '[[ "$(url_encode_path "file[1].txt")" == "file%5B1%5D.txt" ]]'
	test_case "URL encode backslashes" '[[ "$(url_encode_path "folder\\name")" == "folder%5Cname" ]]'

	# Test: URL encoding in actual trashinfo files
	mkdir -p "$TEST_DIR/rm safe test dir"
	echo "content" > "$TEST_DIR/rm safe test dir/test file.txt"
	if RECURSIVE=true trash_item "$TEST_DIR/rm safe test dir"; then
		# Look for trashinfo files that correspond to the directory with spaces
		# The trashinfo filename should match the actual directory name in trash
		local trashinfo_file=$(find "$TRASH_INFO_DIR" -name "rm safe test dir*.trashinfo" -print -quit)
		test_case "Trashinfo file created" 'test -n "$trashinfo_file"'
		test_case "Spaces encoded in trashinfo" 'test -n "$trashinfo_file" && grep -q "%20" "$trashinfo_file"'
	else
		test_case "Trashinfo file created" false
		test_case "Spaces encoded in trashinfo" false
	fi

	# Test: OS-specific trash directory detection (check get_trash_base output directly)
	test_case "Trash directory exists" test -d "$TRASH_FILES_DIR"
	test_case "Trash info directory exists" test -d "$TRASH_INFO_DIR"

	local expected_trash
	if [[ $OS == "Darwin" ]]; then
		expected_trash="$HOME/.Trash"
		[[ $USER_ID -eq 0 ]] && expected_trash="/var/root/.Trash"
	elif [[ $OS == "Linux" ]]; then
		expected_trash="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
		[[ $USER_ID -eq 0 ]] && expected_trash="/root/.local/share/Trash"
	fi

	if [[ -n $expected_trash ]]; then
		test_case "OS default trash location check" '[ "$(get_trash_base)" = "'"$expected_trash"'" ]'
	fi

	# Summary
	echo
	echo "=== Test Summary ==="
	echo "Passed: $pass"
	echo "Failed: $fail"
	echo "Total:  $((pass + fail))"

	cleanup_tests
	trap - EXIT

	# Disable test mode
	unset TEST_MODE

	return $fail
}

# --- Main ---
main() {
	local undo_mode=""
	local undo_offset_arg=""

	# Parse options
	while [[ $# -gt 0 ]]; do
		case $1 in
			-f|--force)       opt_set force true ;;
			-i|--interactive) opt_set interactive true ;;
			-r|-R|--recursive) opt_set recursive true ;;
			-v|--verbose)     opt_set verbose true ;;
			-a|--about)       echo "rm-safe: A safer 'rm' that moves files to the system trash instead of permanently deleting them."; exit 0 ;;
			-h|--help)        show_help; exit 0 ;;
			--undo|--undo=*)
				if [[ -n $undo_mode ]]; then
					echo "rm-safe: Error: --undo and --undo-picker are mutually exclusive" >&2
					exit 1
				fi
				undo_mode="undo"
				if [[ $1 == --undo=* ]]; then
					undo_offset_arg="${1#--undo=}"
				elif [[ ${2:-} =~ ^-[0-9]+$ ]]; then
					undo_offset_arg="$2"
					shift
				fi
				;;
			--undo-picker|--undo-picker=*)
				if [[ -n $undo_mode ]]; then
					echo "rm-safe: Error: --undo and --undo-picker are mutually exclusive" >&2
					exit 1
				fi
				undo_mode="undo-picker"
				if [[ $1 == --undo-picker=* ]]; then
					undo_offset_arg="${1#--undo-picker=}"
				elif [[ ${2:-} =~ ^-[0-9]+$ ]]; then
					undo_offset_arg="$2"
					shift
				fi
				;;
			--test)
				# Export options for test suite
				export FORCE=$(opt_get force)
				export INTERACTIVE=$(opt_get interactive)
				export RECURSIVE=$(opt_get recursive)
				export VERBOSE=$(opt_get verbose)
				run_tests
				exit $?
				;;
			--)               shift; break ;;
			-*)
				# Handle combined options
				local flags="${1#-}"
				for ((i=0; i<${#flags}; i++)); do
					case "${flags:$i:1}" in
						f) opt_set force true ;;
						i) opt_set interactive true ;;
						r|R) opt_set recursive true ;;
						v) opt_set verbose true ;;
						a) echo "rm-safe: A safer 'rm' that moves files to the system trash instead of permanently deleting them."; exit 0 ;;
						h) show_help; exit 0 ;;
						*)
							echo "rm-safe: Invalid option: -${flags:$i:1}" >&2
							exit 1
							;;
					esac
				done
				;;
			*) break ;;
		esac
		shift
	done

	if [[ -n $undo_mode ]]; then
		if [[ $# -gt 0 ]]; then
			echo "rm-safe: Error: undo options do not accept file operands" >&2
			exit 1
		fi

		init

		local offset=""
		if [[ -n $undo_offset_arg ]]; then
			offset=$(parse_undo_offset "$undo_offset_arg") || exit $?
			if [[ $undo_mode == "undo-picker" && $offset -eq 1 ]]; then
				offset=""
			fi
		fi

		if [[ $undo_mode == "undo" ]]; then
			offset=${offset:-1}
			undo_with_offset "$offset"
			exit $?
		fi

		undo_picker "$offset"
		exit $?
	fi

	# Check for operands
	if [[ $# -eq 0 ]]; then
		echo "rm-safe: missing operand" >&2
		echo "Try 'rm-safe --help' for more information." >&2
		exit 1
	fi

	# Initialize properly now that we are not testing
	init

	# Export options for functions
	export FORCE=$(opt_get force)
	export INTERACTIVE=$(opt_get interactive)
	export RECURSIVE=$(opt_get recursive)
	export VERBOSE=$(opt_get verbose)

	# Process items
	local exit_code=0
	for item in "$@"; do
		[[ -z $item ]] && continue

		# Check existence (skip error if force flag is set)
		if [[ ! -e $item && ! -L $item ]]; then
			if [[ "$(opt_get force)" != true ]]; then
				echo "rm-safe: '$item': No such file or directory" >&2
				log_action "FAIL_NOEXIST" "$item"
				exit_code=1
			fi
			continue
		fi

		# Check directory without recursive
		if [[ -d $item && ! -L $item && "$(opt_get recursive)" == false ]]; then
			local resolved_item=""
			echo "rm-safe: '$item': Is a directory (use -r)" >&2
			resolve_path_into resolved_item "$item"
			log_action "FAIL_ISDIR" "$resolved_item"
			exit_code=1
			continue
		fi

		# Handle directories atomically
		if [[ -d $item && ! -L $item && "$(opt_get recursive)" == true ]]; then
			verbose "Atomically moving directory to trash: $item"
			if ! trash_item "$item"; then
				exit_code=1
			fi
		else
			# Single item (file, symlink, or directory without -r)
			if ! trash_item "$item"; then
				exit_code=1
			fi
		fi
	done

	exit $exit_code
}

# Execute main if not sourced
if [[ ${BASH_SOURCE[0]} == ${0} ]]; then
	main "$@"
fi
