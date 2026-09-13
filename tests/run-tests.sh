#!/usr/bin/env bash
# Sandboxed tests for setup-multi-claude.sh and export-shared-bundle.sh.
#
# Everything runs under a throwaway HOME inside a mktemp sandbox. The real `claude` binary
# and the network are replaced by shims (a fake `claude` that echoes how it was called, and
# a fake `curl` that serves a fake installer). The harness refuses to run if HOME is not
# inside the sandbox, so it can never touch the real ~/.claude, ~/.claude-alt or rc files.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SETUP="$ROOT/setup-multi-claude.sh"
EXPORT="$ROOT/export-shared-bundle.sh"
KEEP="${KEEP_SANDBOX:-0}"

REAL_HOME="$HOME"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/multi-claude-test.XXXXXX")"
cleanup() { [ "$KEEP" = 1 ] && { echo "sandbox kept at $SANDBOX"; return; }; rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---- sandbox guard: never run against a real home -------------------------------------
export HOME="$SANDBOX/home"
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$HOME" "$TMPDIR"
case "$HOME" in "$SANDBOX"/*) ;; *) echo "refusing to run: HOME=$HOME is outside the sandbox"; exit 1 ;; esac
[ "$HOME" != "$REAL_HOME" ] || { echo "refusing to run: HOME is the real home"; exit 1; }
unset CLAUDE_CONFIG_DIR
export SHELL=/bin/bash

# ---- shims ----------------------------------------------------------------------------
SHIM_CURL="$SANDBOX/shim-curl"; SHIM_CLAUDE="$SANDBOX/shim-claude"
mkdir -p "$SHIM_CURL" "$SHIM_CLAUDE"
SYS_PATH="/usr/local/bin:/usr/bin:/bin"

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
# fake curl: only serves the Claude installer to -o FILE; anything else is an error
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
case "\$url" in *install.sh) ;; *) echo "fake curl: unexpected url \$url" >&2; exit 99 ;; esac
[ -n "\$out" ] || { echo "fake curl: expected -o FILE" >&2; exit 99; }
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
else pass "skipped (no shellcheck)"; fi
t "bash -n"; if bash -n "$SETUP" && bash -n "$EXPORT"; then pass; else failt "syntax error"; fi

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
assert_file "$HOME/.local/bin/claude-profiles"
[ -x "$HOME/.local/bin/claude-profiles" ] && pass "claude-profiles executable" || failt "claude-profiles not executable"

# from here on the installed fake claude is on PATH (as it would be after the installer)
export PATH="$HOME/.local/bin:$SHIM_CURL:$SYS_PATH"

echo "[T2] re-running install is a no-op"
t "idempotent"
out="$(claude-profiles install --profiles alt --shell both --no-install 2>&1)"; rc=$?
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
out="$(claude-profiles add-profile work 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_link "$HOME/.claude-work/settings.json" "$HOME/.claude-shared/settings.json"
assert_eq "$(grep -v '^#' "$HOME/.claude-shared/profiles" | tr '\n' ' ')" "alt work " "registry has both"
assert_eq "$(via bash 'claude work --x')" "CONFIG_DIR=$HOME/.claude-work"$'\nARGC=1\nARG=[--x]' "new profile routed"
t "add-profile rejects bad names"
claude-profiles add-profile 'Bad Name' >/dev/null 2>&1; assert_rc $? 1
claude-profiles add-profile main >/dev/null 2>&1; assert_rc $? 1
claude-profiles add-profile shared >/dev/null 2>&1; assert_rc $? 1
claude-profiles add-profile -x >/dev/null 2>&1; assert_rc $? 1
assert_eq "$(grep -cv '^#' "$HOME/.claude-shared/profiles")" "2" "registry unchanged after rejects"
t "exec runs a profile without the shell function"
assert_eq "$(claude-profiles exec alt --x)" "CONFIG_DIR=$HOME/.claude-alt"$'\nARGC=1\nARG=[--x]' "exec alt"
assert_eq "$(CLAUDE_CONFIG_DIR=/elsewhere claude-profiles exec main)" $'CONFIG_DIR=<unset>\nARGC=0' "exec main clears an inherited CLAUDE_CONFIG_DIR"
claude-profiles exec bogus >/dev/null 2>&1; assert_rc $? 1

# ======================================================================================
echo "[T5] status"
printf '{"oauthAccount":{"emailAddress":"main@example.com","organizationName":"TestOrg"},"mcpServers":{"a":{"command":"a-main"},"b":{"command":"b"}}}\n' > "$HOME/.claude.json"
printf '{"oauthAccount":{"emailAddress":"alt@example.com","organizationName":"TestOrg"},"mcpServers":{"a":{"command":"a-alt"},"c":{"command":"c"}}}\n' > "$HOME/.claude-alt/.claude.json"
t "status table"
out="$(claude-profiles status 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "claude 9.9.9"
if printf '%s' "$out" | grep -E '^main +~/.claude +yes +main@example.com +TestOrg +team' >/dev/null; then pass "main row"; else failt "main row wrong: $out"; fi
if printf '%s' "$out" | grep -E '^alt +~/.claude-alt +yes +alt@example.com +TestOrg +team' >/dev/null; then pass "alt row"; else failt "alt row wrong: $out"; fi
if printf '%s' "$out" | grep -E '^work +~/.claude-work +never-run' >/dev/null; then pass "work row"; else failt "work row wrong: $out"; fi

# ======================================================================================
echo "[T6] doctor"
t "doctor passes on a healthy install"
out="$(claude-profiles doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "all checks passed"
assert_contains "$out" "wrapper defines claude() under bash"
[ "$have_zsh" -eq 1 ] && assert_contains "$out" "wrapper defines claude() under zsh"
t "doctor flags a missing symlink"
rm "$HOME/.claude-alt/settings.json"
out="$(claude-profiles doctor 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "settings.json missing"
t "install repairs it"
claude-profiles install --no-install --shell both >/dev/null 2>&1
assert_link "$HOME/.claude-alt/settings.json" "$HOME/.claude-shared/settings.json"
claude-profiles doctor >/dev/null 2>&1; assert_rc $? 0
t "doctor warns about ~/.claude/.claude.json"
touch "$HOME/.claude/.claude.json"
out="$(claude-profiles doctor 2>&1)"; assert_contains "$out" "Never set that for main"
rm "$HOME/.claude/.claude.json"
t "doctor flags a hook whose script is missing"
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/hooks/nope.sh"}]}]}}\n' > "$HOME/.claude-shared/settings.json"
out="$(claude-profiles doctor 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "hooks/nope.sh which does not exist"
printf '{}\n' > "$HOME/.claude-shared/settings.json"
t "doctor parses real-world hook and statusLine commands precisely"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.claude-shared/hooks/h.sh"; chmod +x "$HOME/.claude-shared/hooks/h.sh"
cat > "$HOME/.claude-shared/settings.json" <<'EOF'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"bash '$HOME/.claude/hooks/h.sh' session"},{"type":"command","command":"~/.claude/hooks/h.sh hook-stop"}]}]},
 "statusLine":{"type":"command","command":"CLAUDE_USER=\"$(jq -r '.oauthAccount.emailAddress // empty' ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json 2>/dev/null)\" PATH=$HOME/n/bin:$PATH $HOME/n/bin/claude-powerline"}}
EOF
out="$(claude-profiles doctor 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_contains "$out" "statusLine references ~/n/bin/claude-powerline which does not exist"
assert_not_contains "$out" "}"
assert_not_contains "$out" ':$PATH'
assert_not_contains "$out" "h.sh which does not exist"
printf '{}\n' > "$HOME/.claude-shared/settings.json"; rm "$HOME/.claude-shared/hooks/h.sh"
t "doctor flags invalid settings.json"
printf '{oops\n' > "$HOME/.claude-shared/settings.json"
out="$(claude-profiles doctor 2>&1)"; rc=$?
assert_rc "$rc" 1
assert_contains "$out" "not valid JSON"
printf '{}\n' > "$HOME/.claude-shared/settings.json"

# ======================================================================================
echo "[T7] sync-mcp"
t "sync-mcp main alt"
out="$(claude-profiles sync-mcp main alt 2>&1)"; rc=$?
assert_rc "$rc" 0
merged="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["mcpServers"]; print(",".join(k+"="+v["command"] for k,v in sorted(d.items())))' "$HOME/.claude-alt/.claude.json")"
assert_eq "$merged" "a=a-main,b=b,c=c" "merged servers (source wins, extras kept)"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["oauthAccount"]["emailAddress"])' "$HOME/.claude-alt/.claude.json")" "alt@example.com" "other keys untouched"
assert_eq "$(find "$HOME/.claude-alt" -maxdepth 1 -name '.claude.json.bak-*' | wc -l | tr -d ' ')" "1" "backup written"
t "sync-mcp refuses when target never ran"
claude-profiles sync-mcp main work >/dev/null 2>&1; assert_rc $? 1

# ======================================================================================
echo "[T8] link-memory"
mkdir -p "$SANDBOX/proj.x/sub"
t "link-memory"
out="$(claude-profiles link-memory "$SANDBOX/proj.x/sub" alt 2>&1)"; rc=$?
assert_rc "$rc" 0
slug="$(printf '%s' "$SANDBOX/proj.x/sub" | sed 's/[^A-Za-z0-9]/-/g')"
assert_dir "$HOME/.claude/projects/$slug/memory"
assert_link "$HOME/.claude-alt/projects/$slug/memory" "$HOME/.claude/projects/$slug/memory"
t "link-memory moves existing alt notes when main is empty"
mkdir -p "$SANDBOX/proj2"; slug2="$(printf '%s' "$SANDBOX/proj2" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HOME/.claude-work/projects/$slug2/memory"; echo note > "$HOME/.claude-work/projects/$slug2/memory/MEMORY.md"
claude-profiles link-memory "$SANDBOX/proj2" work >/dev/null 2>&1; assert_rc $? 0
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
assert_absent "$HOME/.local/bin/claude-profiles"
assert_eq "$(wc -c < "$HOME/.bashrc" | tr -d ' ')" "0" ".bashrc untouched"

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
out="$(bash "$SETUP" install --no-install --bundle "$SANDBOX/bundle.tgz" 2>&1)"; rc=$?
assert_rc "$rc" 0
assert_eq "$(ls -d "$HOME"/.claude-shared.bak-* | wc -l | tr -d ' ')" "1" "shared backup"
assert_file "$HOME/.claude-shared/rules/local.md"
t "import refuses a bundle with credentials"
mkdir -p "$SANDBOX/bad"; echo s > "$SANDBOX/bad/.credentials.json"; tar -czf "$SANDBOX/bad.tgz" -C "$SANDBOX/bad" .
bash "$SETUP" install --no-install --bundle "$SANDBOX/bad.tgz" >/dev/null 2>&1; assert_rc $? 1

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
echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
