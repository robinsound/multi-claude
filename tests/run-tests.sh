#!/usr/bin/env bash
# Sandboxed tests for setup-multi-claude.sh, install.sh and export-shared-bundle.sh.
#
# Everything runs under a throwaway HOME inside a mktemp sandbox. The real `claude` binary
# and the network are replaced by shims (a fake `claude` that echoes how it was called, and
# a fake `curl` that serves a fake Claude installer plus this project's own files from a
# sandbox directory). The harness refuses to run if HOME is not inside the sandbox, so it
# can never touch the real ~/.claude, ~/.claude-alt or rc files.
#
# The scripts under test are copies inside the sandbox, not the files of this checkout. An
# install records where it came from so that `update` can pull from there; run from the
# checkout, a test of `update` would `git pull` the real repository. A copy has no clone
# behind it, and the last check of the suite proves no sandbox home ever pointed outside.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
KEEP="${KEEP_SANDBOX:-0}"

REAL_HOME="$HOME"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/multi-claude-test.XXXXXX")"
BG_PIDS=""
cleanup() {
  # shellcheck disable=SC2086  # a list of pids
  [ -z "$BG_PIDS" ] || kill $BG_PIDS 2>/dev/null
  [ "$KEEP" = 1 ] && { echo "sandbox kept at $SANDBOX"; return; }
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# ---- sandbox guard: never run against a real home -------------------------------------
export HOME="$SANDBOX/home"
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$HOME" "$TMPDIR"
case "$HOME" in "$SANDBOX"/*) ;; *) echo "refusing to run: HOME=$HOME is outside the sandbox"; exit 1 ;; esac
[ "$HOME" != "$REAL_HOME" ] || { echo "refusing to run: HOME is the real home"; exit 1; }
unset CLAUDE_CONFIG_DIR MULTI_CLAUDE_REPO MULTI_CLAUDE_REF
export SHELL=/bin/bash

# ---- the scripts under test: sandbox copies with no git clone behind them --------------
COPY="$SANDBOX/scripts"; mkdir -p "$COPY"
cp "$ROOT/setup-multi-claude.sh" "$ROOT/install.sh" "$ROOT/export-shared-bundle.sh" "$COPY/" || { echo "cannot copy the scripts into the sandbox"; exit 1; }
SETUP="$COPY/setup-multi-claude.sh"
INSTALL="$COPY/install.sh"
EXPORT="$COPY/export-shared-bundle.sh"

# ---- shims ----------------------------------------------------------------------------
SHIM_CURL="$SANDBOX/shim-curl"; SHIM_CLAUDE="$SANDBOX/shim-claude"
mkdir -p "$SHIM_CURL" "$SHIM_CLAUDE"
SYS_PATH="/usr/local/bin:/usr/bin:/bin"
# the project's download location, as the fake curl serves it: files placed in $SERVE
SERVE="$SANDBOX/serve"; mkdir -p "$SERVE"
export MULTI_CLAUDE_RAW_URL="https://raw.test"

cat > "$SHIM_CLAUDE/claude" <<'EOF'
#!/usr/bin/env bash
# fake claude: answers --version and `auth status --json`; otherwise echoes its invocation
case "${1:-}" in
  --version) echo "9.9.9 (Claude Code fake)"; exit 0 ;;
  auth)
    if [ "${2:-}" = status ]; then
      if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then cfg="$CLAUDE_CONFIG_DIR"; state="$CLAUDE_CONFIG_DIR/.claude.json"; else cfg="$HOME/.claude"; state="$HOME/.claude.json"; fi
      if [ -f "$state" ]; then
        email="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("oauthAccount") or {}).get("emailAddress",""))' "$state")"
        printf '{"loggedIn": true, "email": "%s", "orgName": "TestOrg", "subscriptionType": "team", "configDirectory": "%s"}\n' "$email" "$cfg"
      else
        printf '{"loggedIn": false, "configDirectory": "%s"}\n' "$cfg"
      fi
      exit 0
    fi ;;
esac
printf 'CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}"
printf 'ARGC=%d\n' $#
for a in "$@"; do printf 'ARG=[%s]\n' "$a"; done
EOF
chmod +x "$SHIM_CLAUDE/claude"

cat > "$SHIM_CURL/curl" <<EOF
#!/usr/bin/env bash
# fake curl, -o FILE only: serves the Claude installer and this project's files
# (https://raw.test/NAME comes from $SERVE/NAME, a missing file is a 404 like curl -f);
# anything else is an error
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
[ -n "\$out" ] || { echo "fake curl: expected -o FILE" >&2; exit 99; }
case "\$url" in
  https://raw.test/*)
    f="$SERVE/\${url#https://raw.test/}"
    [ -f "\$f" ] || { echo "fake curl: (22) 404 for \$url" >&2; exit 22; }
    cat "\$f" > "\$out"; exit 0 ;;
  https://claude.ai/install.sh) ;;
  *) echo "fake curl: unexpected url \$url" >&2; exit 99 ;;
esac
cat > "\$out" <<'INSTALLER'
#!/usr/bin/env bash
# fake native installer: drops the fake claude into ~/.local/bin, like the real one
mkdir -p "\$HOME/.local/bin"
cp "$SHIM_CLAUDE/claude" "\$HOME/.local/bin/claude"
echo "fake installer: installed \${1:-latest} to \$HOME/.local/bin/claude"
INSTALLER
EOF
chmod +x "$SHIM_CURL/curl"

# ---- tiny test framework --------------------------------------------------------------
PASS=0; FAIL=0; CUR=""
t()        { CUR="$1"; }
pass()     { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s%s\n' "$CUR" "${1:+ - $1}"; }
failt()    { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s - %s\n' "$CUR" "$1"; }
assert_eq()       { if [ "$1" = "$2" ]; then pass "$3"; else failt "$3: expected [$2] got [$1]"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then pass "contains '$2'"; else failt "missing '$2' in: $(printf '%s' "$1" | head -c 400)"; fi; }
assert_not_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then failt "unexpected '$2' in output"; else pass "no '$2'"; fi; }
assert_file()     { if [ -f "$1" ]; then pass "file $1"; else failt "missing file $1"; fi; }
assert_dir()      { if [ -d "$1" ] && [ ! -L "$1" ]; then pass "dir $1"; else failt "missing dir $1"; fi; }
assert_absent()   { if [ ! -e "$1" ] && [ ! -L "$1" ]; then pass "absent $1"; else failt "should not exist: $1"; fi; }
assert_link()     { if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then pass "$(basename "$1") -> shared"; else failt "$1 should be a symlink to $2 (is: $(readlink "$1" 2>/dev/null || echo not-a-link))"; fi; }
assert_rc()       { if [ "$1" -eq "$2" ]; then pass "exit $2"; else failt "exit code $1, expected $2"; fi; }
assert_count()    { local n; n="$(grep -cF -- "$2" "$1" 2>/dev/null || true)"; if [ "$n" -eq "$3" ]; then pass "$3x marker in $(basename "$1")"; else failt "$(basename "$1") has $n markers, expected $3"; fi; }

# run the wrapper inside a given shell with args; prints the fake claude's report
via() {  # via SHELL cmdline...
  local sh="$1"; shift
  case "$sh" in
    zsh)  zsh -c '. "$HOME/.claude-shared/claude-profiles.sh"; eval "$1"' _ "$*" ;;
    bash) bash -c 'shopt -s expand_aliases; . "$HOME/.claude-shared/claude-profiles.sh"; eval "$1"' _ "$*" ;;
  esac
}
have_zsh=0; command -v zsh >/dev/null 2>&1 && have_zsh=1

echo "sandbox: $SANDBOX"
echo

# ======================================================================================
echo "[T0] static checks"
t "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$SETUP" "$EXPORT"; then pass; else failt "shellcheck reported problems"; fi
  if shellcheck -s sh "$INSTALL"; then pass "install.sh is POSIX sh"; else failt "shellcheck reported problems in install.sh"; fi
else pass "skipped (no shellcheck)"; fi
t "bash -n"; if bash -n "$SETUP" && bash -n "$EXPORT"; then pass; else failt "syntax error"; fi
t "sh -n install.sh"; if sh -n "$INSTALL"; then pass; else failt "syntax error"; fi

# ======================================================================================
echo "[T1] fresh install with no claude on PATH (installer via fake curl)"
export PATH="$SHIM_CURL:$SYS_PATH"
touch "$HOME/.bashrc" "$HOME/.zshrc"
t "install"
out="$(bash "$SETUP" install --profiles alt --shell both 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "fake installer: installed latest"
assert_contains "$out" "registered profile 'alt'"
assert_not_contains "$out" "FAIL"
assert_file "$HOME/.local/bin/claude"
for item in CLAUDE.md settings.json; do assert_file "$HOME/.claude-shared/$item"; done
for item in hooks commands rules skills agents; do assert_dir "$HOME/.claude-shared/$item"; done
assert_eq "$(cat "$HOME/.claude-shared/settings.json")" "{}" "empty settings.json"
for p in .claude .claude-alt; do
  for item in CLAUDE.md settings.json hooks commands rules skills agents; do
    assert_link "$HOME/$p/$item" "$HOME/.claude-shared/$item"
  done
done
assert_absent "$HOME/.claude/claude-powerline.json"
assert_eq "$(grep -v '^#' "$HOME/.claude-shared/profiles")" "alt" "registry"
assert_file "$HOME/.claude-shared/claude-profiles.sh"
assert_count "$HOME/.bashrc" "# >>> multi-claude >>>" 1
assert_count "$HOME/.zshrc" "# >>> multi-claude >>>" 1
assert_file "$HOME/.local/bin/multi-claude"
[ -x "$HOME/.local/bin/multi-claude" ] && pass "multi-claude executable" || failt "multi-claude not executable"
assert_absent "$HOME/.local/bin/claude-profiles"   # the pre-1.1 name is only kept where it was installed
assert_eq "$(grep '^source=' "$HOME/.claude-shared/multi-claude.conf")" "source=download" "update source recorded (no clone behind this copy)"
t "a fresh install shares the peer-session registry"
assert_contains "$out" "one registry for every account"
assert_dir "$HOME/.claude-shared/sessions"
assert_eq "$(stat -c %a "$HOME/.claude-shared/sessions")" "700" "shared registry mode 0700"
for p in .claude .claude-alt; do assert_link "$HOME/$p/sessions" "$HOME/.claude-shared/sessions"; done
t "next steps name the accounts to log in and how to add one"
assert_contains "$out" "log in the main account:"
assert_contains "$out" "log in the alt account:"
assert_contains "$out" "multi-claude add-profile <name>"
assert_contains "$out" "multi-claude update"

# from here on the installed fake claude is on PATH (as it would be after the installer)
export PATH="$HOME/.local/bin:$SHIM_CURL:$SYS_PATH"

echo "[T2] re-running install is a no-op"
t "idempotent"
out="$(multi-claude install --profiles alt --shell both --no-install 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_not_contains "$out" " warn "
assert_count "$HOME/.bashrc" "# >>> multi-claude >>>" 1
assert_count "$HOME/.zshrc" "# >>> multi-claude >>>" 1
assert_eq "$(find "$HOME" -name '*.bak-*' | wc -l | tr -d ' ')" "0" "no backups created"
assert_eq "$(grep -cv '^#' "$HOME/.claude-shared/profiles")" "1" "registry still one line"

# ======================================================================================
echo "[T3] wrapper routing"
for sh in bash zsh; do
  [ "$sh" = zsh ] && [ "$have_zsh" -eq 0 ] && { echo "  (zsh not installed; skipping)"; continue; }
  t "$sh: claude";                 assert_eq "$(via $sh 'claude')" $'CONFIG_DIR=<unset>\nARGC=0' "main, no args"
  t "$sh: claude alt";             assert_eq "$(via $sh 'claude alt')" "CONFIG_DIR=$HOME/.claude-alt"$'\nARGC=0' "alt, no args"
  t "$sh: claude alt --resume x";  assert_eq "$(via $sh 'claude alt --resume x')" "CONFIG_DIR=$HOME/.claude-alt"$'\nARGC=2\nARG=[--resume]\nARG=[x]' "alt with args"
  t "$sh: claude --foo alt";       assert_eq "$(via $sh 'claude --foo alt')" "CONFIG_DIR=$HOME/.claude-alt"$'\nARGC=1\nARG=[--foo]' "alt keyword after a flag"
  t "$sh: clauded alt";            assert_eq "$(via $sh 'clauded alt')" "CONFIG_DIR=$HOME/.claude-alt"$'\nARGC=1\nARG=[--dangerously-skip-permissions]' "clauded alias"
  t "$sh: clauded";                assert_eq "$(via $sh 'clauded')" $'CONFIG_DIR=<unset>\nARGC=1\nARG=[--dangerously-skip-permissions]' "clauded main"
  t "$sh: claude -p 'alt text'";   assert_eq "$(via $sh "claude -p 'alt text'")" $'CONFIG_DIR=<unset>\nARGC=2\nARG=[-p]\nARG=[alt text]' "quoted prompt untouched"
  t "$sh: claude alt alt";         assert_eq "$(via $sh 'claude alt alt')" "CONFIG_DIR=$HOME/.claude-alt"$'\nARGC=1\nARG=[alt]' "only first keyword consumed"
  t "$sh: claude main -p hi";      assert_eq "$(via $sh 'claude main -p hi')" $'CONFIG_DIR=<unset>\nARGC=2\nARG=[-p]\nARG=[hi]' "main keyword"
  t "$sh: claude work (unknown)";  assert_eq "$(via $sh 'claude work')" $'CONFIG_DIR=<unset>\nARGC=1\nARG=[work]' "unregistered name passes through"
  t "$sh: claude ''";              assert_eq "$(via $sh "claude ''")" $'CONFIG_DIR=<unset>\nARGC=1\nARG=[]' "empty arg passes through"
  t "$sh: claude 'a b' alt";       assert_eq "$(via $sh "claude 'a b' alt")" "CONFIG_DIR=$HOME/.claude-alt"$'\nARGC=1\nARG=[a b]' "arg with space preserved"
done
t "bash set -u"
assert_eq "$(bash -uc '. "$HOME/.claude-shared/claude-profiles.sh"; claude' 2>&1)" $'CONFIG_DIR=<unset>\nARGC=0' "wrapper survives set -u"
t "wrapper does not leak CLAUDE_CONFIG_DIR"
assert_eq "$(bash -c '. "$HOME/.claude-shared/claude-profiles.sh"; claude alt >/dev/null; echo "${CLAUDE_CONFIG_DIR-<unset>}"')" "<unset>" "env not exported"

echo "[T4] add-profile takes effect without re-sourcing"
t "add-profile work"
out="$(multi-claude add-profile work 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_link "$HOME/.claude-work/settings.json" "$HOME/.claude-shared/settings.json"
assert_eq "$(grep -v '^#' "$HOME/.claude-shared/profiles" | tr '\n' ' ')" "alt work " "registry has both"
assert_eq "$(via bash 'claude work --x')" "CONFIG_DIR=$HOME/.claude-work"$'\nARGC=1\nARG=[--x]' "new profile routed"
assert_link "$HOME/.claude-work/sessions" "$HOME/.claude-shared/sessions"
assert_contains "$out" "claude work"
assert_contains "$out" "/login"
t "add-profile rejects bad names"
multi-claude add-profile 'Bad Name' >/dev/null 2>&1; assert_rc $? 1
multi-claude add-profile main >/dev/null 2>&1; assert_rc $? 1
multi-claude add-profile shared >/dev/null 2>&1; assert_rc $? 1
multi-claude add-profile -x >/dev/null 2>&1; assert_rc $? 1
assert_eq "$(grep -cv '^#' "$HOME/.claude-shared/profiles")" "2" "registry unchanged after rejects"
t "exec runs a profile without the shell function"
assert_eq "$(multi-claude exec alt --x)" "CONFIG_DIR=$HOME/.claude-alt"$'\nARGC=1\nARG=[--x]' "exec alt"
assert_eq "$(CLAUDE_CONFIG_DIR=/elsewhere multi-claude exec main)" $'CONFIG_DIR=<unset>\nARGC=0' "exec main clears an inherited CLAUDE_CONFIG_DIR"
multi-claude exec bogus >/dev/null 2>&1; assert_rc $? 1

# ======================================================================================
echo "[T5] status"
printf '{"oauthAccount":{"emailAddress":"main@example.com","organizationName":"TestOrg"},"mcpServers":{"a":{"command":"a-main"},"b":{"command":"b"}}}\n' > "$HOME/.claude.json"
printf '{"oauthAccount":{"emailAddress":"alt@example.com","organizationName":"TestOrg"},"mcpServers":{"a":{"command":"a-alt"},"c":{"command":"c"}}}\n' > "$HOME/.claude-alt/.claude.json"
t "status table"
out="$(multi-claude status 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "claude 9.9.9"
if printf '%s' "$out" | grep -E '^main +~/.claude +yes +main@example.com +TestOrg +team' >/dev/null; then pass "main row"; else failt "main row wrong: $out"; fi
if printf '%s' "$out" | grep -E '^alt +~/.claude-alt +yes +alt@example.com +TestOrg +team' >/dev/null; then pass "alt row"; else failt "alt row wrong: $out"; fi
if printf '%s' "$out" | grep -E '^work +~/.claude-work +never-run' >/dev/null; then pass "work row"; else failt "work row wrong: $out"; fi

# ======================================================================================
echo "[T6] doctor"
t "doctor passes on a healthy install"
out="$(multi-claude doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "all checks passed"
assert_contains "$out" "wrapper defines claude() under bash"
[ "$have_zsh" -eq 1 ] && assert_contains "$out" "wrapper defines claude() under zsh"
t "doctor flags a missing symlink"
rm "$HOME/.claude-alt/settings.json"
out="$(multi-claude doctor 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "settings.json missing"
t "install repairs it"
rm "$HOME/.claude-work/hooks"                       # a profile that was added later, not at install time
out="$(multi-claude install --no-install --shell both 2>&1)"
assert_link "$HOME/.claude-alt/settings.json" "$HOME/.claude-shared/settings.json"
assert_link "$HOME/.claude-work/hooks" "$HOME/.claude-shared/hooks"
assert_eq "$(grep -v '^#' "$HOME/.claude-shared/profiles" | tr '\n' ' ')" "alt work " "no profile added or dropped"
assert_not_contains "$out" "log in the alt account"   # alt has been started: no login step for it
assert_contains "$out" "log in the work account"       # work never ran: it still needs one
multi-claude doctor >/dev/null 2>&1; assert_rc $? 0
t "doctor warns about ~/.claude/.claude.json"
touch "$HOME/.claude/.claude.json"
out="$(multi-claude doctor 2>&1)"; assert_contains "$out" "Never set that for main"
rm "$HOME/.claude/.claude.json"
t "doctor flags a hook whose script is missing"
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/hooks/nope.sh"}]}]}}\n' > "$HOME/.claude-shared/settings.json"
out="$(multi-claude doctor 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "hooks/nope.sh which does not exist"
printf '{}\n' > "$HOME/.claude-shared/settings.json"
t "doctor parses real-world hook and statusLine commands precisely"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.claude-shared/hooks/h.sh"; chmod +x "$HOME/.claude-shared/hooks/h.sh"
cat > "$HOME/.claude-shared/settings.json" <<'EOF'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"bash '$HOME/.claude/hooks/h.sh' session"},{"type":"command","command":"~/.claude/hooks/h.sh hook-stop"}]}]},
 "statusLine":{"type":"command","command":"CLAUDE_USER=\"$(jq -r '.oauthAccount.emailAddress // empty' ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json 2>/dev/null)\" PATH=$HOME/n/bin:$PATH $HOME/n/bin/claude-powerline"}}
EOF
out="$(multi-claude doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "statusLine references ~/n/bin/claude-powerline which does not exist"
assert_not_contains "$out" "}"
assert_not_contains "$out" ':$PATH'
assert_not_contains "$out" "h.sh which does not exist"
printf '{}\n' > "$HOME/.claude-shared/settings.json"; rm "$HOME/.claude-shared/hooks/h.sh"
t "doctor flags invalid settings.json"
printf '{oops\n' > "$HOME/.claude-shared/settings.json"
out="$(multi-claude doctor 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "not valid JSON"
printf '{}\n' > "$HOME/.claude-shared/settings.json"

# ======================================================================================
echo "[T7] sync-mcp"
t "sync-mcp main alt"
out="$(multi-claude sync-mcp main alt 2>&1)"; rc=$?
assert_rc "$rc" 0
merged="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["mcpServers"]; print(",".join(k+"="+v["command"] for k,v in sorted(d.items())))' "$HOME/.claude-alt/.claude.json")"
assert_eq "$merged" "a=a-main,b=b,c=c" "merged servers (source wins, extras kept)"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["oauthAccount"]["emailAddress"])' "$HOME/.claude-alt/.claude.json")" "alt@example.com" "other keys untouched"
assert_eq "$(find "$HOME/.claude-alt" -maxdepth 1 -name '.claude.json.bak-*' | wc -l | tr -d ' ')" "1" "backup written"
t "sync-mcp refuses when target never ran"
multi-claude sync-mcp main work >/dev/null 2>&1; assert_rc $? 1

# ======================================================================================
echo "[T8] link-memory"
mkdir -p "$SANDBOX/proj.x/sub"
t "link-memory"
out="$(multi-claude link-memory "$SANDBOX/proj.x/sub" alt 2>&1)"; rc=$?
assert_rc "$rc" 0
slug="$(printf '%s' "$SANDBOX/proj.x/sub" | sed 's/[^A-Za-z0-9]/-/g')"
assert_dir "$HOME/.claude/projects/$slug/memory"
assert_link "$HOME/.claude-alt/projects/$slug/memory" "$HOME/.claude/projects/$slug/memory"
t "link-memory moves existing alt notes when main is empty"
mkdir -p "$SANDBOX/proj2"; slug2="$(printf '%s' "$SANDBOX/proj2" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HOME/.claude-work/projects/$slug2/memory"; echo note > "$HOME/.claude-work/projects/$slug2/memory/MEMORY.md"
multi-claude link-memory "$SANDBOX/proj2" work >/dev/null 2>&1; assert_rc $? 0
assert_eq "$(cat "$HOME/.claude/projects/$slug2/memory/MEMORY.md" 2>/dev/null)" "note" "notes moved to main"
assert_link "$HOME/.claude-work/projects/$slug2/memory" "$HOME/.claude/projects/$slug2/memory"

# ======================================================================================
echo "[T9] adopt existing local config into the shared dir (second home)"
export HOME="$SANDBOX/home2"; mkdir -p "$HOME/.claude/hooks"
export PATH="$SHIM_CLAUDE:$SHIM_CURL:$SYS_PATH"
touch "$HOME/.zshrc"; export SHELL=/bin/zsh
printf '{"theme":"dark"}\n' > "$HOME/.claude/settings.json"
printf 'hello\n' > "$HOME/.claude/CLAUDE.md"
printf '#!/bin/sh\necho hi\n' > "$HOME/.claude/hooks/x.sh"
t "adopt"
out="$(bash "$SETUP" install --no-install 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "adopting existing ~/.claude/settings.json"
assert_eq "$(cat "$HOME/.claude-shared/settings.json")" '{"theme":"dark"}' "settings adopted"
assert_eq "$(cat "$HOME/.claude-shared/CLAUDE.md")" "hello" "CLAUDE.md adopted"
assert_file "$HOME/.claude-shared/hooks/x.sh"
assert_link "$HOME/.claude/settings.json" "$HOME/.claude-shared/settings.json"
assert_link "$HOME/.claude-alt/hooks" "$HOME/.claude-shared/hooks"
assert_count "$HOME/.zshrc" "# >>> multi-claude >>>" 1
assert_absent "$HOME/.bashrc"
t "shell auto picks the login shell rc only"
assert_eq "$(ls -A "$HOME" | grep -c 'rc$')" "1" "only .zshrc touched"

echo "[T10] conflicting local copy is backed up, never deleted"
rm "$HOME/.claude-alt/settings.json"; printf '{"theme":"light"}\n' > "$HOME/.claude-alt/settings.json"
rm "$HOME/.claude-alt/CLAUDE.md"; printf 'hello\n' > "$HOME/.claude-alt/CLAUDE.md"   # identical copy
t "conflict"
out="$(bash "$SETUP" install --no-install 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "differs from ~/.claude-shared/settings.json"
assert_contains "$out" "is identical to the shared copy"
assert_link "$HOME/.claude-alt/settings.json" "$HOME/.claude-shared/settings.json"
assert_link "$HOME/.claude-alt/CLAUDE.md" "$HOME/.claude-shared/CLAUDE.md"
assert_eq "$(find "$HOME/.claude-alt" -maxdepth 1 -name 'settings.json.bak-*' | wc -l | tr -d ' ')" "1" "backup of the differing copy"
assert_eq "$(cat "$HOME"/.claude-alt/settings.json.bak-*)" '{"theme":"light"}' "backup content intact"
assert_eq "$(cat "$HOME/.claude-shared/settings.json")" '{"theme":"dark"}' "shared copy untouched"
t "rc block refresh"
sed -i 's|^\[ -r "\$HOME/.claude-shared/claude-profiles.sh" \].*|# stale line|' "$HOME/.zshrc"
out="$(bash "$SETUP" install --no-install 2>&1)"
assert_contains "$out" "updated ~/.zshrc"
assert_count "$HOME/.zshrc" "# >>> multi-claude >>>" 1
assert_count "$HOME/.zshrc" '[ -r "$HOME/.claude-shared/claude-profiles.sh" ]' 1

# ======================================================================================
echo "[T11] dry-run changes nothing (third home)"
export HOME="$SANDBOX/home3"; mkdir -p "$HOME"; touch "$HOME/.bashrc"; export SHELL=/bin/bash
t "dry-run"
out="$(bash "$SETUP" install --dry-run 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "[dry-run]"
assert_absent "$HOME/.claude-shared"
assert_absent "$HOME/.claude"
assert_absent "$HOME/.claude-alt"
assert_absent "$HOME/.local/bin/multi-claude"
assert_eq "$(wc -c < "$HOME/.bashrc" | tr -d ' ')" "0" ".bashrc untouched"
t "version"
ver="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SETUP")"
assert_eq "$(bash "$SETUP" version)" "multi-claude v$ver" "version command"

# ======================================================================================
echo "[T12] export bundle on a source host, import on a target with a different HOME"
SRC="$SANDBOX/srchome"; mkdir -p "$SRC/.claude-shared/hooks" "$SRC/.claude-shared/skills" "$SRC/.claude-shared/__pycache__" "$SRC/proj/skill"
printf '#!/bin/sh\necho %s\n' "$SRC/.claude/hooks/h.sh" > "$SRC/.claude-shared/hooks/h.sh"; chmod +x "$SRC/.claude-shared/hooks/h.sh"
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"bash %s/.claude/hooks/h.sh"}]}]}}\n' "$SRC" > "$SRC/.claude-shared/settings.json"
printf 'rules for %s and see /home/someoneelse/notes.md\n' "$SRC" > "$SRC/.claude-shared/CLAUDE.md"
printf 'context7 rule mentions %s/.claude/hooks\n' "$SRC" > "$SRC/.claude-shared/rules.md"
ln -s "$SRC/proj/skill" "$SRC/.claude-shared/skills/proj-skill"
ln -s "$SRC/.claude-shared/hooks/h.sh" "$SRC/.claude-shared/skills/inner-link"
ln -s "$SRC/nowhere" "$SRC/.claude-shared/skills/dangling"
echo secret > "$SRC/.claude-shared/.credentials.json"
echo x > "$SRC/.claude-shared/__pycache__/a.pyc"
echo old > "$SRC/.claude-shared/settings.json.bak-1"
printf 'alt\n' > "$SRC/.claude-shared/profiles"; echo 'claude(){ :; }' > "$SRC/.claude-shared/claude-profiles.sh"
printf 'source=%s/clone\n' "$SRC" > "$SRC/.claude-shared/multi-claude.conf"
mkdir -p "$SRC/.claude-shared/sessions.off-1"; echo t > "$SRC/.claude-shared/sessions.off-1/9.abc.key"
t "export"
out="$(HOME="$SRC" bash "$EXPORT" -o "$SANDBOX/bundle.tgz" 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_file "$SANDBOX/bundle.tgz"
assert_contains "$out" "DANGLING"
listing="$(tar -tzf "$SANDBOX/bundle.tgz")"
assert_contains "$listing" "./hooks/h.sh"
assert_contains "$listing" ".bundle-meta"
assert_not_contains "$listing" ".credentials.json"
assert_not_contains "$listing" "__pycache__"
assert_not_contains "$listing" "settings.json.bak-1"
assert_not_contains "$listing" "./profiles"
assert_not_contains "$listing" "claude-profiles.sh"
assert_not_contains "$listing" "multi-claude.conf"
assert_not_contains "$listing" "sessions.off"
assert_contains "$out" "curl -fsSL https://raw.test/install.sh | bash -s -- --bundle ~/bundle.tgz"
t "export --help works without a script file to read"
out="$(HOME="$SRC" bash -s -- --help < "$EXPORT" 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "usage: export-shared-bundle.sh"
t "export refuses to overwrite"
HOME="$SRC" bash "$EXPORT" -o "$SANDBOX/bundle.tgz" >/dev/null 2>&1; assert_rc $? 1
t "export --dereference skips dangling links"
out="$(HOME="$SRC" bash "$EXPORT" --dereference -o "$SANDBOX/bundle-deref.tgz" 2>&1)"; rc=$?
assert_rc "$rc" 0
listing="$(tar -tzf "$SANDBOX/bundle-deref.tgz")"
assert_not_contains "$listing" "skills/dangling"
assert_contains "$listing" "./skills/inner-link"

export HOME="$SANDBOX/home4"; mkdir -p "$HOME"; touch "$HOME/.bashrc"
t "import with --bundle"
out="$(bash "$SETUP" install --no-install --bundle "$SANDBOX/bundle.tgz" 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "shared config seeded from bundle"
assert_file "$HOME/.claude-shared/hooks/h.sh"
assert_file "$HOME/.claude-shared/.bundle-meta"
assert_eq "$(cat "$HOME/.claude-shared/CLAUDE.md")" "rules for $SRC and see /home/someoneelse/notes.md" "Markdown prose left untouched"
assert_eq "$(cat "$HOME/.claude-shared/rules.md")" "context7 rule mentions $SRC/.claude/hooks" "rules.md left untouched"
assert_eq "$(bash -c '. "$HOME/.claude-shared/hooks/h.sh"')" "$HOME/.claude/hooks/h.sh" "script content rewritten"
assert_contains "$(cat "$HOME/.claude-shared/settings.json")" "bash $HOME/.claude/hooks/h.sh"
assert_not_contains "$(cat "$HOME/.claude-shared/settings.json")" "$SRC"
assert_eq "$(readlink "$HOME/.claude-shared/skills/proj-skill")" "$HOME/proj/skill" "outside symlink re-pointed"
assert_eq "$(readlink "$HOME/.claude-shared/skills/inner-link")" "$HOME/.claude-shared/hooks/h.sh" "inner symlink re-pointed"
assert_link "$HOME/.claude/hooks" "$HOME/.claude-shared/hooks"
assert_link "$HOME/.claude-alt/settings.json" "$HOME/.claude-shared/settings.json"
[ -x "$HOME/.claude-shared/hooks/h.sh" ] && pass "hook still executable" || failt "hook lost its mode"
t "doctor after import: hook resolves, dangling links only warn"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "dangling symlink ~/.claude-shared/skills/proj-skill"
assert_contains "$out" "~/.claude-shared/CLAUDE.md contains an absolute path under another user's home"
assert_not_contains "$out" "settings.json contains an absolute path"
assert_not_contains "$out" "FAIL"
t "import over a non-empty shared dir keeps a backup"
echo local > "$HOME/.claude-shared/rules/local.md"
(umask 077; echo token > "$HOME/.claude-shared/sessions/7.abc.key")   # a live peer token
out="$(bash "$SETUP" install --no-install --bundle "$SANDBOX/bundle.tgz" 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_eq "$(ls -d "$HOME"/.claude-shared.bak-* | wc -l | tr -d ' ')" "1" "shared backup"
assert_file "$HOME/.claude-shared/rules/local.md"
assert_file "$(ls -d "$HOME"/.claude-shared.bak-*)/rules/local.md"
assert_absent "$(ls -d "$HOME"/.claude-shared.bak-*)/sessions"       # the backup never duplicates peer tokens
assert_file "$HOME/.claude-shared/sessions/7.abc.key"
t "import refuses a bundle with credentials"
mkdir -p "$SANDBOX/bad"; echo s > "$SANDBOX/bad/.credentials.json"; tar -czf "$SANDBOX/bad.tgz" -C "$SANDBOX/bad" .
bash "$SETUP" install --no-install --bundle "$SANDBOX/bad.tgz" >/dev/null 2>&1; assert_rc $? 1
t "import never takes another host's multi-claude.conf"
mkdir -p "$SANDBOX/confb"; printf 'source=/elsewhere\nsessions=per-account\n' > "$SANDBOX/confb/multi-claude.conf"; echo x > "$SANDBOX/confb/extra.md"
tar -czf "$SANDBOX/confb.tgz" -C "$SANDBOX/confb" .
bash "$SETUP" install --no-install --bundle "$SANDBOX/confb.tgz" >/dev/null 2>&1; assert_rc $? 0
assert_file "$HOME/.claude-shared/extra.md"
assert_eq "$(cat "$HOME/.claude-shared/multi-claude.conf" | grep -v '^#')" "source=download" "host state untouched by the bundle"
assert_link "$HOME/.claude/sessions" "$HOME/.claude-shared/sessions"

# ======================================================================================
echo "[T13] misc CLI"
t "help"; bash "$SETUP" help >/dev/null 2>&1; assert_rc $? 0
t "no args exits 1"; bash "$SETUP" >/dev/null 2>&1; assert_rc $? 1
t "unknown command"; bash "$SETUP" bogus >/dev/null 2>&1; assert_rc $? 1
t "unknown install option"; bash "$SETUP" install --bogus >/dev/null 2>&1; assert_rc $? 1
t "print-wrapper without install"
export HOME="$SANDBOX/home5"; mkdir -p "$HOME"
out="$(bash "$SETUP" print-wrapper 2>&1)"; assert_contains "$out" "claude() {"
assert_absent "$HOME/.claude-shared"
t "wrapper file passes shellcheck for bash and zsh-ish sh"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s bash -e SC2148,SC2139 "$SANDBOX/home/.claude-shared/claude-profiles.sh"; then pass; else failt "wrapper shellcheck"; fi
else pass "skipped"; fi

# ======================================================================================
echo "[T14] opting out at install, then share-sessions on a host with per-account registries (sixth home)"
export HOME="$SANDBOX/home6"; mkdir -p "$HOME"; touch "$HOME/.bashrc"; export SHELL=/bin/bash
export PATH="$SHIM_CLAUDE:$SHIM_CURL:$SYS_PATH"
CONF="$HOME/.claude-shared/multi-claude.conf"
bash "$SETUP" install --no-install --no-share-sessions --profiles alt,work >/dev/null 2>&1 || failt "install for T14 failed"
# fake live registries as Claude Code writes them: <pid>.json + <pid>.<hash>.key (0600)
mkdir -m 0700 "$HOME/.claude/sessions" "$HOME/.claude-alt/sessions"
printf '{"pid":111,"name":"main-a"}\n' > "$HOME/.claude/sessions/111.json"
(umask 077; printf '{"peerToken":"x"}\n' > "$HOME/.claude/sessions/111.abc.key")
printf '{"pid":222,"name":"alt-b"}\n' > "$HOME/.claude-alt/sessions/222.json"
(umask 077; printf '{"peerToken":"y"}\n' > "$HOME/.claude-alt/sessions/222.def.key")
t "install --no-share-sessions keeps one registry per account and records the choice"
assert_absent "$HOME/.claude-shared/sessions"
assert_eq "$(grep '^sessions=' "$CONF")" "sessions=per-account" "opt-out recorded"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "peer-session registry per account, as chosen"
out="$(bash "$SETUP" status 2>&1)"; assert_contains "$out" "peer sessions: per account"
t "a later plain install (what update runs) respects the opt-out"
out="$(bash "$SETUP" install --no-install 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "one registry per account (opted out)"
assert_absent "$HOME/.claude-shared/sessions"
assert_dir "$HOME/.claude/sessions"
assert_file "$HOME/.claude-alt/sessions/222.json"
t "add-profile on an opted-out host does not link a registry"
bash "$SETUP" add-profile solo >/dev/null 2>&1; assert_rc $? 0
assert_absent "$HOME/.claude-solo/sessions"
t "share-sessions --dry-run changes nothing"
out="$(bash "$SETUP" share-sessions --dry-run 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "[dry-run]"
assert_absent "$HOME/.claude-shared/sessions"
assert_dir "$HOME/.claude/sessions"
assert_file "$HOME/.claude-alt/sessions/222.json"
t "share-sessions"
out="$(bash "$SETUP" share-sessions 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_not_contains "$out" " warn "
assert_dir "$HOME/.claude-shared/sessions"
assert_eq "$(stat -c %a "$HOME/.claude-shared/sessions")" "700" "shared registry mode 0700"
for p in .claude .claude-alt .claude-work .claude-solo; do assert_link "$HOME/$p/sessions" "$HOME/.claude-shared/sessions"; done
for f in 111.json 111.abc.key 222.json 222.def.key; do assert_file "$HOME/.claude-shared/sessions/$f"; done
assert_eq "$(grep -c '^sessions=' "$CONF")" "0" "opt-out cleared"
assert_eq "$(stat -c %a "$HOME/.claude-shared/sessions/222.def.key")" "600" "peer token keeps mode 0600"
assert_eq "$(cat "$HOME/.claude-shared/sessions/222.json")" '{"pid":222,"name":"alt-b"}' "entry content intact"
assert_eq "$(find "$HOME" -maxdepth 2 -name 'sessions.bak-*' | wc -l | tr -d ' ')" "0" "emptied dirs need no backup"
t "a session writing through its own profile path lands in the shared registry"
printf '{"pid":333}\n' > "$HOME/.claude-work/sessions/333.json"
assert_file "$HOME/.claude-shared/sessions/333.json"
assert_eq "$(ls "$HOME/.claude/sessions" | sort | tr '\n' ' ')" "111.abc.key 111.json 222.def.key 222.json 333.json " "main lists every account's entries"
t "idempotent"
out="$(bash "$SETUP" share-sessions 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_not_contains "$out" "moved"
assert_not_contains "$out" " warn "
t "add-profile after sharing joins automatically"
bash "$SETUP" add-profile ci >/dev/null 2>&1; assert_rc $? 0
assert_link "$HOME/.claude-ci/sessions" "$HOME/.claude-shared/sessions"
t "re-running install keeps sharing on"
out="$(bash "$SETUP" install --no-install --profiles alt,work 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "one registry for every account"
assert_link "$HOME/.claude-alt/sessions" "$HOME/.claude-shared/sessions"
t "install --no-share-sessions on a shared host changes nothing and points at unshare-sessions"
out="$(bash "$SETUP" install --no-install --no-share-sessions 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "--no-share-sessions ignored"
assert_contains "$out" "multi-claude unshare-sessions"
assert_link "$HOME/.claude-alt/sessions" "$HOME/.claude-shared/sessions"
assert_eq "$(grep -c '^sessions=' "$CONF")" "0" "no opt-out recorded"
t "doctor and status report sharing"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "peer-session registry shared at ~/.claude-shared/sessions"
out="$(bash "$SETUP" status 2>&1)"; assert_contains "$out" "peer sessions: shared across accounts"
t "doctor fails when a profile drops out of the shared registry"
rm "$HOME/.claude-alt/sessions"; mkdir "$HOME/.claude-alt/sessions"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "profile 'alt': ~/.claude-alt/sessions is not linked to the shared registry"
t "share-sessions repairs it and never overwrites a shared entry"
printf '{"pid":111,"stale":true}\n' > "$HOME/.claude-alt/sessions/111.json"   # same pid as a shared entry
printf '{"pid":444}\n' > "$HOME/.claude-alt/sessions/444.json"
out="$(bash "$SETUP" share-sessions 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "already exist in the shared registry"
assert_link "$HOME/.claude-alt/sessions" "$HOME/.claude-shared/sessions"
assert_eq "$(cat "$HOME/.claude-shared/sessions/111.json")" '{"pid":111,"name":"main-a"}' "shared entry untouched"
assert_file "$HOME/.claude-shared/sessions/444.json"
assert_eq "$(find "$HOME/.claude-alt" -maxdepth 1 -name 'sessions.bak-*' | wc -l | tr -d ' ')" "1" "conflicting local dir kept as backup"
assert_eq "$(cat "$HOME"/.claude-alt/sessions.bak-*/111.json)" '{"pid":111,"stale":true}' "backup content intact"
t "doctor warns about a wrong mode on the shared registry"
chmod 0755 "$HOME/.claude-shared/sessions"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "has mode 755, expected 0700"
t "share-sessions restores the mode"
bash "$SETUP" share-sessions >/dev/null 2>&1
assert_eq "$(stat -c %a "$HOME/.claude-shared/sessions")" "700" "mode restored"
t "export never packs the registry"
out="$(bash "$EXPORT" -o "$SANDBOX/bundle-sessions.tgz" 2>&1)"; rc=$?
assert_rc "$rc" 0
listing="$(tar -tzf "$SANDBOX/bundle-sessions.tgz")"
assert_not_contains "$listing" "sessions/"
assert_not_contains "$listing" ".key"
t "import refuses a bundle carrying peer tokens"
mkdir -p "$SANDBOX/badsess/sessions"; echo t > "$SANDBOX/badsess/sessions/1.abc.key"; tar -czf "$SANDBOX/badsess.tgz" -C "$SANDBOX/badsess" .
bash "$SETUP" install --no-install --bundle "$SANDBOX/badsess.tgz" >/dev/null 2>&1; assert_rc $? 1
t "an unregistered ~/.claude-<name> dir is reported and left alone"
mkdir -p "$HOME/.claude-hand/sessions"; echo '{}' > "$HOME/.claude-hand/.claude.json"; echo '{"pid":555}' > "$HOME/.claude-hand/sessions/555.json"
out="$(bash "$SETUP" share-sessions 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "~/.claude-hand holds an account but is not a registered profile"
assert_dir "$HOME/.claude-hand/sessions"
out="$(bash "$SETUP" doctor 2>&1)"; assert_contains "$out" "~/.claude-hand holds an account but is not a registered profile"
t "registering it brings it in"
bash "$SETUP" add-profile hand >/dev/null 2>&1; assert_rc $? 0
assert_link "$HOME/.claude-hand/sessions" "$HOME/.claude-shared/sessions"
assert_file "$HOME/.claude-shared/sessions/555.json"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?; assert_rc "$rc" 0; assert_not_contains "$out" "not a registered profile"
t "share-sessions before install refuses"
HOME="$SANDBOX/home-none" bash "$SETUP" share-sessions >/dev/null 2>&1; assert_rc $? 1

echo "[T15] sharing is the default on a fresh home (seventh home)"
export HOME="$SANDBOX/home7"; mkdir -p "$HOME"; touch "$HOME/.bashrc"
CONF="$HOME/.claude-shared/multi-claude.conf"
t "plain install shares the registry"
out="$(bash "$SETUP" install --no-install --profiles alt 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "one registry for every account"
assert_dir "$HOME/.claude-shared/sessions"
assert_eq "$(stat -c %a "$HOME/.claude-shared/sessions")" "700" "mode 0700"
assert_link "$HOME/.claude/sessions" "$HOME/.claude-shared/sessions"
assert_link "$HOME/.claude-alt/sessions" "$HOME/.claude-shared/sessions"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "peer-session registry shared at ~/.claude-shared/sessions"
t "install --dry-run on an untouched home creates nothing"
out="$(HOME="$SANDBOX/home8" bash -c 'mkdir -p "$HOME"; touch "$HOME/.bashrc"; bash "$1" install --no-install --dry-run' _ "$SETUP" 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "[dry-run]"
assert_absent "$SANDBOX/home8/.claude-shared"
assert_absent "$SANDBOX/home8/.claude"

echo "[T16] unshare-sessions: back to one registry per account (seventh home)"
# Two running "sessions": real processes whose environment says which account they belong
# to, exactly what a session started through the wrapper looks like. Plus one entry whose
# process is gone and one file that is not a registry entry at all.
reg="$HOME/.claude-shared/sessions"
sleep 300 & pid_main=$!
CLAUDE_CONFIG_DIR="$HOME/.claude-alt" sleep 300 & pid_alt=$!
BG_PIDS="$BG_PIDS $pid_main $pid_alt"; disown "$pid_main" "$pid_alt" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do   # until both have exec'ed, so their environment is final
  [ "$(cat "/proc/$pid_main/comm" 2>/dev/null)" = sleep ] && [ "$(cat "/proc/$pid_alt/comm" 2>/dev/null)" = sleep ] && break
  sleep 0.2
done
printf '{"pid":%s,"name":"main-live"}\n' "$pid_main" > "$reg/$pid_main.json"; (umask 077; echo k1 > "$reg/$pid_main.aaa.key")
printf '{"pid":%s,"name":"alt-live"}\n' "$pid_alt" > "$reg/$pid_alt.json";   (umask 077; echo k2 > "$reg/$pid_alt.bbb.key")
printf '{"pid":999999999,"name":"gone"}\n' > "$reg/999999999.json"
echo note > "$reg/notes.txt"
t "unshare-sessions --dry-run changes nothing"
out="$(bash "$SETUP" unshare-sessions --dry-run 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "[dry-run]"
assert_link "$HOME/.claude/sessions" "$HOME/.claude-shared/sessions"
assert_file "$reg/$pid_alt.json"
assert_eq "$(grep -c '^sessions=' "$CONF")" "0" "nothing recorded"
t "unshare-sessions"
out="$(bash "$SETUP" unshare-sessions 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_not_contains "$out" " warn "
for p in .claude .claude-alt; do
  assert_dir "$HOME/$p/sessions"
  assert_eq "$(stat -c %a "$HOME/$p/sessions")" "700" "$p/sessions mode 0700"
done
t "running sessions get their entries back, each in its own account"
assert_contains "$out" "handed 4 registry file(s) of running sessions back"
assert_eq "$(ls "$HOME/.claude/sessions" | sort | tr '\n' ' ')" "$pid_main.aaa.key $pid_main.json " "main's session is back in ~/.claude/sessions"
assert_eq "$(ls "$HOME/.claude-alt/sessions" | sort | tr '\n' ' ')" "$pid_alt.bbb.key $pid_alt.json " "alt's session is back in ~/.claude-alt/sessions"
assert_eq "$(stat -c %a "$HOME/.claude-alt/sessions/$pid_alt.bbb.key")" "600" "peer token keeps mode 0600"
assert_eq "$(cat "$HOME/.claude-alt/sessions/$pid_alt.json")" "{\"pid\":$pid_alt,\"name\":\"alt-live\"}" "entry content intact"
t "what belongs to no running session is kept aside, not deleted"
assert_absent "$HOME/.claude-shared/sessions"
assert_eq "$(ls -d "$HOME"/.claude-shared/sessions.off-* | wc -l | tr -d ' ')" "1" "one retired registry"
assert_eq "$(ls "$HOME"/.claude-shared/sessions.off-* | sort | tr '\n' ' ')" "999999999.json notes.txt " "stale entry and stray file kept"
t "the choice is recorded and reported"
assert_eq "$(grep '^sessions=' "$CONF")" "sessions=per-account" "opt-out recorded"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "peer-session registry per account, as chosen"
out="$(bash "$SETUP" status 2>&1)"; assert_contains "$out" "peer sessions: per account"
t "install keeps the registries apart afterwards"
bash "$SETUP" install --no-install >/dev/null 2>&1; assert_rc $? 0
assert_dir "$HOME/.claude-alt/sessions"
assert_absent "$HOME/.claude-shared/sessions"
t "unshare-sessions again is a no-op"
out="$(bash "$SETUP" unshare-sessions 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "already per account"
t "export never packs a retired registry"
bash "$EXPORT" -o "$SANDBOX/bundle-off.tgz" >/dev/null 2>&1; assert_rc $? 0
assert_not_contains "$(tar -tzf "$SANDBOX/bundle-off.tgz")" "sessions"
t "share-sessions switches it back on and carries the running sessions over"
out="$(bash "$SETUP" share-sessions 2>&1)"; rc=$?
assert_rc "$rc" 0
for p in .claude .claude-alt; do assert_link "$HOME/$p/sessions" "$HOME/.claude-shared/sessions"; done
assert_eq "$(ls "$HOME/.claude-shared/sessions" | sort | tr '\n' ' ')" "$(printf '%s\n' "$pid_main.aaa.key" "$pid_main.json" "$pid_alt.bbb.key" "$pid_alt.json" | sort | tr '\n' ' ')" "both accounts' sessions in one registry"
assert_eq "$(grep -c '^sessions=' "$CONF")" "0" "opt-out cleared"
t "unshare-sessions with nothing stale leaves no directory behind"
bash "$SETUP" unshare-sessions >/dev/null 2>&1; assert_rc $? 0
assert_absent "$HOME/.claude-shared/sessions"
assert_eq "$(ls -d "$HOME"/.claude-shared/sessions.off-* | wc -l | tr -d ' ')" "1" "no second retired registry"
assert_file "$HOME/.claude/sessions/$pid_main.json"
t "a host from before sharing was the default: doctor nudges, the next install switches it on"
sed -i '/^sessions=/d' "$CONF"
out="$(bash "$SETUP" doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "peer-session registry is still per account"
out="$(bash "$SETUP" install --no-install 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "one registry for every account"
assert_link "$HOME/.claude-alt/sessions" "$HOME/.claude-shared/sessions"
assert_file "$HOME/.claude-shared/sessions/$pid_alt.json"
t "unshare-sessions before install refuses"
HOME="$SANDBOX/home-none" bash "$SETUP" unshare-sessions >/dev/null 2>&1; assert_rc $? 1
kill "$pid_main" "$pid_alt" 2>/dev/null

# ======================================================================================
echo "[T17] a host that still has the old claude-profiles command (ninth home)"
export HOME="$SANDBOX/home9"; mkdir -p "$HOME/.local/bin"; touch "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$SHIM_CLAUDE:$SHIM_CURL:$SYS_PATH"
sed 's/^VERSION=.*/VERSION="1.0.0"/' "$SETUP" > "$HOME/.local/bin/claude-profiles"; chmod +x "$HOME/.local/bin/claude-profiles"   # what 1.0 left behind
t "install turns the old copy into an alias of multi-claude"
out="$(bash "$SETUP" install --no-install 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_not_contains "$out" " warn "
assert_file "$HOME/.local/bin/multi-claude"
assert_link "$HOME/.local/bin/claude-profiles" "multi-claude"
assert_eq "$(claude-profiles version)" "multi-claude v$ver" "the old name runs the new version"
claude-profiles status >/dev/null 2>&1; assert_rc $? 0
t "running install through the alias is quiet and keeps it"
out="$(claude-profiles install --no-install 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_not_contains "$out" " warn "
assert_link "$HOME/.local/bin/claude-profiles" "multi-claude"
assert_eq "$(grep '^source=' "$HOME/.claude-shared/multi-claude.conf")" "source=download" "re-running the installed copy keeps the recorded source"
t "an unrelated file with the old name is left alone"
export HOME="$SANDBOX/home10"; mkdir -p "$HOME/.local/bin"; touch "$HOME/.bashrc"
printf '#!/bin/sh\necho mine\n' > "$HOME/.local/bin/claude-profiles"
out="$(bash "$SETUP" install --no-install 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "is not a copy of this script; left alone"
assert_eq "$(cat "$HOME/.local/bin/claude-profiles")" $'#!/bin/sh\necho mine' "file untouched"

# ======================================================================================
echo "[T18] install.sh: install without a clone (homes 11-13)"
export HOME="$SANDBOX/home11"; mkdir -p "$HOME"; touch "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$SHIM_CLAUDE:$SHIM_CURL:$SYS_PATH"
CONF="$HOME/.claude-shared/multi-claude.conf"
t "fails cleanly when the download fails"
out="$(sh "$INSTALL" --no-install 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "download failed: https://raw.test/setup-multi-claude.sh"
assert_absent "$HOME/.claude-shared"
t "refuses a download that is not the script (an error page)"
printf '<html>sign in to continue</html>\n' > "$SERVE/setup-multi-claude.sh"
out="$(sh "$INSTALL" --no-install 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "not a valid setup-multi-claude.sh"
assert_absent "$HOME/.claude-shared"
t "refuses a download that was cut short"
sed '/^cmd_install() {/q' "$SETUP" > "$SERVE/setup-multi-claude.sh"
out="$(sh "$INSTALL" --no-install 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "not a valid setup-multi-claude.sh"
assert_absent "$HOME/.claude-shared"
assert_absent "$HOME/.local/bin/multi-claude"
t "installs, passing its options on to install"
cp "$SETUP" "$SERVE/setup-multi-claude.sh"
out="$(sh "$INSTALL" --no-install --profiles alt,work 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "downloading https://raw.test/setup-multi-claude.sh"
assert_not_contains "$out" "FAIL"
assert_file "$HOME/.local/bin/multi-claude"
if cmp -s "$SETUP" "$HOME/.local/bin/multi-claude"; then pass "the command is the downloaded script"; else failt "installed command differs from the download"; fi
assert_eq "$(grep -v '^#' "$HOME/.claude-shared/profiles" | tr '\n' ' ')" "alt work " "profiles from --profiles"
for p in .claude .claude-alt .claude-work; do
  assert_link "$HOME/$p/settings.json" "$HOME/.claude-shared/settings.json"
  assert_link "$HOME/$p/sessions" "$HOME/.claude-shared/sessions"
done
assert_eq "$(grep '^source=' "$CONF")" "source=download" "update source: download"
assert_eq "$(find "$TMPDIR" -maxdepth 1 -name 'multi-claude-install.*' | wc -l | tr -d ' ')" "0" "temporary download removed"
multi-claude doctor >/dev/null 2>&1; assert_rc $? 0
t "works piped into bash and into sh, the way the one-liner runs it"
for sh in bash sh; do
  out="$(HOME="$SANDBOX/home12-$sh" bash -c 'mkdir -p "$HOME"; touch "$HOME/.bashrc"; "$1" -s -- --no-install < "$2"' _ "$sh" "$INSTALL" 2>&1)"; rc=$?
  assert_rc "$rc" 0
  assert_file "$SANDBOX/home12-$sh/.local/bin/multi-claude"
  assert_link "$SANDBOX/home12-$sh/.claude-alt/sessions" "$SANDBOX/home12-$sh/.claude-shared/sessions"
done
t "--dry-run through install.sh touches nothing"
out="$(HOME="$SANDBOX/home13" bash -c 'mkdir -p "$HOME"; touch "$HOME/.bashrc"; sh "$1" --dry-run' _ "$INSTALL" 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "[dry-run]"
assert_absent "$SANDBOX/home13/.claude-shared"
assert_absent "$SANDBOX/home13/.local/bin/multi-claude"

echo "[T19] update by download (home 11)"
printf '{"oauthAccount":{"emailAddress":"alt@example.com"}}\n' > "$HOME/.claude-alt/.claude.json"
(umask 077; echo secret > "$HOME/.claude-alt/.credentials.json")
t "nothing new: says so and changes nothing"
out="$(multi-claude update 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "already up to date (v$ver)"
t "update --dry-run only prints the plan"
sed 's/^VERSION=.*/VERSION="9.9.9"/' "$SETUP" > "$SERVE/setup-multi-claude.sh"
out="$(multi-claude update --dry-run 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "[dry-run] download https://raw.test/setup-multi-claude.sh"
assert_eq "$(multi-claude version)" "multi-claude v$ver" "still the old version"
t "a new version is downloaded, installed and re-applied"
rm "$HOME/.claude-work/settings.json"          # damage that the re-applied install has to repair
tmp_before="$(ls -A "$TMPDIR" | sort)"
out="$(multi-claude update 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "updating from https://raw.test"
assert_contains "$out" "v$ver -> v9.9.9"
assert_contains "$out" "multi-claude setup v9.9.9"
assert_not_contains "$out" "FAIL"
assert_eq "$(multi-claude version)" "multi-claude v9.9.9" "the command is the new version"
assert_link "$HOME/.claude-work/settings.json" "$HOME/.claude-shared/settings.json"
assert_eq "$(grep -v '^#' "$HOME/.claude-shared/profiles" | tr '\n' ' ')" "alt work " "profiles neither added nor dropped"
assert_eq "$(cat "$HOME/.claude-alt/.credentials.json")" "secret" "login untouched"
assert_eq "$(cat "$HOME/.claude-alt/.claude.json")" '{"oauthAccount":{"emailAddress":"alt@example.com"}}' "account state untouched"
assert_eq "$(ls -A "$TMPDIR" | sort)" "$tmp_before" "no temporary files left behind"
assert_eq "$(find "$HOME/.local/bin" -name 'multi-claude.new.*' | wc -l | tr -d ' ')" "0" "no half-written command left behind"
t "updating again is a no-op"
out="$(multi-claude update 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "already up to date (v9.9.9)"
t "a broken download never replaces the working command"
sum_before="$(cksum < "$HOME/.local/bin/multi-claude")"
sed '/^cmd_install() {/q' "$SETUP" > "$SERVE/setup-multi-claude.sh"
out="$(multi-claude update 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "not a valid setup-multi-claude.sh (nothing was changed)"
assert_eq "$(cksum < "$HOME/.local/bin/multi-claude")" "$sum_before" "command untouched"
t "a failed download changes nothing"
rm "$SERVE/setup-multi-claude.sh"
out="$(multi-claude update 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "download failed"
assert_eq "$(cksum < "$HOME/.local/bin/multi-claude")" "$sum_before" "command untouched"
assert_eq "$(multi-claude version)" "multi-claude v9.9.9" "still works"
t "update rejects options it does not know"
multi-claude update --bogus >/dev/null 2>&1; assert_rc $? 1

# ======================================================================================
echo "[T20] update when installed from a git clone (home 14)"
if command -v git >/dev/null 2>&1; then
  export HOME="$SANDBOX/home14"; mkdir -p "$HOME"; touch "$HOME/.bashrc"
  export PATH="$HOME/.local/bin:$SHIM_CLAUDE:$SHIM_CURL:$SYS_PATH"
  CONF="$HOME/.claude-shared/multi-claude.conf"
  g() { git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=master "$@"; }
  ORIGIN="$SANDBOX/origin.git"; PUB="$SANDBOX/publisher"; CLONE="$HOME/apps/multi-claude"
  publish() {   # publish VERSION : a new commit on the origin with that version
    sed "s/^VERSION=.*/VERSION=\"$1\"/" "$SETUP" > "$PUB/setup-multi-claude.sh"
    g -C "$PUB" add -A && g -C "$PUB" commit -q -m "v$1" && g -C "$PUB" push -q origin HEAD:master
  }
  g init -q --bare "$ORIGIN" && g clone -q "$ORIGIN" "$PUB" 2>/dev/null && publish "$ver" 2>/dev/null && g clone -q "$ORIGIN" "$CLONE" \
    || failt "could not build the sandbox repositories"
  t "install from a clone records the clone as the update source"
  out="$(bash "$CLONE/setup-multi-claude.sh" install --no-install 2>&1)"; rc=$?
  assert_rc "$rc" 0
  assert_eq "$(grep '^source=' "$CONF")" "source=$CLONE" "update source: the clone"
  out="$(multi-claude doctor 2>&1)"; assert_contains "$out" "'multi-claude update' pulls the clone ~/apps/multi-claude"
  t "nothing new upstream"
  out="$(multi-claude update 2>&1)"; rc=$?
  assert_rc "$rc" 0
  assert_contains "$out" "updating from the clone ~/apps/multi-claude"
  assert_contains "$out" "already up to date (v$ver)"
  t "update --dry-run only prints the plan"
  out="$(multi-claude update --dry-run 2>&1)"; rc=$?
  assert_rc "$rc" 0
  assert_contains "$out" "[dry-run] git -C $CLONE pull --ff-only"
  t "update pulls the clone and re-applies the new version"
  publish 9.9.9 2>/dev/null
  out="$(multi-claude update 2>&1)"; rc=$?
  assert_rc "$rc" 0
  assert_contains "$out" "multi-claude setup v9.9.9"
  assert_eq "$(multi-claude version)" "multi-claude v9.9.9" "the command is the new version"
  assert_eq "$(bash "$CLONE/setup-multi-claude.sh" version)" "multi-claude v9.9.9" "the clone was fast-forwarded"
  assert_eq "$(grep '^source=' "$CONF")" "source=$CLONE" "still updates from the clone"
  t "a clone pulled by hand: update still refreshes the installed command"
  publish 9.9.10 2>/dev/null; g -C "$CLONE" pull -q --ff-only 2>/dev/null
  out="$(bash "$CLONE/setup-multi-claude.sh" update 2>&1)"; rc=$?
  assert_rc "$rc" 0
  assert_eq "$(multi-claude version)" "multi-claude v9.9.10" "installed copy caught up with the clone"
  t "update stops, changing nothing, when the clone cannot fast-forward"
  echo local > "$CLONE/local.txt"; g -C "$CLONE" add -A; g -C "$CLONE" commit -q -m local
  publish 9.9.11 2>/dev/null
  out="$(multi-claude update 2>&1)"; rc=$?
  assert_rc "$rc" 1
  assert_contains "$out" "git pull failed in ~/apps/multi-claude"
  assert_eq "$(multi-claude version)" "multi-claude v9.9.10" "command untouched"
  t "when the clone is gone, update says so and downloads instead"
  mv "$CLONE" "$SANDBOX/clone-moved-away"
  sed 's/^VERSION=.*/VERSION="9.9.12"/' "$SETUP" > "$SERVE/setup-multi-claude.sh"
  out="$(multi-claude update 2>&1)"; rc=$?
  assert_rc "$rc" 0
  assert_contains "$out" "is gone; downloading instead"
  assert_eq "$(multi-claude version)" "multi-claude v9.9.12" "updated by download"
  assert_eq "$(grep '^source=' "$CONF")" "source=download" "update source is now the download"
else
  t "git"; pass "skipped (no git)"
fi

# ======================================================================================
echo "[T21] the suite stayed inside the sandbox"
t "no install ever recorded a location outside the sandbox as its update source"
outside="$(cat "$SANDBOX"/home*/.claude-shared/multi-claude.conf 2>/dev/null | grep '^source=' | grep -v '^source=download$' | grep -v "^source=$SANDBOX/" || true)"
assert_eq "$outside" "" "sources"

# ======================================================================================
echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
