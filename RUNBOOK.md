# Runbook: two or more Claude Code accounts on one VM

Goal: on a new server, `claude` opens the main account and `claude alt` opens the
alternate account, exactly like this machine. Both accounts share one CLAUDE.md,
settings.json, hooks, commands, rules and skills. Adding a third account is one command.

Files in this folder:

| File | Run where | Purpose |
|------|-----------|---------|
| `setup-multi-claude.sh` | new VM, from the clone (`~/apps/multi-claude`) | installs Claude Code, wires the profiles, installs the `claude()` wrapper. Idempotent. Installs itself as `claude-profiles`. |
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
Per account by default, shareable on request: `sessions/`, the registry Claude Code uses to
find the other sessions on this machine (section 5d).

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

The scripts run from a clone of this repository on the new VM. The examples use
`~/apps/multi-claude`; any path works, but keep the clone: it is where updates are pulled
and where `install` is re-run (section 3f).

### 3a. Clone the repo on the new VM

The repository is private. Either forward your SSH agent when you connect, or sign in
with the GitHub CLI once on the VM:

```bash
ssh -A <user>@<vm>                                            # -A forwards your SSH agent
mkdir -p ~/apps
git clone git@github.com:robinsound/multi-claude.git ~/apps/multi-claude

# without SSH keys on the VM:
gh auth login && gh repo clone robinsound/multi-claude ~/apps/multi-claude
```

No git on the VM at all? Copy the one script and substitute `bash ~/setup-multi-claude.sh`
for `./setup-multi-claude.sh` in every command below:

```bash
scp setup-multi-claude.sh <user>@<vm>:~/
```

### 3b. Optional: bring the shared config from this machine

On the machine that already has the working setup (here: `~/robin/multi-claude`):

```bash
cd ~/apps/multi-claude                          # this machine's clone
./export-shared-bundle.sh                       # -> ./multi-claude-shared-<host>-<ts>.tar.gz
scp multi-claude-shared-*.tar.gz <user>@<vm>:~/
```

The archive lands in the clone and is ignored by git (`.gitignore`). Never commit it: it
carries your settings and hooks. It never contains `.credentials.json` or `.claude.json`.

It lists symlinks that point outside `~/.claude-shared` (they dangle on the target unless
the same path exists there; add `--dereference` to copy their content instead).

Review before shipping: `settings.json` carries the permission allow-list and hook
commands; hooks may reference tools the new VM lacks (codebase-memory-mcp, herdr,
claude-powerline). `claude-profiles doctor` on the target reports every such reference.

### 3c. Run the installer from the clone

```bash
cd ~/apps/multi-claude
./setup-multi-claude.sh install                                    # profiles: main + alt
# or:
./setup-multi-claude.sh install --bundle ~/multi-claude-shared-*.tar.gz
./setup-multi-claude.sh install --profiles alt,work                # three accounts
./setup-multi-claude.sh install --share-sessions                   # sessions of all accounts can message each other (5d)
./setup-multi-claude.sh install --dry-run                          # show the plan, change nothing
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
5. Copies itself to `~/.local/bin/claude-profiles`. It is a copy, not a link, so the
   clone can move or disappear without breaking the command (see 3f for updates).

Nothing is deleted. Re-running is safe and repairs broken symlinks.

### 3d. Log in each account

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

### 3e. Verify

```bash
claude-profiles status
# PROFILE  CONFIG_DIR     LOGGED_IN  ACCOUNT                      ORG        SUBSCRIPTION
# main     ~/.claude      yes        robin@attention.tech         Attention  team
# alt      ~/.claude-alt  yes        robin.claude@attention.tech  Attention  team

claude-profiles doctor         # exit 0 = wiring is correct; warnings are advisory
```

### 3f. Updating later

`~/.local/bin/claude-profiles` and the wrapper in `~/.claude-shared` are written at
install time, so a `git pull` alone changes nothing on the host. Pull, then re-run
`install` from the clone; it refreshes both and repairs the wiring:

```bash
cd ~/apps/multi-claude && git pull
tests/run-tests.sh                        # optional: ~5 s, sandboxed, touches no real config
./setup-multi-claude.sh install
```

If you would rather have `git pull` take effect immediately, replace the copy with a
link once. `install` recognises the link and leaves it alone:

```bash
ln -sfn ~/apps/multi-claude/setup-multi-claude.sh ~/.local/bin/claude-profiles
```

The clone must then stay where it is; a moved or deleted clone leaves a dangling command.
Changes to the generated wrapper still need one `./setup-multi-claude.sh install`.

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

### 5a. Adding more accounts

One command per extra account; no reinstall, no shell reload:

```bash
claude-profiles add-profile work      # creates ~/.claude-work, wires it, registers it
claude work                           # finish onboarding, then /login as that account
claude-profiles status                # shows which email each profile is logged in as
```

What `add-profile` does: creates `~/.claude-<name>`, symlinks the shared files into it
(CLAUDE.md, settings.json, hooks, commands, rules, skills, agents) and appends the name to
`~/.claude-shared/profiles`. The `claude()` wrapper reads that file on every call, so
`claude work` works at once in every open shell. Credentials, session history, memory,
MCP servers and plugins of the new account stay in its own directory.

Name rules: lowercase letters, digits, `-` and `_`, starting with a letter or digit.
`main` and `shared` are reserved. An invalid name is rejected before anything is written.

Several at once, or on a fresh VM: `./setup-multi-claude.sh install --profiles alt,work,client`.
Re-running `install` with a longer list on an existing host only adds; nothing is removed.

Per new account, as needed:

- Log in over SSH from a private browser window, or the OAuth grant lands on whichever
  account the browser is already signed into. `claude work auth login --email <addr>`
  pre-fills the address.
- MCP servers: `claude-profiles sync-mcp main work` copies main's set (see 5b).
- Shared project memory: `claude-profiles link-memory <repo-dir> work` (see 5c).
- `clauded work` is the skip-permissions variant, same as for `alt`.

There is no cap on the number of profiles. Each one costs one directory and one login.
Rate limits are per account, so profiles run in parallel without interfering.

### 5b. MCP servers and plugins

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

### 5c. Shared project memory

Project memory (the `memory/` notes under `projects/<slug>/`) is per account. To let both
accounts read and write the same notes for a repository:

```bash
claude-profiles link-memory ~/att/video/playback          # every profile -> main's memory
claude-profiles link-memory ~/att/video/playback alt      # only alt
```

### 5d. Letting sessions of different accounts see and message each other

Claude Code sessions on one machine can list and message each other (the ListAgents and
SendMessage tools, and peer notifications). Out of the box that only works within one
account: `claude` sessions see each other, `claude alt` sessions see each other, and the
two groups are invisible to one another. Opting in makes every session on the machine a
peer of every other, whichever account it runs on.

```bash
claude-profiles share-sessions            # any time after install; safe while sessions run
# or, on a fresh VM:
./setup-multi-claude.sh install --share-sessions
```

How it works. Each session registers itself in `sessions/` inside its config dir
(`<pid>.json` with name, cwd, status and socket path, plus a `<pid>.<hash>.key` peer token,
mode 0600) and discovers peers by reading that directory. The transport is a unix socket
per session under `/run/user/<uid>/cc-socks/`, which every profile of one OS user already
shares. `share-sessions` therefore only has to give all profiles one registry:

1. creates `~/.claude-shared/sessions` with mode 0700;
2. moves the entries found in `~/.claude/sessions` and every `~/.claude-<profile>/sessions`
   into it (an entry that already exists there is never overwritten; the local directory is
   then kept as `sessions.bak-<ts>` instead);
3. replaces each profile's `sessions` with a symlink to the shared directory.

Running sessions need no restart: they keep writing to the same relative path, which now
resolves inside the shared directory. Profiles added later with `add-profile` join
automatically, and `install` keeps the sharing on when re-run. `doctor` reports the mode
in use and fails if one profile has dropped out; `status` shows it in its header line.

Verify from any session: ask Claude to list its peer sessions. Sessions of the other
accounts appear in the list, and a message to one of them arrives there as a normal peer
message. Verified on this machine with Claude Code 2.1.270.

Know before enabling:

- Undocumented territory. Claude Code documents that sessions must see the same registry
  files to reach each other, but offers no setting for it; a future release could change
  the registry format or start recording the config dir in each entry. `doctor` will show
  a broken link, but not a silently changed format.
- Peer messages carry a session name, not an account. Names derive from the working
  directory, so nothing tells a main session that `playback-65` runs on the alt account.
- Same security boundary as before: everything stays owned by one OS user, the registry
  is 0700 and the peer tokens 0600. Nothing is exposed to other users on the machine.
- Unrelated to agent teams: a lead spawns its teammates inside its own session, so a team
  always runs on one account, shared registry or not.
- Project memory and MCP servers stay per account (5b, 5c).

Undo (each profile gets its own empty registry back; sessions already running re-register
on their next restart, and until then still see each other through the old entries):

```bash
for d in ~/.claude ~/.claude-*/; do d="${d%/}"; [ -L "$d/sessions" ] && rm "$d/sessions" && mkdir -m 0700 "$d/sessions"; done
mv ~/.claude-shared/sessions ~/.claude-shared/sessions.off-$(date +%Y%m%d)   # doctor then reports "per account"
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
| a `claude alt` session is missing from a main session's peer list (or the reverse) | the peer-session registry is per account by default | `claude-profiles share-sessions` (section 5d); `claude-profiles doctor` shows which mode is active |
| doctor: `~/.claude-<p>/sessions is not linked to the shared registry` | sharing is on but that profile's `sessions/` was recreated as a plain dir (undo by hand, or an older `add-profile`) | `claude-profiles share-sessions` again; it moves the stray entries over and re-links |
| `claude-profiles` lacks a subcommand or fix that is in the repo | `~/.local/bin/claude-profiles` is a copy taken at install time; `git pull` does not update it | `cd ~/apps/multi-claude && git pull && ./setup-multi-claude.sh install` (section 3f) |

Uninstall (keeps every account logged in):

```bash
sed -i '/# >>> multi-claude >>>/,/# <<< multi-claude <<</d' ~/.zshrc ~/.bashrc
rm ~/.claude-shared/claude-profiles.sh ~/.local/bin/claude-profiles
# ~/.claude, ~/.claude-alt and the symlinks into ~/.claude-shared keep working as they are;
# plain `CLAUDE_CONFIG_DIR=~/.claude-alt claude` still opens the alt account.
# The clone (~/apps/multi-claude) can stay or go; nothing points at it unless you made the 3f link.
# A shared peer-session registry (5d) keeps working too; its undo is in 5d.
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
doctor pass/fail cases, sync-mcp, link-memory, share-sessions (move, link, conflict backup,
mode, idempotency, add-profile joining, doctor/status reporting, export exclusion), dry-run,
bundle export/import with home rewriting, and shellcheck.

## Reference: this machine (source of the pattern)

- Wrapper: since 2026-09-13 the generated `~/.claude-shared/claude-profiles.sh`, sourced
  by the managed block at the end of `~/.zshrc` (this machine was installed with the
  script itself, sharing on). The older hand-made `claude()` in `~/.local/bin/env`
  (rebuilt 2026-09-04 after PL-3342, knew only `alt`) was removed the same day; a
  backup sits next to the file as `env.bak-<ts>`.
- main: `robin@attention.tech` (`~/.claude`, state `~/.claude.json`);
  alt: `robin.claude@attention.tech` (`~/.claude-alt`).
- Shared: `~/.claude-shared/{CLAUDE.md,settings.json,hooks,commands,rules,skills,claude-powerline.json}`.
- Claude Code 2.1.270, native install at `~/.local/bin/claude`.
- Clone of this repo: `~/robin/multi-claude` (origin `robinsound/multi-claude`, private).
- Peer-session registry shared across both accounts (5d); `doctor` passes with two
  genuine warnings (stale `~/.claude/.claude.json` from Sep 7, one hook hardcoding `/home/robin`).
