# multi-claude

Run two or more Claude Code accounts on one Linux machine: `claude` for the main
account, `claude alt` for the alternate, `claude <name>` for any other, with one shared
set of instructions, settings and hooks.

- `setup-multi-claude.sh` -- run on the target VM from a clone of this repo (`install`,
  `status`, `doctor`, `add-profile`, `sync-mcp`, `link-memory`, `exec`). Installs itself
  as `claude-profiles`.
- `export-shared-bundle.sh` -- run on a configured machine to carry `~/.claude-shared`
  over (no credentials).
- `tests/run-tests.sh` -- sandboxed self-test.
- `RUNBOOK.md` -- step-by-step install, daily use, updating, troubleshooting.

Quick start on a fresh VM. The repo is private: connect with `ssh -A` so your SSH agent
is forwarded, or run `gh auth login` on the VM first and clone with `gh repo clone`.

```bash
git clone git@github.com:robinsound/multi-claude.git ~/apps/multi-claude
cd ~/apps/multi-claude
./setup-multi-claude.sh install && exec $SHELL -l
claude        # /login as main
claude alt    # /login as alt
claude-profiles status
```

Update later from the same clone (re-running is safe; it refreshes the `claude-profiles`
copy in `~/.local/bin` and repairs the wiring):

```bash
cd ~/apps/multi-claude && git pull && ./setup-multi-claude.sh install
```

No git on the VM? `scp setup-multi-claude.sh <user>@<vm>:~/` and run
`bash ~/setup-multi-claude.sh install` instead; everything else is identical.
