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
# Idempotent: `install` can be re-run at any time. Nothing is deleted; anything that
# has to move out of the way is renamed to <name>.bak-<timestamp>.
#
# Run `setup-multi-claude.sh help` for usage. After `install` the script is also
# available as `claude-profiles` (copied to ~/.local/bin).
set -euo pipefail

VERSION="1.0.0"
INSTALLER_URL="${CLAUDE_INSTALLER_URL:-https://claude.ai/install.sh}"

# Everything is derived from $HOME. Tests point HOME at a sandbox; never hardcode a user.
SHARED_DIR="$HOME/.claude-shared"
MAIN_DIR="$HOME/.claude"
BIN_DIR="$HOME/.local/bin"
WRAPPER_FILE="$SHARED_DIR/claude-profiles.sh"
REGISTRY_FILE="$SHARED_DIR/profiles"
SELF_NAME="claude-profiles"

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
PROFILES="alt"
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
# Managed by setup-multi-claude.sh / claude-profiles add-profile. Read by the claude() wrapper on every call."
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

# ------------------------------------------------------------------ bundle seeding ----
seed_bundle() {
  local bundle="$1" listing src_home
  [ -f "$bundle" ] || die "bundle not found: $bundle"
  listing="$(tar -tzf "$bundle")" || die "cannot read bundle $bundle"
  if printf '%s\n' "$listing" | grep -qE '(^|/)(\.credentials\.json|\.claude\.json)$'; then
    die "refusing bundle $bundle: it contains credential/state files"
  fi
  if printf '%s\n' "$listing" | grep -qE '^/|(^|/)\.\.(/|$)'; then
    die "refusing bundle $bundle: absolute or parent paths inside the archive"
  fi
  if [ -d "$SHARED_DIR" ] && [ -n "$(ls -A "$SHARED_DIR" 2>/dev/null)" ]; then
    warn "$(tilde "$SHARED_DIR") is not empty; keeping a copy at $(tilde "$SHARED_DIR").bak-$TS before extracting the bundle over it"
    run cp -a -- "$SHARED_DIR" "$SHARED_DIR.bak-$TS"
  fi
  run mkdir -p -- "$SHARED_DIR"
  log "  extracting $(tilde "$bundle") into $(tilde "$SHARED_DIR")"
  run tar -xzf "$bundle" -C "$SHARED_DIR"
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
# claude-profiles.sh - generated by setup-multi-claude.sh. Re-run `claude-profiles install`
# to regenerate; do not edit by hand. Works when sourced from bash or zsh.
#
#   claude ...           main account  (~/.claude)
#   claude <profile> ... account whose config dir is ~/.claude-<profile>
#   clauded [profile]    same with --dangerously-skip-permissions
#
# Profile names come from ~/.claude-shared/profiles (one per line) and are read on every
# call, so `claude-profiles add-profile NAME` takes effect without reopening the shell.
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
  local self target
  case "$0" in
    bash|sh|-bash|-sh|*/bash|*/sh) log "  (running from a pipe; not copying myself to $(tilde "$BIN_DIR/$SELF_NAME"))"; return 0 ;;
  esac
  self="$(readlink -f "$0")"; target="$BIN_DIR/$SELF_NAME"
  if [ -e "$target" ] && [ "$(readlink -f "$target")" = "$self" ]; then ok "$(tilde "$target") is this script"; return 0; fi
  if [ -e "$target" ] && cmp -s "$self" "$target"; then ok "$(tilde "$target") is up to date"; return 0; fi
  run mkdir -p -- "$BIN_DIR"
  run install -m 0755 -- "$self" "$target"
  ok "installed $(tilde "$target") (use it for status / doctor / add-profile later)"
}

# ================================================================== commands ==========
cmd_install() {
  local p
  log "multi-claude setup v$VERSION  home=$(tilde "$HOME")  profiles: main ${PROFILES//,/ }"
  [ "$(id -u)" -eq 0 ] && warn "running as root: everything lands in $HOME. Run as the user who will use claude."
  for p in ${PROFILES//,/ }; do validate_name "$p"; done

  log "[1/6] Claude Code binary"
  if [ "$NO_INSTALL" -eq 1 ]; then log "  skipped (--no-install)"; else install_claude || true; fi

  log "[2/6] shared config dir $(tilde "$SHARED_DIR")"
  run mkdir -p -- "$SHARED_DIR"
  if [ -n "$BUNDLE" ]; then seed_bundle "$BUNDLE"; fi

  log "[3/6] main profile $(tilde "$MAIN_DIR")"
  link_profile_dir "$MAIN_DIR"

  log "[4/6] extra profiles"
  for p in ${PROFILES//,/ }; do
    link_profile_dir "$(profile_dir "$p")"
    ensure_registered "$p"
  done

  log "[5/6] shell wrapper"
  write_wrapper
  detect_rc_files
  for rc in $RC_FILES; do install_rc_block "$rc"; done

  log "[6/6] helper command"
  self_install

  log ""
  if [ "$FAILS" -gt 0 ]; then
    log "finished with $FAILS failure(s) and $WARNS warning(s); fix them and re-run install."; return 1
  fi
  log "done ($WARNS warning(s)). Next steps:"
  local n=1
  printf '  %d. %-28s %-18s %s\n' "$n" "reload the shell:" "exec \$SHELL -l" "(or: source $(tilde "$(printf '%s' "$RC_FILES" | awk '{print $NF}')"))"
  n=$((n + 1)); printf '  %d. %-28s %-18s %s\n' "$n" "log in the main account:" "claude" "then type /login   (or: claude auth login)"
  for p in ${PROFILES//,/ }; do
    n=$((n + 1)); printf '  %d. %-28s %-18s %s\n' "$n" "log in the '$p' account:" "claude $p" "then type /login   (or: claude $p auth login)"
  done
  n=$((n + 1)); printf '  %d. %-28s %s\n' "$n" "check every account:" "$SELF_NAME status"
  n=$((n + 1)); printf '  %d. %-28s %s\n' "$n" "verify the wiring:" "$SELF_NAME doctor"
}

cmd_add_profile() {
  local p="${1:-}"
  [ -n "$p" ] || die "usage: $SELF_NAME add-profile <name>"
  validate_name "$p"
  [ -d "$SHARED_DIR" ] || die "$(tilde "$SHARED_DIR") does not exist; run 'install' first"
  link_profile_dir "$(profile_dir "$p")"
  ensure_registered "$p"
  log ""
  log "log in the new account with:   claude $p        then type /login   (or: claude $p auth login)"
}

cmd_status() {
  local p dir state json logged email org sub ver
  command -v claude >/dev/null 2>&1 || die "claude is not on PATH"
  ver="$(claude --version 2>/dev/null | head -1)"
  log "claude $ver   wrapper: $(tilde "$WRAPPER_FILE")   registry: $(tilde "$REGISTRY_FILE")"
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
  local p dir item src dst rc n want ver
  log "multi-claude doctor  home=$(tilde "$HOME")"

  if command -v claude >/dev/null 2>&1; then
    ver="$(claude --version 2>/dev/null | head -1)"; ok "claude binary: $(command -v claude) ($ver)"
  else
    fail "claude is not on PATH (expected $(tilde "$BIN_DIR/claude")); run: $SELF_NAME install"
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

cmd_help() {
  cat <<EOF
setup-multi-claude.sh v$VERSION - several Claude Code accounts on one machine

usage: $(basename "$0") <command> [options]

commands
  install                 install Claude Code if missing, create ~/.claude-shared, wire the
                          main and extra profile dirs, install the claude() shell wrapper,
                          copy this script to ~/.local/bin/$SELF_NAME. Idempotent.
      --profiles a,b      extra account profiles (default: alt) -> ~/.claude-<name>
      --bundle FILE       seed ~/.claude-shared from export-shared-bundle.sh output
      --shell auto|bash|zsh|both   which rc files get the source line (default: auto)
      --claude-version V  latest | stable | x.y.z for the native installer
      --no-install        do not download Claude Code
      --upgrade           re-run the installer even if claude exists
      --dry-run           print what would change; touch nothing
  add-profile <name>      add one more account profile (no shell reload needed)
  status                  which account each profile is logged in as
  doctor                  verify binary, wrapper, rc files, symlinks, hooks; exit 1 on failure
  sync-mcp <from> <to>    copy user-scope MCP servers between profiles on this host
  link-memory <dir> [p..] share a project's memory notes between main and profile(s)
  exec <profile> [args]   run claude as a profile without the shell function (scripts, cron,
                          non-interactive ssh where ~/.bashrc is not read)
  print-wrapper           print the shell wrapper (to install it by hand)
  help                    this text

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
        --profiles) PROFILES="${2:-}"; shift 2 ;;
        --profiles=*) PROFILES="${1#*=}"; shift ;;
        --bundle) BUNDLE="${2:-}"; shift 2 ;;
        --bundle=*) BUNDLE="${1#*=}"; shift ;;
        --shell) SHELL_CHOICE="${2:-}"; shift 2 ;;
        --shell=*) SHELL_CHOICE="${1#*=}"; shift ;;
        --claude-version) CLAUDE_VERSION="${2:-}"; shift 2 ;;
        --claude-version=*) CLAUDE_VERSION="${1#*=}"; shift ;;
        --no-install) NO_INSTALL=1; shift ;;
        --upgrade) UPGRADE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) cmd_help; exit 0 ;;
        *) die "unknown option for install: $1" ;;
      esac
    done
    [ -n "$PROFILES" ] || die "--profiles needs at least one name"
    cmd_install ;;
  add-profile)   [ "${2:-}" = --dry-run ] && DRY_RUN=1; cmd_add_profile "${1:-}" ;;
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
