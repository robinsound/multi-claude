#!/bin/sh
# install.sh - install multi-claude without cloning the repository.
#
#   curl -fsSL https://raw.githubusercontent.com/robinsound/multi-claude/master/install.sh | bash
#
# Everything after `-s --` goes to `setup-multi-claude.sh install`, for example:
#
#   curl -fsSL .../install.sh | bash -s -- --profiles alt,work
#   curl -fsSL .../install.sh | bash -s -- --dry-run          # show the plan, change nothing
#
# What it does: downloads setup-multi-claude.sh to a temporary file, refuses it unless it is a
# complete bash script, and runs its `install` command. That installs Claude Code when it is
# missing, wires the accounts and leaves the `multi-claude` command in ~/.local/bin. Nothing
# else is kept on disk. Later: `multi-claude update` fetches the newest version the same way.
#
# Environment (all optional):
#   MULTI_CLAUDE_REPO      owner/name on GitHub        (default: robinsound/multi-claude)
#   MULTI_CLAUDE_REF       branch or tag               (default: master)
#   MULTI_CLAUDE_RAW_URL   base URL serving the files; replaces the two above
#
# POSIX sh on purpose, so `| sh` works as well as `| bash`. The body is one function called
# on the last line: a download cut short can never run half a script.
set -eu

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

main() {
  repo="${MULTI_CLAUDE_REPO:-robinsound/multi-claude}"
  ref="${MULTI_CLAUDE_REF:-master}"
  base="${MULTI_CLAUDE_RAW_URL:-https://raw.githubusercontent.com/$repo/$ref}"
  script="setup-multi-claude.sh"

  command -v bash >/dev/null 2>&1 || die "bash is required to run $script; install it and try again"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/multi-claude-install.XXXXXX")" || die "cannot create a temporary directory"
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP

  printf 'downloading %s/%s\n' "$base" "$script"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$base/$script" -o "$tmp/$script" || die "download failed: $base/$script"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp/$script" "$base/$script" || die "download failed: $base/$script"
  else
    die "curl or wget is required to download $script"
  fi

  # a truncated or wrong download (an error page, a proxy login form) must never run
  if ! head -n 1 "$tmp/$script" | grep -q '^#!.*bash' ||
     ! grep -q '^VERSION=' "$tmp/$script" ||
     ! bash -n "$tmp/$script" 2>/dev/null; then
    die "the downloaded file is not a valid $script; nothing was installed"
  fi

  # stdin may be the pipe this very script arrives through: keep the installer away from it
  bash "$tmp/$script" install "$@" </dev/null
}

main "$@"
