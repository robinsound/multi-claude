#!/usr/bin/env bash
# export-shared-bundle.sh - pack ~/.claude-shared so setup-multi-claude.sh --bundle can seed
# another machine with the same CLAUDE.md, settings.json, hooks, commands, rules and skills.
#
# Never includes credentials or per-account state (.credentials.json, .claude.json), the
# host-specific pieces (the claude-profiles.sh wrapper, the profile registry, the peer-session
# registry, multi-claude.conf). Records the source $HOME in .bundle-meta so the importer can
# rewrite absolute paths for a different user.
#
# Works from a clone or straight from a download: `curl -fsSL <url>/export-shared-bundle.sh | bash`.
set -euo pipefail

SHARED_DIR="$HOME/.claude-shared"
RAW_URL="${MULTI_CLAUDE_RAW_URL:-https://raw.githubusercontent.com/${MULTI_CLAUDE_REPO:-robinsound/multi-claude}/${MULTI_CLAUDE_REF:-master}}"
OUT=""
DEREF=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
export-shared-bundle.sh - pack ~/.claude-shared for another machine (no credentials)

usage: export-shared-bundle.sh [-o FILE] [--dereference]
  -o, --output FILE   archive path (default: ./multi-claude-shared-<host>-<timestamp>.tar.gz)
  --dereference       copy the content behind symlinks that point outside ~/.claude-shared
                      (default: keep them as symlinks; they dangle on the target unless the
                      same path exists there)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUT="${2:-}"; shift 2 ;;
    --output=*) OUT="${1#*=}"; shift ;;
    --dereference) DEREF=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -d "$SHARED_DIR" ] || die "$SHARED_DIR does not exist on this machine; nothing to export"
[ -n "$OUT" ] || OUT="./multi-claude-shared-$(hostname -s 2>/dev/null || hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"
case "$OUT" in /*) ;; *) OUT="$PWD/${OUT#./}" ;; esac
[ ! -e "$OUT" ] || die "$OUT already exists; pick another name with -o"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

{
  printf 'SOURCE_HOME=%s\n' "$HOME"
  printf 'SOURCE_HOST=%s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'SOURCE_USER=%s\n' "$(id -un)"
  printf 'CREATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'CLAUDE_VERSION=%s\n' "$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | head -1 || printf 'unknown')"
} > "$tmp/.bundle-meta"

# symlinks that leave the shared dir: report them, and with --dereference skip the dangling ones
excludes=()
outside=0
while IFS= read -r -d '' l; do
  target="$(readlink "$l")"
  case "$target" in
    "$SHARED_DIR"/*) continue ;;
  esac
  outside=$((outside + 1))
  rel="${l#"$SHARED_DIR"/}"
  if [ -e "$l" ]; then
    printf '  symlink %-45s -> %s  [exists here%s]\n' "$rel" "$target" "$([ "$DEREF" -eq 1 ] && printf '; copying content' || printf '; kept as link')"
  else
    printf '  symlink %-45s -> %s  [DANGLING%s]\n' "$rel" "$target" "$([ "$DEREF" -eq 1 ] && printf '; skipped' || printf '; kept as link')"
    [ "$DEREF" -eq 1 ] && excludes+=("--exclude=./$rel")
  fi
done < <(find "$SHARED_DIR" -type l -print0)
[ "$outside" -eq 0 ] || printf '  (%d symlink(s) point outside %s; the importer rewrites %s to the target home in their targets)\n' "$outside" "$SHARED_DIR" "$HOME"

tar_opts=(-czf "$OUT"
  --exclude='./claude-profiles.sh' --exclude='./profiles' --exclude='./multi-claude.conf'
  --exclude='./sessions' --exclude='./sessions.off-*'
  --exclude='__pycache__' --exclude='*.pyc' --exclude='*.bak-*'
  --exclude='.credentials.json' --exclude='.claude.json')
[ "$DEREF" -eq 1 ] && tar_opts+=(-h)
tar "${tar_opts[@]}" "${excludes[@]+"${excludes[@]}"}" -C "$SHARED_DIR" . -C "$tmp" .bundle-meta

if tar -tzf "$OUT" | grep -qE '(^|/)(\.credentials\.json|\.claude\.json)$|(^|/)sessions[^/]*/[^/]+\.key$'; then
  rm -f "$OUT"; die "archive contained credential/state files; aborted and removed"
fi

n="$(tar -tzf "$OUT" | wc -l | tr -d ' ')"
size="$(du -h "$OUT" | cut -f1)"
printf 'wrote %s (%s, %s entries)\n' "$OUT" "$size" "$n"
printf '\nnext (RUNBOOK.md section 3):\n'
printf '  scp %s <user>@<vm>:~/\n' "$OUT"
printf '  ssh <user>@<vm>\n'
printf '  curl -fsSL %s/install.sh | bash -s -- --bundle ~/%s\n' "$RAW_URL" "$(basename "$OUT")"
printf '  # multi-claude already installed there:  multi-claude install --bundle ~/%s\n' "$(basename "$OUT")"
