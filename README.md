# multi-claude

Run two or more Claude Code accounts on one Linux machine: `claude` for the main
account, `claude alt` for the alternate, `claude <name>` for any other, with one shared
set of instructions, settings and hooks.

- `setup-multi-claude.sh` -- run on the target VM (`install`, `status`, `doctor`,
  `add-profile`, `sync-mcp`, `link-memory`, `exec`). Installs itself as `claude-profiles`.
- `export-shared-bundle.sh` -- run on a configured machine to carry `~/.claude-shared`
  over (no credentials).
- `tests/run-tests.sh` -- sandboxed self-test.
- `RUNBOOK.md` -- step-by-step install, daily use, troubleshooting.

Quick start on a fresh VM:

```bash
scp setup-multi-claude.sh <user>@<vm>:~/ && ssh <user>@<vm>
bash ~/setup-multi-claude.sh install && exec $SHELL -l
claude        # /login as main
claude alt    # /login as alt
claude-profiles status
```
