#!/usr/bin/env bash
# setup-multi-claude.sh - run two or more Claude Code accounts side by side on one Linux box.
#
#   claude ...          -> main account   config ~/.claude        state ~/.claude.json
#   claude alt ...      -> "alt" account  config ~/.claude-alt    state ~/.claude-alt/.claude.json
#   claude <name> ...   -> any profile listed in ~/.claude-shared/profiles
#   clauded [name] ...  -> same, with --dangerously-skip-permissions
#
# How: a shell function named `claude` consumes the first argument that matches a
# registered profile name and runs the real binary with CLAUDE_CONFIG_DIR pointing at
# that profile's directory. Every profile directory symlinks CLAUDE.md, settings.json,
# hooks/, commands/, rules/, skills/ and agents/ into ~/.claude-shared, so instructions,
# permissions and hooks are written once. Credentials, sessions, project memory and
# plugins stay per account.
#
# Sessions talk across accounts: every profile uses one peer-session registry, so Claude
# Code sessions of different accounts list and message each other (ListAgents /
# SendMessage) exactly like sessions of one account do. On by default; opt out with
# `install --no-share-sessions` or `multi-claude unshare-sessions`. `doctor` reports the mode.
#
# Idempotent: `install` can be re-run at any time. Nothing is deleted; anything that
# has to move out of the way is renamed to <name>.bak-<timestamp>.
#
# Get it without a clone through install.sh, or run `./setup-multi-claude.sh install` from a
# clone. Either way the script ends up as `multi-claude` in ~/.local/bin (`claude-profiles`,
# its name before 1.1, keeps working where it was installed). `multi-claude update` fetches
# the latest version and re-applies it; `multi-claude help` lists every command.
set -euo pipefail

VERSION="1.1.0"
INSTALLER_URL="${CLAUDE_INSTALLER_URL:-https://claude.ai/install.sh}"

# Where `update` downloads this script from when it was not installed from a clone.
# Point MULTI_CLAUDE_REPO at a fork, or MULTI_CLAUDE_RAW_URL at any base URL serving the files.
REPO_SLUG="${MULTI_CLAUDE_REPO:-robinsound/multi-claude}"
REPO_REF="${MULTI_CLAUDE_REF:-master}"
RAW_URL="${MULTI_CLAUDE_RAW_URL:-https://raw.githubusercontent.com/$REPO_SLUG/$REPO_REF}"
SCRIPT_NAME="setup-multi-claude.sh"

# Everything is derived from $HOME. Tests point HOME at a sandbox; never hardcode a user.
SHARED_DIR="$HOME/.claude-shared"
MAIN_DIR="$HOME/.claude"
BIN_DIR="$HOME/.local/bin"
WRAPPER_FILE="$SHARED_DIR/claude-profiles.sh"
REGISTRY_FILE="$SHARED_DIR/profiles"
SHARED_SESSIONS="$SHARED_DIR/sessions"   # the one peer-session registry; absent when every account keeps its own
STATE_FILE="$SHARED_DIR/multi-claude.conf"   # host state: where updates come from, the session-sharing opt-out
SELF_NAME="multi-claude"
LEGACY_NAME="claude-profiles"            # this command's name before 1.1

SHARED_FILES="CLAUDE.md settings.json"
SHARED_DIRS="hooks commands rules skills agents"
SHARED_OPTIONAL_FILES="claude-powerline.json"
RESERVED_NAMES="main shared"

MARK_BEGIN="# >>> multi-claude >>>"
MARK_END="# <<< multi-claude <<<"

DRY_RUN=0
NO_INSTALL=0
UPGRADE=0
CLAUDE_VERSION=""
SHELL_CHOICE="auto"
BUNDLE=""
SHARE_SESSIONS=""   # "" = share unless this host opted out; 1 = --share-sessions; 0 = --no-share-sessions
PROFILES=""         # --profiles; without it: alt on a fresh host, nothing new on a configured one
PROFILES_SET=0
TS="$(date +%Y%m%d-%H%M%S)"
FAILS=0
WARNS=0

# ------------------------------------------------------------------ output helpers ----
c_reset=$'\033[0m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_fail=$'\033[31m'; c_dim=$'\033[2m'
if [ ! -t 1 ]; then c_reset=""; c_ok=""; c_warn=""; c_fail=""; c_dim=""; fi

log()  { printf '%s\n' "$*"; }
ok()   { printf '%s  ok  %s%s\n' "$c_ok" "$c_reset" "$*"; }
warn() { WARNS=$((WARNS + 1)); printf '%s warn %s%s\n' "$c_warn" "$c_reset" "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '%s FAIL %s%s\n' "$c_fail" "$c_reset" "$*"; }
die()  { printf '%serror:%s %s\n' "$c_fail" "$c_reset" "$*" >&2; exit 1; }
tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; "$HOME") printf '~' ;; *) printf '%s' "$1" ;; esac; }

# run CMD... : execute, or only print when --dry-run
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s %s\n' "$c_dim" "$c_reset" "$*"
  else
    "$@"
  fi
}
# write_file PATH CONTENT : create a file (dry-run aware)
write_file() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s write %s\n' "$c_dim" "$c_reset" "$1"
  else
    printf '%s\n' "$2" > "$1"
  fi
}

# ------------------------------------------------------------------ host state --------
# KEY=VALUE lines in ~/.claude-shared/multi-claude.conf. It records facts about this host
# only (where updates come from, an opt-out of session sharing), so a bundle never carries it.
state_get() {
  [ -r "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | tail -1
}
state_set() {   # state_set KEY VALUE ; an empty VALUE removes the key
  local key="$1" val="$2" tmp
  [ "$(state_get "$key")" != "$val" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s record %s=%s in %s\n' "$c_dim" "$c_reset" "$key" "$val" "$(tilde "$STATE_FILE")"; return 0
  fi
  tmp="$(mktemp)"
  {
    if [ -f "$STATE_FILE" ]; then grep -v "^$key=" "$STATE_FILE" || true
    else printf '# multi-claude state of this host. Managed by %s; never part of an exported bundle.\n' "$SELF_NAME"; fi
    if [ -n "$val" ]; then printf '%s=%s\n' "$key" "$val"; fi
  } > "$tmp"
  cat "$tmp" > "$STATE_FILE"; rm -f "$tmp"
}

# self_path : absolute path of this script file; nothing when bash reads it from a pipe
self_path() {
  case "$0" in bash|sh|-bash|-sh|*/bash|*/sh) return 0 ;; esac
  readlink -f "$0" 2>/dev/null || true
}
# clone_of FILE : the git clone FILE sits at the top of. Fails for a plain file (the
# installed copy, a download), which is what decides how `update` fetches a new version.
clone_of() {
  local d
  [ -n "${1:-}" ] || return 1
  d="$(dirname "$1")"
  [ -e "$d/.git" ] || return 1
  [ -f "$d/$SCRIPT_NAME" ] || return 1
  printf '%s' "$d"
}

# ------------------------------------------------------------------ profile helpers ---
validate_name() {
  local n="$1"
  case "$n" in
    ''|*[!a-z0-9_-]*|-*) die "invalid profile name '$n' (use lowercase letters, digits, - and _; must start with a letter or digit)" ;;
  esac
  for r in $RESERVED_NAMES; do
    [ "$n" = "$r" ] && die "'$n' is reserved"
  done
  return 0
}
profile_dir() {   # main -> ~/.claude ; name -> ~/.claude-<name>
  if [ "$1" = main ]; then printf '%s' "$MAIN_DIR"; else printf '%s/.claude-%s' "$HOME" "$1"; fi
}
profile_state_file() {   # the ~/.claude.json equivalent for a profile
  if [ "$1" = main ]; then printf '%s/.claude.json' "$HOME"; else printf '%s/.claude.json' "$(profile_dir "$1")"; fi
}
invoke_hint() { if [ "$1" = main ]; then printf 'claude'; else printf 'claude %s' "$1"; fi; }
list_profiles() {   # registered profiles, one per line (main is implicit and not listed)
  [ -r "$REGISTRY_FILE" ] || return 0
  grep -v '^[[:space:]]*\(#\|$\)' "$REGISTRY_FILE" || true
}
is_registered() { list_profiles | grep -qx -- "$1"; }
ensure_registered() {
  if is_registered "$1"; then ok "profile '$1' already registered in $(tilde "$REGISTRY_FILE")"; return; fi
  if [ ! -e "$REGISTRY_FILE" ]; then
    write_file "$REGISTRY_FILE" "# Claude Code account profiles, one per line. 'main' (~/.claude) is implicit.
# Managed by multi-claude (install / add-profile). Read by the claude() wrapper on every call."
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s register profile %s\n' "$c_dim" "$c_reset" "$1"
  else
    printf '%s\n' "$1" >> "$REGISTRY_FILE"
  fi
  ok "registered profile '$1' (config dir $(tilde "$(profile_dir "$1")"))"
}
# run the real claude binary as a given profile (bounded to 30s; used by status)
claude_as() {
  local p="$1"; shift
  local -a t=()
  command -v timeout >/dev/null 2>&1 && t=(timeout 30)
  if [ "$p" = main ]; then
    "${t[@]}" env -u CLAUDE_CONFIG_DIR claude "$@"
  else
    "${t[@]}" env CLAUDE_CONFIG_DIR="$(profile_dir "$p")" claude "$@"
  fi
}

# json_field JSON KEY : print a top-level JSON field (python3 preferred, jq fallback)
json_field() {
  local json="$1" key="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); v=d.get(sys.argv[1],"")
    print("" if v is None else (str(v).lower() if isinstance(v,bool) else v))
except Exception:
    print("")' "$key"
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // "" | tostring' 2>/dev/null || true
  else
    printf ''
  fi
}
json_valid() {
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then jq -e . "$1" >/dev/null 2>&1
  else return 0; fi
}

# ------------------------------------------------------------------ shared symlinks ---
same_content() {
  if [ -d "$1" ] && [ -d "$2" ]; then diff -rq "$1" "$2" >/dev/null 2>&1
  elif [ -f "$1" ] && [ -f "$2" ]; then cmp -s "$1" "$2"
  else return 1; fi
}

# link_shared_item PROFILE_DIR ITEM KIND   (KIND: file | dir | optional-file)
link_shared_item() {
  local pdir="$1" item="$2" kind="$3"
  local src="$SHARED_DIR/$item" dst="$pdir/$item" adopted=0
  if [ "$kind" = optional-file ] && [ ! -e "$src" ]; then return 0; fi

  if [ -L "$dst" ]; then
    if [ "$(readlink "$dst")" = "$src" ]; then ok "$(tilde "$dst") -> $(tilde "$src")"; return 0; fi
    warn "$(tilde "$dst") pointed to $(readlink "$dst"); re-pointing it to $(tilde "$src")"
    run rm -- "$dst"
  elif [ -e "$dst" ]; then
    if [ ! -e "$src" ]; then
      log "  adopting existing $(tilde "$dst") as the shared copy"
      run mv -- "$dst" "$src"; adopted=1
    elif same_content "$dst" "$src"; then
      log "  $(tilde "$dst") is identical to the shared copy; replacing it with a symlink"
      run rm -r -- "$dst"
    else
      warn "$(tilde "$dst") differs from $(tilde "$src"); kept as $(tilde "$dst").bak-$TS -- merge it by hand"
      run mv -- "$dst" "$dst.bak-$TS"
    fi
  fi

  if [ ! -e "$src" ] && [ "$adopted" -eq 0 ]; then
    case "$kind" in
      dir) run mkdir -p -- "$src" ;;
      *)   if [ "$item" = settings.json ]; then write_file "$src" '{}'; else run touch -- "$src"; fi ;;
    esac
  fi
  run ln -s -- "$src" "$dst"
  ok "$(tilde "$dst") -> $(tilde "$src")"
}

link_profile_dir() {   # create a profile dir and wire every shared item into it
  local pdir="$1" item
  run mkdir -p -- "$pdir"
  for item in $SHARED_FILES; do link_shared_item "$pdir" "$item" file; done
  for item in $SHARED_DIRS; do link_shared_item "$pdir" "$item" dir; done
  for item in $SHARED_OPTIONAL_FILES; do link_shared_item "$pdir" "$item" optional-file; done
}

# ------------------------------------------------------------------ peer-session registry
# Claude Code registers every running session in <config dir>/sessions/<pid>.json (+ a
# <pid>.<hash>.key peer token, mode 0600) and discovers peers by reading that directory.
# The message transport, a per-process unix socket under /run/user/<uid>/cc-socks, is
# already shared by every profile of one OS user. Pointing every profile's sessions/ at
# one shared directory therefore makes sessions of all accounts see and message each other.
#
# That is the default. A host leaves it only through an explicit opt-out, which is written
# to the state file so that a later `install` or `update` does not switch sharing back on.
sessions_shared() { [ -d "$SHARED_SESSIONS" ] && [ ! -L "$SHARED_SESSIONS" ]; }
sessions_opted_out() { [ "$(state_get sessions)" = per-account ]; }

# session_owner_dir PID : config dir of the account a running session belongs to, read from
# the process environment (CLAUDE_CONFIG_DIR, or ~/.claude when unset). Fails when the
# process is gone or is not ours.
session_owner_dir() {
  local env="/proc/$1/environ" cfg
  [ -r "$env" ] || return 1
  cfg="$(tr '\0' '\n' < "$env" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -1)"
  cfg="${cfg%/}"
  printf '%s' "${cfg:-$MAIN_DIR}"
}

ensure_shared_sessions_dir() {
  if [ -d "$SHARED_SESSIONS" ]; then
    [ "$(stat -c %a "$SHARED_SESSIONS" 2>/dev/null)" = 700 ] || run chmod 0700 -- "$SHARED_SESSIONS"
    ok "shared registry $(tilde "$SHARED_SESSIONS")"
  else
    run mkdir -p -m 0700 -- "$SHARED_SESSIONS"
    ok "created shared registry $(tilde "$SHARED_SESSIONS") (mode 0700)"
  fi
}

# share_sessions_dir PROFILE_DIR : replace PROFILE_DIR/sessions with a symlink to the shared
# registry. Entries of running sessions are moved, not copied: a session keeps writing to
# the same relative path, which now resolves inside the shared directory, so nothing has to
# be restarted. An entry that already exists in the shared registry is never overwritten.
share_sessions_dir() {
  local pdir="$1" f n=0 kept=0
  local src="$SHARED_SESSIONS" dst="$1/sessions"
  if [ -L "$dst" ]; then
    if [ "$(readlink "$dst")" = "$src" ]; then ok "$(tilde "$dst") -> $(tilde "$src")"; return 0; fi
    warn "$(tilde "$dst") pointed to $(readlink "$dst"); re-pointing it to $(tilde "$src")"
    run rm -- "$dst"
  elif [ -d "$dst" ]; then
    for f in "$dst"/* "$dst"/.[!.]*; do
      [ -e "$f" ] || continue
      if [ -e "$src/$(basename "$f")" ]; then kept=$((kept + 1)); continue; fi
      run mv -- "$f" "$src/"; n=$((n + 1))
    done
    [ "$n" -gt 0 ] && log "  moved $n registry file(s) from $(tilde "$dst") into $(tilde "$src")"
    if [ "$kept" -gt 0 ]; then
      warn "$kept file(s) in $(tilde "$dst") already exist in the shared registry; kept as $(tilde "$dst").bak-$TS (stale entries of exited sessions, most likely)"
      run mv -- "$dst" "$dst.bak-$TS"
    else
      run rmdir -- "$dst"
    fi
  elif [ -e "$dst" ]; then
    warn "$(tilde "$dst") is not a directory; kept as $(tilde "$dst").bak-$TS"
    run mv -- "$dst" "$dst.bak-$TS"
  fi
  run ln -s -- "$src" "$dst"
  ok "$(tilde "$dst") -> $(tilde "$src")"
}

# ~/.claude-<name> dirs that hold an account but were never registered (hand-made setups
# from before this script). They are skipped by everything registry-driven, so say so.
unregistered_profile_dirs() {
  local d n
  for d in "$HOME"/.claude-*/; do
    d="${d%/}"; n="${d##*/.claude-}"
    { [ -d "$d" ] && [ ! -L "$d" ]; } || continue
    case "$n" in shared|*.bak-*) continue ;; esac
    [ -f "$d/.claude.json" ] || [ -f "$d/.credentials.json" ] || [ -d "$d/sessions" ] || continue
    is_registered "$n" || printf '%s\n' "$n"
  done
}
warn_unregistered_profiles() {
  local p
  for p in $(unregistered_profile_dirs); do
    warn "$(tilde "$(profile_dir "$p")") holds an account but is not a registered profile, so it is skipped; register it first: $SELF_NAME add-profile $p"
  done
}

# every profile dir that should carry the shared registry: main, the registered ones, and
# (during install) the ones being created now
session_profile_dirs() {
  local p
  # shellcheck disable=SC2086  # $1 is a space-separated list of names; splitting is intended
  { printf 'main\n'; list_profiles; printf '%s\n' ${1:-}; } | sort -u | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$(profile_dir "$p")" ] || [ "$DRY_RUN" -eq 1 ]; then profile_dir "$p"; printf '\n'; fi
  done
}

# ------------------------------------------------------------------ bundle seeding ----
seed_bundle() {
  local bundle="$1" listing src_home
  [ -f "$bundle" ] || die "bundle not found: $bundle"
  listing="$(tar -tzf "$bundle")" || die "cannot read bundle $bundle"
  if printf '%s\n' "$listing" | grep -qE '(^|/)(\.credentials\.json|\.claude\.json)$|(^|/)sessions[^/]*/[^/]+\.key$'; then
    die "refusing bundle $bundle: it contains credential/state files"
  fi
  if printf '%s\n' "$listing" | grep -qE '^/|(^|/)\.\.(/|$)'; then
    die "refusing bundle $bundle: absolute or parent paths inside the archive"
  fi
  if [ -d "$SHARED_DIR" ] && [ -n "$(ls -A "$SHARED_DIR" 2>/dev/null)" ]; then
    warn "$(tilde "$SHARED_DIR") is not empty; keeping a copy at $(tilde "$SHARED_DIR").bak-$TS before extracting the bundle over it"
    run cp -a -- "$SHARED_DIR" "$SHARED_DIR.bak-$TS"
    # the copy is a backup of the configuration; it must not duplicate live peer tokens
    if [ -d "$SHARED_DIR.bak-$TS/sessions" ]; then run rm -rf -- "$SHARED_DIR.bak-$TS/sessions"; fi
  fi
  run mkdir -p -- "$SHARED_DIR"
  log "  extracting $(tilde "$bundle") into $(tilde "$SHARED_DIR")"
  run tar -xzf "$bundle" --exclude='./multi-claude.conf' -C "$SHARED_DIR"
  [ "$DRY_RUN" -eq 1 ] && return 0

  src_home=""
  if [ -f "$SHARED_DIR/.bundle-meta" ]; then
    src_home="$(sed -n 's/^SOURCE_HOME=//p' "$SHARED_DIR/.bundle-meta" | head -1)"
  fi
  if [ -n "$src_home" ] && [ "$src_home" != "$HOME" ]; then
    rewrite_home "$src_home" "$HOME"
  fi
  ok "shared config seeded from bundle"
}

# rewrite_home FROM TO : the bundle came from another $HOME; fix absolute paths in text
# files and symlink targets inside the shared dir so hooks/settings keep working here.
rewrite_home() {
  local from="$1" to="$2" n=0 f target
  local from_re to_re
  from_re="$(printf '%s' "$from" | sed 's/[][\.*^$/]/\\&/g')"
  to_re="$(printf '%s' "$to" | sed 's/[&/\]/\\&/g')"
  while IFS= read -r -d '' f; do
    if grep -Iq -- "$from" "$f" 2>/dev/null; then
      sed -i "s/$from_re/$to_re/g" "$f"; n=$((n + 1))
    fi
  done < <(find "$SHARED_DIR" -type f ! -path '*/__pycache__/*' ! -name '*.md' -print0)
  while IFS= read -r -d '' f; do
    target="$(readlink "$f")"
    case "$target" in
      "$from"/*) ln -sfn -- "$to${target#"$from"}" "$f"; n=$((n + 1)) ;;
    esac
  done < <(find "$SHARED_DIR" -type l -print0)
  log "  rewrote $from -> $to in $n file(s)/symlink(s) (Markdown left untouched; doctor lists what still mentions the old home)"
}

# ------------------------------------------------------------------ claude install ----
install_claude() {
  if [ "$UPGRADE" -eq 0 ]; then
    if command -v claude >/dev/null 2>&1; then
      ok "claude already installed: $(claude --version 2>/dev/null | head -1) ($(command -v claude))"; return 0
    fi
    if [ -x "$BIN_DIR/claude" ]; then
      ok "found $(tilde "$BIN_DIR/claude") (not on PATH in this shell yet)"; export PATH="$BIN_DIR:$PATH"; return 0
    fi
  fi
  command -v curl >/dev/null 2>&1 || { fail "curl is required to download the Claude Code installer (apt-get install -y curl)"; return 1; }
  log "  downloading the Claude Code native installer from $INSTALLER_URL${CLAUDE_VERSION:+ (version: $CLAUDE_VERSION)}"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s curl -fsSL %s | bash -s %s\n' "$c_dim" "$c_reset" "$INSTALLER_URL" "${CLAUDE_VERSION:-latest}"; return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$INSTALLER_URL" -o "$tmp/install.sh" || { rm -rf "$tmp"; fail "download failed"; return 1; }
  if [ -n "$CLAUDE_VERSION" ]; then bash "$tmp/install.sh" "$CLAUDE_VERSION"; else bash "$tmp/install.sh"; fi
  rm -rf "$tmp"
  export PATH="$BIN_DIR:$PATH"
  command -v claude >/dev/null 2>&1 || { fail "claude is still not on PATH after the installer ran; check the installer output"; return 1; }
  ok "installed $(claude --version 2>/dev/null | head -1)"
}

# ------------------------------------------------------------------ shell wrapper -----
write_wrapper() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s write %s\n' "$c_dim" "$c_reset" "$(tilde "$WRAPPER_FILE")"; return 0
  fi
  cat > "$WRAPPER_FILE" <<'EOF'
# claude-profiles.sh - generated by multi-claude (setup-multi-claude.sh). Re-run
# `multi-claude install` to regenerate; do not edit by hand. Works when sourced from bash or zsh.
#
#   claude ...           main account  (~/.claude)
#   claude <profile> ... account whose config dir is ~/.claude-<profile>
#   clauded [profile]    same with --dangerously-skip-permissions
#
# Profile names come from ~/.claude-shared/profiles (one per line) and are read on every
# call, so `multi-claude add-profile NAME` takes effect without reopening the shell.
# The first bare argument that equals a profile name is consumed as the selector; every
# other argument is passed through untouched. `main` always means the default account.

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

claude() {
  local _registry="$HOME/.claude-shared/profiles" _known=" main " _profile="" _line _a
  local -a _args
  _args=()
  if [ -r "$_registry" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
      case "$_line" in ''|'#'*|*[!a-z0-9_-]*) continue ;; esac
      _known="$_known$_line "
    done < "$_registry"
  fi
  for _a in "$@"; do
    if [ -z "$_profile" ]; then
      case "$_known" in
        *" $_a "*) _profile="$_a"; continue ;;
      esac
    fi
    _args+=("$_a")
  done
  if [ -n "$_profile" ] && [ "$_profile" != main ]; then
    CLAUDE_CONFIG_DIR="$HOME/.claude-$_profile" command claude ${_args[@]+"${_args[@]}"}
  else
    command claude ${_args[@]+"${_args[@]}"}
  fi
}

alias clauded='claude --dangerously-skip-permissions'
EOF
  ok "wrote $(tilde "$WRAPPER_FILE")"
}

rc_block() {
  printf '%s  managed by setup-multi-claude.sh; re-run it instead of editing this block\n' "$MARK_BEGIN"
  # shellcheck disable=SC2016  # $HOME must stay literal in the rc file
  printf '[ -r "$HOME/.claude-shared/claude-profiles.sh" ] && . "$HOME/.claude-shared/claude-profiles.sh"\n'
  printf '%s\n' "$MARK_END"
}

detect_rc_files() {
  local login_shell
  login_shell="$(basename "${SHELL:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)}")"
  case "$SHELL_CHOICE" in
    bash) RC_FILES="$HOME/.bashrc" ;;
    zsh)  RC_FILES="$HOME/.zshrc" ;;
    both) RC_FILES="$HOME/.bashrc $HOME/.zshrc" ;;
    auto)
      RC_FILES=""
      [ -f "$HOME/.bashrc" ] && RC_FILES="$HOME/.bashrc"
      [ -f "$HOME/.zshrc" ] && RC_FILES="$RC_FILES $HOME/.zshrc"
      case "$login_shell" in
        zsh)  case " $RC_FILES " in *" $HOME/.zshrc "*) ;; *) RC_FILES="$RC_FILES $HOME/.zshrc" ;; esac ;;
        bash) case " $RC_FILES " in *" $HOME/.bashrc "*) ;; *) RC_FILES="$RC_FILES $HOME/.bashrc" ;; esac ;;
      esac
      [ -n "$RC_FILES" ] || RC_FILES="$HOME/.bashrc"
      ;;
    *) die "--shell must be auto, bash, zsh or both" ;;
  esac
}

install_rc_block() {
  local rc="$1" want tmp
  want="$(rc_block)"
  if [ -f "$rc" ] && grep -qF -- "$MARK_BEGIN" "$rc"; then
    if [ "$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" 'index($0,b)==1{p=1} p{print} index($0,e)==1{p=0}' "$rc")" = "$want" ]; then
      ok "$(tilde "$rc") already sources the wrapper"; return 0
    fi
    log "  refreshing the multi-claude block in $(tilde "$rc")"
    if [ "$DRY_RUN" -eq 1 ]; then printf '%s[dry-run]%s rewrite block in %s\n' "$c_dim" "$c_reset" "$rc"; return 0; fi
    tmp="$(mktemp)"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v blk="$want" '
      index($0,b)==1 {print blk; skip=1; next}
      skip && index($0,e)==1 {skip=0; next}
      !skip {print}' "$rc" > "$tmp"
    cat "$tmp" > "$rc"; rm -f "$tmp"
    ok "updated $(tilde "$rc")"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then printf '%s[dry-run]%s append multi-claude block to %s\n' "$c_dim" "$c_reset" "$rc"; return 0; fi
  local sep=""
  if [ -f "$rc" ] && [ -s "$rc" ] && [ -n "$(tail -c1 "$rc")" ]; then sep=$'\n'; fi
  printf '%s\n%s\n' "$sep" "$want" >> "$rc"
  ok "added the multi-claude block to $(tilde "$rc")"
}

self_install() {
  local self target="$BIN_DIR/$SELF_NAME" legacy="$BIN_DIR/$LEGACY_NAME" src
  self="$(self_path)"
  if [ -z "$self" ]; then
    warn "running from a pipe, so the $SELF_NAME command was not installed; use install.sh, which downloads the script to a file first"
    return 0
  fi
  if [ -e "$target" ] && [ "$(readlink -f "$target")" = "$self" ]; then ok "$(tilde "$target") is this script"
  elif [ -e "$target" ] && cmp -s "$self" "$target"; then ok "$(tilde "$target") is up to date"
  else
    run mkdir -p -- "$BIN_DIR"
    run install -m 0755 -- "$self" "$target"
    ok "installed $(tilde "$target") (status / doctor / add-profile / update)"
  fi

  # Remember where this copy came from; `update` pulls from there. Re-running the installed
  # copy itself tells nothing new, so the recorded source stays as it is.
  if src="$(clone_of "$self")"; then state_set source "$src"
  elif [ "$self" != "$(readlink -f "$target" 2>/dev/null || true)" ]; then state_set source download; fi

  # Before 1.1 this command was called claude-profiles. Where an older copy is installed,
  # turn it into an alias instead of leaving a stale second version behind.
  if [ -L "$legacy" ] && [ "$(readlink "$legacy")" = "$SELF_NAME" ]; then
    ok "$(tilde "$legacy") is an alias of $SELF_NAME"
  elif [ -L "$legacy" ] && [ -e "$legacy" ] && [ "$(readlink -f "$legacy")" = "$self" ]; then
    ok "$(tilde "$legacy") is this script"
  elif [ -L "$legacy" ] || { [ -f "$legacy" ] && grep -q "$SCRIPT_NAME" "$legacy" 2>/dev/null; }; then
    run ln -sfn -- "$SELF_NAME" "$legacy"
    ok "$(tilde "$legacy") (the old name) is now an alias of $SELF_NAME"
  elif [ -e "$legacy" ]; then
    warn "$(tilde "$legacy") exists but is not a copy of this script; left alone"
  fi
}

# ================================================================== commands ==========
cmd_install() {
  local p dir share=1 requested="${PROFILES//,/ }" all=""
  for p in $requested; do validate_name "$p"; done
  # Every registered profile is re-wired on each run (that is what makes `install` a repair
  # and `update` safe); --profiles only adds to the list.
  for p in $(list_profiles) $requested; do
    case "$p" in ''|*[!a-z0-9_-]*|-*|main|shared) warn "ignoring '$p' in $(tilde "$REGISTRY_FILE"): not a valid profile name"; continue ;; esac
    case " $all " in *" $p "*) ;; *) all="${all:+$all }$p" ;; esac
  done
  log "multi-claude setup v$VERSION  home=$(tilde "$HOME")  profiles: main${all:+ $all}"
  [ "$(id -u)" -eq 0 ] && warn "running as root: everything lands in $HOME. Run as the user who will use claude."

  log "[1/7] Claude Code binary"
  if [ "$NO_INSTALL" -eq 1 ]; then log "  skipped (--no-install)"; else install_claude || true; fi

  log "[2/7] shared config dir $(tilde "$SHARED_DIR")"
  run mkdir -p -- "$SHARED_DIR"
  if [ -n "$BUNDLE" ]; then seed_bundle "$BUNDLE"; fi

  log "[3/7] main profile $(tilde "$MAIN_DIR")"
  link_profile_dir "$MAIN_DIR"

  log "[4/7] extra profiles"
  [ -n "$all" ] || log "  none (add one with: $SELF_NAME add-profile <name>)"
  for p in $all; do
    link_profile_dir "$(profile_dir "$p")"
    ensure_registered "$p"
  done

  log "[5/7] peer sessions across accounts"
  case "$SHARE_SESSIONS" in
    1) ;;
    0) if sessions_shared; then
         warn "--no-share-sessions ignored: the registry is already shared. To split it: $SELF_NAME unshare-sessions"
       else share=0; fi ;;
    *) if ! sessions_shared && sessions_opted_out; then share=0; fi ;;
  esac
  if [ "$share" -eq 1 ]; then
    log "  one registry for every account: their sessions list and message each other"
    ensure_shared_sessions_dir
    while IFS= read -r dir; do [ -n "$dir" ] && share_sessions_dir "$dir"; done < <(session_profile_dirs "$all")
    state_set sessions ""
  else
    log "  one registry per account (opted out): sessions of different accounts do not see each other"
    log "  switch it on any time with: $SELF_NAME share-sessions"
    state_set sessions per-account
  fi

  log "[6/7] shell wrapper"
  write_wrapper
  detect_rc_files
  for rc in $RC_FILES; do install_rc_block "$rc"; done

  log "[7/7] $SELF_NAME command"
  self_install

  log ""
  if [ "$FAILS" -gt 0 ]; then
    log "finished with $FAILS failure(s) and $WARNS warning(s); fix them and re-run install."; return 1
  fi
  log "done ($WARNS warning(s)). Next steps:"
  local n=1
  printf '  %d. %-28s %-22s %s\n' "$n" "reload the shell:" "exec \$SHELL -l" "(or: source $(tilde "$(printf '%s' "$RC_FILES" | awk '{print $NF}')"))"
  for p in main $all; do   # only the accounts that have never been started
    [ -f "$(profile_state_file "$p")" ] && continue
    n=$((n + 1)); printf '  %d. %-28s %-22s %s\n' "$n" "log in the $p account:" "$(invoke_hint "$p")" "then type /login   (or: $(invoke_hint "$p") auth login)"
  done
  n=$((n + 1)); printf '  %d. %-28s %s\n' "$n" "check every account:" "$SELF_NAME status"
  n=$((n + 1)); printf '  %d. %-28s %s\n' "$n" "verify the wiring:" "$SELF_NAME doctor"
  n=$((n + 1)); printf '  %d. %-28s %s\n' "$n" "add another account:" "$SELF_NAME add-profile <name>   (then: claude <name>, and /login)"
  n=$((n + 1)); printf '  %d. %-28s %s\n' "$n" "update later:" "$SELF_NAME update"
}

cmd_add_profile() {
  local p="${1:-}"
  [ -n "$p" ] || die "usage: $SELF_NAME add-profile <name>"
  validate_name "$p"
  [ -d "$SHARED_DIR" ] || die "$(tilde "$SHARED_DIR") does not exist; run 'install' first"
  link_profile_dir "$(profile_dir "$p")"
  ensure_registered "$p"
  if sessions_shared; then share_sessions_dir "$(profile_dir "$p")"; fi
  log ""
  log "next:  claude $p        start it and type /login to sign in as that account   (or: claude $p auth login)"
  log "then:  $SELF_NAME status     shows which account every profile is logged in as"
  if sessions_shared; then log "its sessions already list and message the sessions of the other accounts"; fi
}

cmd_status() {
  local p dir state json logged email org sub ver
  command -v claude >/dev/null 2>&1 || die "claude is not on PATH"
  ver="$(claude --version 2>/dev/null | head -1)"
  log "multi-claude v$VERSION   claude $ver   wrapper: $(tilde "$WRAPPER_FILE")   registry: $(tilde "$REGISTRY_FILE")   peer sessions: $(sessions_shared && printf 'shared across accounts' || printf 'per account')"
  printf '%-10s %-24s %-11s %-34s %-16s %s\n' PROFILE CONFIG_DIR LOGGED_IN ACCOUNT ORG SUBSCRIPTION
  for p in main $(list_profiles); do
    dir="$(profile_dir "$p")"; state="$(profile_state_file "$p")"
    if [ ! -d "$dir" ]; then
      printf '%-10s %-24s %-11s %s\n' "$p" "$(tilde "$dir")" "no-dir" "run: $SELF_NAME add-profile $p"; continue
    fi
    if [ ! -f "$state" ]; then
      printf '%-10s %-24s %-11s %s\n' "$p" "$(tilde "$dir")" "never-run" "start it once: $(invoke_hint "$p")   then /login"; continue
    fi
    json="$(claude_as "$p" auth status --json 2>/dev/null || true)"
    logged="$(json_field "$json" loggedIn)"
    if [ -z "$logged" ]; then
      # older claude without `auth status --json`: read the account cached in the state file
      email="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("oauthAccount") or {}).get("emailAddress",""))' "$state" 2>/dev/null || true)"
      org="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("oauthAccount") or {}).get("organizationName",""))' "$state" 2>/dev/null || true)"
      logged="$([ -f "$dir/.credentials.json" ] && printf 'yes?' || printf 'no')"; sub="?"
    else
      email="$(json_field "$json" email)"; org="$(json_field "$json" orgName)"; sub="$(json_field "$json" subscriptionType)"
      [ "$logged" = true ] && logged=yes || logged=no
    fi
    printf '%-10s %-24s %-11s %-34s %-16s %s\n' "$p" "$(tilde "$dir")" "$logged" "${email:--}" "${org:--}" "${sub:--}"
  done
}

cmd_doctor() {
  local p dir item src dst rc n want ver mode
  log "multi-claude doctor v$VERSION  home=$(tilde "$HOME")"

  if command -v claude >/dev/null 2>&1; then
    ver="$(claude --version 2>/dev/null | head -1)"; ok "claude binary: $(command -v claude) ($ver)"
  else
    fail "claude is not on PATH (expected $(tilde "$BIN_DIR/claude")); run: $SELF_NAME install"
  fi
  src="$(state_get source)"
  if [ -n "$src" ] && [ "$src" != download ] && [ -e "$src/.git" ] && [ -f "$src/$SCRIPT_NAME" ]; then
    ok "'$SELF_NAME update' pulls the clone $(tilde "$src")"
  else
    [ -z "$src" ] || [ "$src" = download ] || warn "the clone this was installed from, $(tilde "$src"), is gone; '$SELF_NAME update' downloads instead"
    ok "'$SELF_NAME update' downloads from $RAW_URL"
  fi

  if [ -d "$SHARED_DIR" ]; then ok "shared dir $(tilde "$SHARED_DIR")"; else fail "missing $(tilde "$SHARED_DIR")"; fi
  if [ -f "$WRAPPER_FILE" ]; then ok "wrapper $(tilde "$WRAPPER_FILE")"; else fail "missing $(tilde "$WRAPPER_FILE")"; fi
  if [ -f "$REGISTRY_FILE" ]; then
    ok "profiles: main$(list_profiles | tr '\n' ' ' | sed 's/^/ /; s/ *$//')"
  else
    fail "missing registry $(tilde "$REGISTRY_FILE")"
  fi

  # the wrapper must define a function in both shells
  for sh in bash zsh; do
    if command -v "$sh" >/dev/null 2>&1 && [ -f "$WRAPPER_FILE" ]; then
      # shellcheck disable=SC2016  # runs inside the child shell
      if "$sh" -c '. "$1"; if [ -n "${ZSH_VERSION:-}" ]; then whence -w claude | grep -q function; else [ "$(type -t claude)" = function ]; fi' _ "$WRAPPER_FILE" 2>/dev/null; then
        ok "wrapper defines claude() under $sh"
      else
        fail "wrapper does not define claude() under $sh"
      fi
    fi
  done

  # rc files
  detect_rc_files
  for rc in $RC_FILES; do
    if [ -f "$rc" ] && grep -qF -- "$MARK_BEGIN" "$rc"; then
      n="$(grep -cF -- "$MARK_BEGIN" "$rc")"
      if [ "$n" -eq 1 ]; then ok "$(tilde "$rc") sources the wrapper"; else fail "$(tilde "$rc") has $n multi-claude blocks (expected 1)"; fi
    else
      fail "$(tilde "$rc") does not source the wrapper; run: $SELF_NAME install"
    fi
  done

  # per-profile symlinks
  for p in main $(list_profiles); do
    dir="$(profile_dir "$p")"
    if [ ! -d "$dir" ]; then fail "profile '$p': missing $(tilde "$dir")"; continue; fi
    for item in $SHARED_FILES $SHARED_DIRS $SHARED_OPTIONAL_FILES; do
      src="$SHARED_DIR/$item"; dst="$dir/$item"
      case " $SHARED_OPTIONAL_FILES " in *" $item "*) [ -e "$src" ] || continue ;; esac
      if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        [ -e "$dst" ] || fail "profile '$p': $(tilde "$dst") -> missing $(tilde "$src")"
      elif [ -L "$dst" ]; then
        fail "profile '$p': $(tilde "$dst") points to $(readlink "$dst") instead of $(tilde "$src")"
      elif [ -e "$dst" ]; then
        warn "profile '$p': $(tilde "$dst") is a local copy, not shared (re-run install to adopt/merge it)"
      else
        fail "profile '$p': $(tilde "$dst") missing; run: $SELF_NAME install"
      fi
    done
    if [ -f "$(profile_state_file "$p")" ]; then
      ok "profile '$p': state file $(tilde "$(profile_state_file "$p")") present"
    else
      warn "profile '$p': never started; run '$(invoke_hint "$p")' once and /login"
    fi
    if [ "$p" != main ] && [ -f "$dir/.claude.json" ] && [ -f "$HOME/.claude.json" ] && cmp -s "$dir/.claude.json" "$HOME/.claude.json"; then
      warn "profile '$p': its .claude.json is byte-identical to main's; was it copied by hand?"
    fi
  done
  if [ -f "$MAIN_DIR/.claude.json" ]; then
    warn "$(tilde "$MAIN_DIR/.claude.json") exists: something ran with CLAUDE_CONFIG_DIR=~/.claude. Never set that for main; its state lives in ~/.claude.json"
  fi
  warn_unregistered_profiles

  # peer-session registry (shared unless this host opted out)
  if sessions_shared; then
    mode="$(stat -c %a "$SHARED_SESSIONS" 2>/dev/null || printf '?')"
    if [ "$mode" = 700 ]; then ok "peer-session registry shared at $(tilde "$SHARED_SESSIONS") (mode 0700)"
    else warn "$(tilde "$SHARED_SESSIONS") has mode $mode, expected 0700: chmod 0700 $(tilde "$SHARED_SESSIONS")"; fi
    for p in main $(list_profiles); do
      dir="$(profile_dir "$p")"; dst="$dir/sessions"
      [ -d "$dir" ] || continue
      if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$SHARED_SESSIONS" ]; then :
      else fail "profile '$p': $(tilde "$dst") is not linked to the shared registry (its sessions are invisible to the other accounts); run: $SELF_NAME share-sessions"; fi
    done
  elif sessions_opted_out; then
    ok "peer-session registry per account, as chosen (sessions of different accounts do not see each other; switch on: $SELF_NAME share-sessions)"
  else
    warn "peer-session registry is still per account, so sessions of different accounts do not see each other; run: $SELF_NAME share-sessions   (or '$SELF_NAME unshare-sessions' to keep it this way)"
  fi

  # shared dir health
  if [ -d "$SHARED_DIR" ]; then
    if [ -f "$SHARED_DIR/settings.json" ]; then
      if json_valid "$SHARED_DIR/settings.json"; then ok "settings.json is valid JSON"; else fail "settings.json is not valid JSON"; fi
    fi
    while IFS= read -r -d '' dst; do
      warn "dangling symlink $(tilde "$dst") -> $(readlink "$dst") (its target does not exist on this host)"
    done < <(find "$SHARED_DIR" -xtype l -print0 2>/dev/null)
    if [ -f "$SHARED_DIR/settings.json" ] && command -v python3 >/dev/null 2>&1; then
      while read -r kind want; do
        [ -n "$want" ] || continue
        if [ ! -e "$want" ]; then
          if [ "$kind" = hook ]; then fail "settings.json hook references $(tilde "$want") which does not exist (every tool call will report a hook error)"
          else warn "settings.json statusLine references $(tilde "$want") which does not exist (install it or drop the statusLine)"; fi
        fi
      done < <(python3 - "$SHARED_DIR/settings.json" "$HOME" <<'PY' 2>/dev/null
import json,re,sys
d=json.load(open(sys.argv[1])); home=sys.argv[2]
cmds=[]
for ev in (d.get("hooks") or {}).values():
    for m in ev:
        for h in m.get("hooks",[]):
            if h.get("command"): cmds.append(("hook",h["command"]))
sl=d.get("statusLine") or {}
if sl.get("command"): cmds.append(("statusline",sl["command"]))
# a path token: ~/x, $HOME/x or /home/user/x, starting after whitespace, quote, = or line start
pat=re.compile(r"""(?<![^\s'"=])(?:~|\$HOME|/home/[^/\s'"{}:]+)/[^\s'"{}:]+""")
seen=set()
for kind,c in cmds:
    for m in pat.finditer(c):
        if c[max(0,m.start()-5):m.start()]=="PATH=": continue   # PATH=$HOME/bin:... is not a file reference
        tok=m.group(0)
        p=home+tok[1:] if tok.startswith("~") else (home+tok[5:] if tok.startswith("$HOME") else tok)
        if p not in seen:
            seen.add(p); print(kind,p)
PY
)
    fi
    while IFS= read -r -d '' dst; do
      if grep -IoE '(^|[[:space:]"'"'"'=:(])/home/[^/[:space:]"'"'"']+/' "$dst" 2>/dev/null | sed -E 's|^[^/]*||' | grep -vxF -- "$HOME/" | grep -q .; then
        warn "$(tilde "$dst") contains an absolute path under another user's home (bundle from a different \$HOME?)"
      fi
    done < <(find "$SHARED_DIR" -type f ! -path '*/__pycache__/*' ! -name '*.bak-*' -print0 2>/dev/null)
  fi

  log ""
  if [ "$FAILS" -gt 0 ]; then log "doctor: $FAILS failure(s), $WARNS warning(s)"; return 1; fi
  log "doctor: all checks passed ($WARNS warning(s))"
}

cmd_sync_mcp() {
  local from="${1:-}" to="${2:-}" fs ts
  if [ -z "$from" ] || [ -z "$to" ]; then die "usage: $SELF_NAME sync-mcp <from-profile> <to-profile>   (e.g. main alt)"; fi
  [ "$from" != "$to" ] || die "from and to are the same profile"
  for p in "$from" "$to"; do [ "$p" = main ] || is_registered "$p" || die "unknown profile '$p' (see $(tilde "$REGISTRY_FILE"))"; done
  command -v python3 >/dev/null 2>&1 || die "python3 is required for sync-mcp"
  fs="$(profile_state_file "$from")"; ts="$(profile_state_file "$to")"
  [ -f "$fs" ] || die "$(tilde "$fs") not found; start '$(invoke_hint "$from")' once first"
  [ -f "$ts" ] || die "$(tilde "$ts") not found; start '$(invoke_hint "$to")' once first (it creates the state file)"
  warn "close any running '$to' Claude session first, or it may overwrite this change on exit"
  if [ "$DRY_RUN" -eq 1 ]; then printf '%s[dry-run]%s merge mcpServers %s -> %s\n' "$c_dim" "$c_reset" "$fs" "$ts"; return 0; fi
  cp -p -- "$ts" "$ts.bak-$TS"
  python3 - "$fs" "$ts" <<'PY'
import json,sys,os
src=json.load(open(sys.argv[1])); dst_path=sys.argv[2]; dst=json.load(open(dst_path))
s=src.get("mcpServers") or {}; d=dst.setdefault("mcpServers",{})
added=[k for k in s if k not in d]; updated=[k for k in s if k in d and d[k]!=s[k]]
d.update(s)
tmp=dst_path+".tmp"
with open(tmp,"w") as f: json.dump(dst,f,indent=2); f.write("\n")
os.replace(tmp,dst_path)
print(f"  mcpServers: {len(s)} in source; added {added or 'none'}; updated {updated or 'none'}")
PY
  ok "user-scope MCP servers copied from '$from' to '$to' (backup: $(tilde "$ts.bak-$TS"))"
}

cmd_link_memory() {
  local project="${1:-}" slug main_mem p pdir mem
  shift || true
  [ -n "$project" ] || die "usage: $SELF_NAME link-memory <project-dir> [profile ...]   (default: every registered profile)"
  [ -d "$project" ] || die "not a directory: $project"
  project="$(cd "$project" && pwd -P)"
  slug="$(printf '%s' "$project" | sed 's/[^A-Za-z0-9]/-/g')"
  main_mem="$MAIN_DIR/projects/$slug/memory"
  # shellcheck disable=SC2046  # profile names never contain whitespace
  [ $# -gt 0 ] || set -- $(list_profiles)
  [ $# -gt 0 ] || die "no profiles registered"
  run mkdir -p -- "$main_mem"
  for p in "$@"; do
    [ "$p" != main ] || continue
    is_registered "$p" || die "unknown profile '$p'"
    pdir="$(profile_dir "$p")/projects/$slug"; mem="$pdir/memory"
    run mkdir -p -- "$pdir"
    if [ -L "$mem" ]; then
      [ "$(readlink "$mem")" = "$main_mem" ] && { ok "$(tilde "$mem") -> $(tilde "$main_mem")"; continue; }
      warn "$(tilde "$mem") pointed elsewhere; re-pointing"; run rm -- "$mem"
    elif [ -d "$mem" ]; then
      if [ -z "$(ls -A "$mem")" ]; then run rmdir -- "$mem"
      elif [ -z "$(ls -A "$main_mem" 2>/dev/null)" ]; then log "  moving existing $(tilde "$mem") into main"; run rm -rf -- "$main_mem"; run mv -- "$mem" "$main_mem"
      else warn "$(tilde "$mem") has its own notes; kept as $(tilde "$mem").bak-$TS -- merge them into $(tilde "$main_mem") by hand"; run mv -- "$mem" "$mem.bak-$TS"; fi
    fi
    run ln -s -- "$main_mem" "$mem"
    ok "$(tilde "$mem") -> $(tilde "$main_mem")"
  done
}

cmd_exec() {
  local p="${1:-}"; shift || true
  [ -n "$p" ] || die "usage: $SELF_NAME exec <profile> [claude args...]"
  [ "$p" = main ] || is_registered "$p" || die "unknown profile '$p' (see $(tilde "$REGISTRY_FILE"))"
  if [ "$p" = main ]; then exec env -u CLAUDE_CONFIG_DIR claude "$@"; fi
  exec env CLAUDE_CONFIG_DIR="$(profile_dir "$p")" claude "$@"
}

cmd_share_sessions() {
  local dir
  [ -d "$SHARED_DIR" ] || die "$(tilde "$SHARED_DIR") does not exist; run 'install' first"
  log "sharing the peer-session registry: every profile's sessions/ -> $(tilde "$SHARED_SESSIONS")"
  warn_unregistered_profiles
  ensure_shared_sessions_dir
  while IFS= read -r dir; do [ -n "$dir" ] && share_sessions_dir "$dir"; done < <(session_profile_dirs)
  state_set sessions ""
  log ""
  if [ "$FAILS" -gt 0 ]; then log "finished with $FAILS failure(s); fix them and re-run"; return 1; fi
  log "done. Sessions of every account now list and message each other (ListAgents / SendMessage);"
  log "running sessions were carried over and need no restart. Profiles added later join automatically."
  log "undo: $SELF_NAME unshare-sessions"
}

# The reverse of share-sessions. Every config dir linked to the shared registry gets a
# directory of its own again, the entries of running sessions go back to the account they
# run on (so those sessions keep seeing their own account's peers without a restart), and
# the choice is recorded so install and update leave it alone.
cmd_unshare_sessions() {
  local dir dst f base pid owner off n=0 left=0 restored=$'\n'
  [ -d "$SHARED_DIR" ] || die "$(tilde "$SHARED_DIR") does not exist; run 'install' first"
  if ! sessions_shared; then
    state_set sessions per-account
    log "the peer-session registry is already per account; install and update will keep it that way."
    log "switch sharing on with: $SELF_NAME share-sessions"
    return 0
  fi
  log "splitting the peer-session registry: every account gets its own sessions/ again"
  for dir in "$MAIN_DIR" "$HOME"/.claude-*/; do
    dir="${dir%/}"; dst="$dir/sessions"
    { [ -L "$dst" ] && [ "$(readlink "$dst")" = "$SHARED_SESSIONS" ]; } || continue
    run rm -- "$dst"
    run mkdir -m 0700 -- "$dst"
    restored="$restored$dir"$'\n'
    ok "$(tilde "$dst") is a directory of its own"
  done
  for f in "$SHARED_SESSIONS"/*; do
    [ -e "$f" ] || continue
    base="${f##*/}"; pid="${base%%.*}"; owner=""
    case "$pid" in ''|*[!0-9]*) ;; *) owner="$(session_owner_dir "$pid" || true)" ;; esac
    case "$restored" in
      *$'\n'"${owner:-?}"$'\n'*) run mv -- "$f" "$owner/sessions/"; n=$((n + 1)) ;;
      *) left=$((left + 1)) ;;
    esac
  done
  [ "$n" -eq 0 ] || log "  handed $n registry file(s) of running sessions back to their accounts"
  if [ "$left" -eq 0 ]; then
    run rmdir -- "$SHARED_SESSIONS"
  else
    off="$SHARED_SESSIONS.off-$TS"
    run mv -- "$SHARED_SESSIONS" "$off"
    log "  $left file(s) of sessions that are no longer running were kept in $(tilde "$off"); delete it when convenient"
  fi
  state_set sessions per-account
  log ""
  log "done. Sessions of different accounts no longer see each other; sessions of one account still do."
  log "This choice is remembered: install and update keep it. Switch back with: $SELF_NAME share-sessions"
}

# fetch_repo_file NAME DEST : download one file of this project (curl, or wget without it)
fetch_repo_file() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$RAW_URL/$1" -o "$2"
  else wget -qO "$2" "$RAW_URL/$1"; fi
}

# Bring this installation to the latest version and re-apply it. Installed from a clone:
# `git pull` there. Installed any other way (install.sh, a copied file): download the script.
# Either way the new version then runs `install`, which refreshes the command, the wrapper
# and the wiring of every registered profile and leaves accounts and settings as they are.
cmd_update() {
  local self src target="$BIN_DIR/$SELF_NAME" new tmp before after newver
  self="$(self_path)"
  src="$(clone_of "$self" || true)"
  [ -n "$src" ] || src="$(state_get source)"

  if [ -n "$src" ] && [ "$src" != download ] && [ -e "$src/.git" ] && [ -f "$src/$SCRIPT_NAME" ]; then
    command -v git >/dev/null 2>&1 || die "git is required to update the clone $(tilde "$src")"
    log "updating from the clone $(tilde "$src")"
    if [ "$DRY_RUN" -eq 1 ]; then
      run git -C "$src" pull --ff-only; run bash "$src/$SCRIPT_NAME" install; return 0
    fi
    before="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
    git -C "$src" pull --ff-only || die "git pull failed in $(tilde "$src"); fix the clone and run '$SELF_NAME update' again"
    after="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
    new="$src/$SCRIPT_NAME"
    if [ "$before" = "$after" ] && [ -e "$target" ] && cmp -s "$new" "$target"; then
      log "already up to date (v$VERSION)"; return 0
    fi
    exec bash "$new" install
  fi

  [ -z "$src" ] || [ "$src" = download ] || warn "the clone this was installed from, $(tilde "$src"), is gone; downloading instead"
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "curl or wget is required to download the update"
  log "updating from $RAW_URL"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s download %s/%s to %s and run: %s install\n' "$c_dim" "$c_reset" "$RAW_URL" "$SCRIPT_NAME" "$(tilde "$target")" "$SELF_NAME"; return 0
  fi
  tmp="$(mktemp -d)"; new="$tmp/$SCRIPT_NAME"
  if ! fetch_repo_file "$SCRIPT_NAME" "$new"; then
    rm -rf "$tmp"; die "download failed: $RAW_URL/$SCRIPT_NAME (nothing was changed)"
  fi
  # a truncated or wrong download must never replace the working command
  if ! head -n 1 "$new" | grep -q '^#!.*bash' || ! grep -q '^VERSION=' "$new" || ! bash -n "$new" 2>/dev/null; then
    rm -rf "$tmp"; die "the downloaded file is not a valid $SCRIPT_NAME (nothing was changed)"
  fi
  if [ -e "$target" ] && cmp -s "$new" "$target"; then
    rm -rf "$tmp"; log "already up to date (v$VERSION)"; return 0
  fi
  newver="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$new" | head -1)"
  log "  v$VERSION -> v${newver:-?}"
  mkdir -p -- "$BIN_DIR"
  # rename into place: a running copy of the old file keeps its own inode until it exits
  install -m 0755 -- "$new" "$target.new.$$"
  mv -f -- "$target.new.$$" "$target"
  rm -rf "$tmp"
  state_set source download
  exec "$target" install
}

cmd_help() {
  cat <<EOF
multi-claude v$VERSION - several Claude Code accounts on one machine

usage: $(basename "$0") <command> [options]

everyday
  add-profile <name>      add one more account: creates ~/.claude-<name>, wires it to the
                          shared config and registers it. Then run 'claude <name>' and /login.
                          No shell reload needed
  status                  which account each profile is logged in as
  doctor                  verify binary, wrapper, rc files, symlinks, hooks, session sharing;
                          exit 1 on failure
  update                  get the latest multi-claude and re-apply it: 'git pull' when it was
                          installed from a clone, a download otherwise. Accounts, logins and
                          settings are left as they are ('claude update' updates Claude Code)

setup
  install                 install Claude Code if missing, create ~/.claude-shared, wire the
                          main and extra profile dirs, share the peer-session registry,
                          install the claude() shell wrapper and copy this script to
                          ~/.local/bin/$SELF_NAME. Idempotent: re-running it repairs the
                          wiring of every registered profile
      --profiles a,b      extra account profiles -> ~/.claude-<name>. Default: alt on a fresh
                          host; on a configured host the names are added to the existing ones
      --bundle FILE       seed ~/.claude-shared from export-shared-bundle.sh output
      --no-share-sessions keep one peer-session registry per account: sessions of different
                          accounts then do not see each other (remembered for later runs)
      --share-sessions    share the registry even if this host opted out before
      --shell auto|bash|zsh|both   which rc files get the source line (default: auto)
      --claude-version V  latest | stable | x.y.z for the native installer
      --no-install        do not download Claude Code
      --upgrade           re-run the installer even if claude exists
      --dry-run           print what would change; touch nothing

sessions across accounts (on by default)
  share-sessions          one peer-session registry for all profiles: Claude Code sessions of
                          different accounts list and message each other (ListAgents /
                          SendMessage). Safe while sessions are running
  unshare-sessions        back to one registry per account; running sessions keep their own
                          account's peers. Remembered, so install and update keep it

sharing between accounts
  sync-mcp <from> <to>    copy user-scope MCP servers between profiles on this host
  link-memory <dir> [p..] share a project's memory notes between main and profile(s)

other
  exec <profile> [args]   run claude as a profile without the shell function (scripts, cron,
                          non-interactive ssh where ~/.bashrc is not read)
  print-wrapper           print the shell wrapper (to install it by hand)
  version                 print the multi-claude version
  help                    this text

add-profile, share-sessions, unshare-sessions, sync-mcp and update accept --dry-run as the
last argument.

after install:   claude            -> main account        claude alt        -> alt account
                 clauded alt       -> alt, skip permission prompts
EOF
}

# ================================================================== main ==============
[ $# -gt 0 ] || { cmd_help; exit 1; }
cmd="$1"; shift
case "$cmd" in
  install)
    while [ $# -gt 0 ]; do
      case "$1" in
        --profiles) PROFILES="${2:-}"; PROFILES_SET=1; shift 2 ;;
        --profiles=*) PROFILES="${1#*=}"; PROFILES_SET=1; shift ;;
        --bundle) BUNDLE="${2:-}"; shift 2 ;;
        --bundle=*) BUNDLE="${1#*=}"; shift ;;
        --shell) SHELL_CHOICE="${2:-}"; shift 2 ;;
        --shell=*) SHELL_CHOICE="${1#*=}"; shift ;;
        --claude-version) CLAUDE_VERSION="${2:-}"; shift 2 ;;
        --claude-version=*) CLAUDE_VERSION="${1#*=}"; shift ;;
        --no-install) NO_INSTALL=1; shift ;;
        --share-sessions) SHARE_SESSIONS=1; shift ;;
        --no-share-sessions) SHARE_SESSIONS=0; shift ;;
        --upgrade) UPGRADE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) cmd_help; exit 0 ;;
        *) die "unknown option for install: $1" ;;
      esac
    done
    if [ "$PROFILES_SET" -eq 1 ]; then
      [ -n "$PROFILES" ] || die "--profiles needs at least one name"
    elif [ ! -e "$REGISTRY_FILE" ]; then
      PROFILES="alt"   # a fresh host starts with main + alt
    fi
    cmd_install ;;
  add-profile)   [ "${2:-}" = --dry-run ] && DRY_RUN=1; cmd_add_profile "${1:-}" ;;
  share-sessions) [ "${1:-}" = --dry-run ] && DRY_RUN=1; cmd_share_sessions ;;
  unshare-sessions) [ "${1:-}" = --dry-run ] && DRY_RUN=1; cmd_unshare_sessions ;;
  update)
    case "${1:-}" in
      '') ;;
      --dry-run) DRY_RUN=1 ;;
      *) die "unknown option for update: $1" ;;
    esac
    cmd_update ;;
  version|--version|-V) log "multi-claude v$VERSION" ;;
  status)        cmd_status ;;
  doctor)        cmd_doctor ;;
  sync-mcp)      [ "${3:-}" = --dry-run ] && DRY_RUN=1; cmd_sync_mcp "${1:-}" "${2:-}" ;;
  link-memory)   cmd_link_memory "$@" ;;
  exec)          cmd_exec "$@" ;;
  print-wrapper)
    if [ -f "$WRAPPER_FILE" ]; then cat "$WRAPPER_FILE"
    else DRY_RUN=0; SHARED_DIR="$(mktemp -d)"; WRAPPER_FILE="$SHARED_DIR/claude-profiles.sh"; write_wrapper >/dev/null; cat "$WRAPPER_FILE"; rm -rf "$SHARED_DIR"; fi ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command '$cmd' (try: $(basename "$0") help)" ;;
esac
