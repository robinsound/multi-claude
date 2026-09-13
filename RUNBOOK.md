# Runbook: two or more Claude Code accounts on one VM

Goal: on a new server, `claude` opens the main account and `claude alt` opens the
alternate account, exactly like this machine. Both accounts share one CLAUDE.md,
settings.json, hooks, commands, rules and skills. Adding a third account is one command.

Files in this folder:

| File | Run where | Purpose |
|------|-----------|---------|
| `setup-multi-claude.sh` | new VM | installs Claude Code, wires the profiles, installs the `claude()` wrapper. Idempotent. Installs itself as `claude-profiles`. |
| `export-shared-bundle.sh` | this machine (optional) | packs `~/.claude-shared` so the new VM starts with the same instructions, hooks and settings. Never includes credentials. |
| `tests/run-tests.sh` | anywhere | sandboxed self-test (fake HOME, fake `claude`, fake `curl`). Run it after editing the scripts. |

## 1. How it works

```
claude alt --resume abc
  │  shell function claude() (from ~/.claude-shared/claude-profiles.sh)
  │  consumes the first argument that is a registered profile name
  ▼
CLAUDE_CONFIG_DIR=$HOME/.claude-alt  command claude --resume abc
```

| Profile | Config dir | Account state (`.claude.json`) | Credentials |
|---------|-----------|-------------------------------|-------------|
| main | `~/.claude` | `~/.claude.json` | `~/.claude/.credentials.json` |
| alt | `~/.claude-alt` | `~/.claude-alt/.claude.json` | `~/.claude-alt/.credentials.json` |
| any `<name>` | `~/.claude-<name>` | `~/.claude-<name>/.claude.json` | `~/.claude-<name>/.credentials.json` |

Shared through symlinks into `~/.claude-shared/` from every profile dir:
`CLAUDE.md`, `settings.json`, `hooks/`, `commands/`, `rules/`, `skills/`, `agents/`
(and `claude-powerline.json` when present).

Per account, never shared: credentials, `.claude.json` (account, onboarding flags,
user-scope MCP servers), `projects/` (session history and memory), `plugins/`.

Profile names live in `~/.claude-shared/profiles`, one per line. The wrapper reads that
file on every call, so a new profile works without reopening the shell. The bare word
`main` is always accepted and means the default account.

## 2. Prerequisites on the new VM

- Linux x86_64 or arm64, a normal user (not root), `curl`, `tar`, `python3` (present on
  Ubuntu; `jq` is an acceptable substitute for status parsing).
- Login shell bash or zsh. The script writes one managed block into `~/.bashrc` and/or
  `~/.zshrc`.
- Outbound HTTPS to `claude.ai` for the installer and the login.
- A browser on your laptop for the OAuth login (the VM itself needs no browser).

## 3. Install

### 3a. Optional: export the shared config from this machine

```bash
cd ~/robin/multi-claude
./export-shared-bundle.sh                       # -> ./multi-claude-shared-<host>-<ts>.tar.gz
```

It lists symlinks that point outside `~/.claude-shared` (they dangle on the target unless
the same path exists there; add `--dereference` to copy their content instead). The
archive never contains `.credentials.json` or `.claude.json`.

Review before shipping: `settings.json` carries the permission allow-list and hook
commands; hooks may reference tools the new VM lacks (codebase-memory-mcp, herdr,
claude-powerline). `claude-profiles doctor` on the target reports every such reference.

### 3b. Copy and run

```bash
scp setup-multi-claude.sh [multi-claude-shared-*.tar.gz] <user>@<vm>:~/
ssh <user>@<vm>
bash ~/setup-multi-claude.sh install                       # profiles: main + alt
# or:
bash ~/setup-multi-claude.sh install --bundle ~/multi-claude-shared-*.tar.gz
bash ~/setup-multi-claude.sh install --profiles alt,work   # three accounts
bash ~/setup-multi-claude.sh install --dry-run             # show the plan, change nothing
```

What `install` does, in order:

1. Installs Claude Code with the official native installer if `claude` is missing
   (`--claude-version stable|latest|x.y.z`, `--upgrade` to re-run it, `--no-install` to skip).
2. Creates `~/.claude-shared` (seeded from the bundle when given; an existing non-empty
   shared dir is copied to `~/.claude-shared.bak-<ts>` first). Absolute paths from the
   source home are rewritten to the new home in scripts, JSON and symlink targets.
   Markdown is left untouched.
3. Wires `~/.claude` and every `~/.claude-<profile>` to the shared files. An existing
   local file is adopted into the shared dir when there is no shared copy yet, replaced
   by a symlink when identical, or kept as `<file>.bak-<ts>` when it differs.
4. Writes `~/.claude-shared/claude-profiles.sh` and adds a 3-line block to the rc
   file(s) (`--shell auto|bash|zsh|both`; auto = the rc files that exist plus the login
   shell's).
5. Copies itself to `~/.local/bin/claude-profiles`.

Nothing is deleted. Re-running is safe and repairs broken symlinks.

### 3c. Log in each account

```bash
exec $SHELL -l                 # or: source ~/.zshrc / source ~/.bashrc
type claude                    # must say "claude is a shell function"

claude                         # main account: finish onboarding, then /login
claude alt                     # alt account: finish onboarding, then /login
```

Headless login over SSH: Claude Code prints a URL. Open it in a browser on your laptop,
sign in as the right account, and paste the code back into the terminal. For the alt
account use a private browser window (or log out of the main account first) so the
authorization is granted to the correct account. `claude alt auth login --email <alt-email>`
pre-fills the address.

### 3d. Verify

```bash
claude-profiles status
# PROFILE  CONFIG_DIR     LOGGED_IN  ACCOUNT                      ORG        SUBSCRIPTION
# main     ~/.claude      yes        robin@attention.tech         Attention  team
# alt      ~/.claude-alt  yes        robin.claude@attention.tech  Attention  team

claude-profiles doctor         # exit 0 = wiring is correct; warnings are advisory
```

## 4. Daily use

```bash
claude                          # main account
claude alt                      # alt account
clauded alt                     # alt account, --dangerously-skip-permissions
claude alt --resume <id>        # any claude flag works after the profile word
claude --continue alt           # the profile word may appear anywhere
claude -p "alt text"            # a quoted prompt is never mistaken for a profile
command claude                  # bypass the wrapper entirely
```

Run both accounts at once in separate tmux windows; their state never overlaps. Rate
limits are per account. `claude update` updates the single shared binary for everyone.

Non-interactive contexts (cron, `ssh vm 'claude ...'`, scripts) do not read `~/.bashrc`,
so the function is absent there. Use one of:

```bash
claude-profiles exec alt -p "summarize the failing tests"
CLAUDE_CONFIG_DIR=$HOME/.claude-alt claude -p "..."
```

## 5. Adding, syncing, sharing

Third account:

```bash
claude-profiles add-profile work      # creates ~/.claude-work, registers it
claude work                           # then /login
```

MCP servers are user-scope per account (they live in each `.claude.json`). Configure
them once on main, then copy:

```bash
claude mcp add -s user context7 -- npx -y @upstash/context7-mcp    # example, on main
claude-profiles sync-mcp main alt                                    # copies mcpServers main -> alt
```

Close the target account's Claude sessions first; a running session rewrites its
`.claude.json` on exit. A backup `.claude.json.bak-<ts>` is written every time.

Plugins are per account too: run `/plugin` under each profile, or keep the shared
`settings.json` `enabledPlugins` and let each profile install on first start.

Project memory (the `memory/` notes under `projects/<slug>/`) is per account. To let both
accounts read and write the same notes for a repository:

```bash
claude-profiles link-memory ~/att/video/playback          # every profile -> main's memory
claude-profiles link-memory ~/att/video/playback alt      # only alt
```

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `claude alt` starts the main account (or treats `alt` as a prompt) | the wrapper is not loaded: `type claude` says "is /home/.../claude" | `source ~/.zshrc` (or `~/.bashrc`); check the rc file ends with the `# >>> multi-claude >>>` block; `claude-profiles doctor` |
| both profiles show the same email in `status` | logged in with the same browser session twice | `claude alt` then `/logout`, `/login` in a private window as the alt account |
| `~/.claude/.claude.json` exists (doctor warns) | something ran with `CLAUDE_CONFIG_DIR=~/.claude` | never set that variable for main; main's state is `~/.claude.json`. The stray file is harmless but stale |
| hook errors on every tool call after a bundle import | `settings.json` references a hook or tool missing on this host | `claude-profiles doctor` lists them; install the tool, or remove that hook from `~/.claude-shared/settings.json` |
| status line shows an error | `claude-powerline` not installed here | `npm i -g @owloops/claude-powerline` on a node 22 toolchain, or delete `statusLine` from `settings.json` |
| dangling symlink warnings in `~/.claude-shared/skills` | the bundle kept links to repo paths that do not exist here | clone the repo to the same relative path, re-export with `--dereference`, or remove the link |
| `settings.json.bak-<ts>` appeared in a profile dir | that profile had its own settings that differed from the shared copy | diff and merge by hand, then delete the backup |
| a login shell on the new VM cannot see `claude` at all | `~/.local/bin` not on PATH yet | `exec $SHELL -l`; the wrapper file also prepends it |

Uninstall (keeps every account logged in):

```bash
sed -i '/# >>> multi-claude >>>/,/# <<< multi-claude <<</d' ~/.zshrc ~/.bashrc
rm ~/.claude-shared/claude-profiles.sh ~/.local/bin/claude-profiles
# ~/.claude, ~/.claude-alt and the symlinks into ~/.claude-shared keep working as they are;
# plain `CLAUDE_CONFIG_DIR=~/.claude-alt claude` still opens the alt account.
```

## 7. Changing the scripts

Run the sandboxed suite before shipping a change:

```bash
tests/run-tests.sh            # ~5 s; fake HOME under mktemp, fake claude and curl
KEEP_SANDBOX=1 tests/run-tests.sh   # keep the sandbox for inspection
```

The harness refuses to run with a real HOME and never touches `~/.claude*` on this host.
It covers: fresh install through the installer path, idempotency, adopt/backup rules,
wrapper routing under bash and zsh (12 argument shapes each), add-profile, status,
doctor pass/fail cases, sync-mcp, link-memory, dry-run, bundle export/import with home
rewriting, and shellcheck.

## Reference: this machine (source of the pattern)

- Wrapper: `claude()` function in `~/.local/bin/env`, sourced by `~/.zshrc` (rebuilt
  2026-09-04 after PL-3342). It only knows `alt`. The generated wrapper on new VMs is
  the profile-driven equivalent; both accept `clauded alt`.
- main: `robin@attention.tech` (`~/.claude`, state `~/.claude.json`);
  alt: `robin.claude@attention.tech` (`~/.claude-alt`).
- Shared: `~/.claude-shared/{CLAUDE.md,settings.json,hooks,commands,rules,skills,claude-powerline.json}`.
- Claude Code 2.1.270, native install at `~/.local/bin/claude`.
