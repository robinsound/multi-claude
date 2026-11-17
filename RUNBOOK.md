# Runbook: two or more Claude Code accounts on one VM

Goal: on a new server, `claude` opens the main account and `claude alt` opens the
alternate account. All accounts share one CLAUDE.md, settings.json, hooks, commands, rules,
skills and agents, and their sessions can message each other. Adding another account is one
command. The README is the short version of this document.

Files in this repository:

| File | Run where | Purpose |
|------|-----------|---------|
| `install.sh` | new VM, straight from the web | one-line installer: downloads `setup-multi-claude.sh` and runs its `install`. No clone needed. |
| `setup-multi-claude.sh` | new VM | installs Claude Code, wires the profiles, shares the peer-session registry, installs the `claude()` wrapper. Idempotent. Installs itself as `multi-claude`. |
| `export-shared-bundle.sh` | a machine that is already set up (optional) | packs `~/.claude-shared` so the new VM starts with the same instructions, hooks and settings. Never includes credentials. |
| `tests/run-tests.sh` | anywhere | sandboxed self-test (fake HOME, fake `claude`, fake `curl`). Run it after editing the scripts. |

The command is `multi-claude`. Before version 1.1 it was called `claude-profiles`; on a
host that had it, the old name stays as an alias of the new one.

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
(and `claude-powerline.json` when present), plus `sessions/`, the registry Claude Code uses
to find the other sessions on this machine. Sharing that registry is what lets sessions of
different accounts message each other; it can be switched off (section 5d).

Per account, never shared: credentials, `.claude.json` (account, onboarding flags,
user-scope MCP servers), `projects/` (session history and memory), `plugins/`.

Profile names live in `~/.claude-shared/profiles`, one per line. The wrapper reads that
file on every call, so a new profile works without reopening the shell. The bare word
`main` is always accepted and means the default account.

`~/.claude-shared/multi-claude.conf` holds two facts about this host: where updates come
from (`source=`, a clone or `download`) and, only after an opt-out, `sessions=per-account`.

## 2. Prerequisites on the new VM

- Linux x86_64 or arm64, a normal user (not root), `curl`, `tar`, `python3` (present on
  Ubuntu; `jq` is an acceptable substitute for status parsing).
- Login shell bash or zsh. The script writes one managed block into `~/.bashrc` and/or
  `~/.zshrc`.
- Outbound HTTPS to `claude.ai` for the Claude Code installer and the login, and to
  `raw.githubusercontent.com` for the one-line install and for `multi-claude update`.
- A browser on your laptop for the OAuth login (the VM itself needs no browser).

## 3. Install

### 3a. Get the installer

Two ways. Both end with the same `multi-claude` command in `~/.local/bin`; they differ only
in where `multi-claude update` looks for a new version later (3f).

**Without a clone (the default).** One line downloads the script and runs it:

```bash
curl -fsSL https://raw.githubusercontent.com/robinsound/multi-claude/master/install.sh | bash
```

Options for `install` (3c) go after `bash -s --`, for example
`... | bash -s -- --profiles alt,work`. `install.sh` downloads `setup-multi-claude.sh` to a
temporary file, refuses it unless it is a complete bash script, runs its `install` command
and removes the download. To read the script before running it, download it first:

```bash
curl -fsSLO https://raw.githubusercontent.com/robinsound/multi-claude/master/install.sh
less install.sh && bash install.sh
```

**From a clone.** Keep the clone afterwards: it is where updates are pulled (3f). The
examples use `~/apps/multi-claude`; any path works.

```bash
git clone https://github.com/robinsound/multi-claude.git ~/apps/multi-claude
cd ~/apps/multi-claude
```

No network access to GitHub from the VM? Copy the one script there and run it with
`bash ~/setup-multi-claude.sh install`:

```bash
scp setup-multi-claude.sh <user>@<vm>:~/
```

### 3b. Optional: bring the shared config from another machine

On the machine that already has the working setup:

```bash
curl -fsSL https://raw.githubusercontent.com/robinsound/multi-claude/master/export-shared-bundle.sh | bash
# or, from a clone:  ./export-shared-bundle.sh
#   -> ./multi-claude-shared-<host>-<ts>.tar.gz in the current directory
scp multi-claude-shared-*.tar.gz <user>@<vm>:~/
```

Inside a clone the archive is ignored by git (`.gitignore`). Never commit it: it carries
your settings and hooks. It never contains `.credentials.json`, `.claude.json`, the
session registry or `multi-claude.conf`.

It lists symlinks that point outside `~/.claude-shared` (they dangle on the target unless
the same path exists there; add `--dereference` to copy their content instead).

Review before shipping: `settings.json` carries the permission allow-list and hook
commands; hooks may reference tools the new VM lacks (an MCP server binary, a status-line
renderer). `multi-claude doctor` on the target reports every such reference.

### 3c. Run the installer

The one-liner of 3a already did this with the defaults. With options, pick the form that
matches how you got the installer; the options are the same:

```bash
curl -fsSL .../install.sh | bash -s -- <options>       # without a clone
./setup-multi-claude.sh install <options>              # from a clone

# options:
#   (none)                                    profiles: main + alt
#   --bundle ~/multi-claude-shared-*.tar.gz   start from another machine's shared config (3b)
#   --profiles alt,work                       three accounts
#   --no-share-sessions                       keep the sessions of each account to themselves (5d)
#   --dry-run                                 show the plan, change nothing
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
4. Points every profile's `sessions/` at one registry, `~/.claude-shared/sessions`, so
   sessions of all accounts can list and message each other (5d). Skipped with
   `--no-share-sessions`, and on a host that opted out earlier.
5. Writes `~/.claude-shared/claude-profiles.sh` and adds a 3-line block to the rc
   file(s) (`--shell auto|bash|zsh|both`; auto = the rc files that exist plus the login
   shell's).
6. Copies itself to `~/.local/bin/multi-claude`. It is a copy, not a link, so a clone
   can move or disappear without breaking the command (see 3f for updates).

Nothing is deleted. Re-running is safe: it repairs the wiring of every registered profile
and adds none. `--profiles` on a host that is already set up only adds the names given.

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
multi-claude status
# PROFILE  CONFIG_DIR     LOGGED_IN  ACCOUNT                ORG      SUBSCRIPTION
# main     ~/.claude      yes        you@example.com        Example  team
# alt      ~/.claude-alt  yes        you.alt@example.com    Example  team

multi-claude doctor            # exit 0 = wiring is correct; warnings are advisory
```

### 3f. Updating later

```bash
multi-claude update
```

It gets the latest version from where this installation came from, then runs that
version's `install`, which refreshes the `multi-claude` command, the wrapper and the wiring
of every registered profile. Profiles, logins, settings and the session-sharing choice are
left as they are. When there is nothing new it says `already up to date` and stops.

| Installed with | `update` gets the new version by | If it fails |
|----------------|----------------------------------|-------------|
| `install.sh`, or a copied script | downloading `setup-multi-claude.sh`; a download that is not a complete script is refused and the working command stays | check the network; run it again |
| a clone | `git pull --ff-only` in that clone | fix the clone (local commits, no upstream) and run it again |

`multi-claude doctor` shows which of the two applies. The last way you ran `install`
decides: run the one-liner on a host installed from a clone and updates switch to
downloads; run `install` from a clone and they switch back. If the recorded clone no longer
exists, `update` says so and downloads.

`multi-claude update --dry-run` prints the plan without changing anything. This updates
multi-claude only; `claude update` updates Claude Code itself for every account.

Doing it by hand from a clone is still fine and has the same result:

```bash
cd ~/apps/multi-claude && git pull
tests/run-tests.sh                        # optional: sandboxed, touches no real config
./setup-multi-claude.sh install
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
multi-claude exec alt -p "summarize the failing tests"
CLAUDE_CONFIG_DIR=$HOME/.claude-alt claude -p "..."
```

## 5. Adding, syncing, sharing

### 5a. Adding more accounts

One command per extra account; no reinstall, no shell reload:

```bash
multi-claude add-profile work         # creates ~/.claude-work, wires it, registers it
claude work                           # finish onboarding, then /login as that account
multi-claude status                   # shows which email each profile is logged in as
```

What `add-profile` does: creates `~/.claude-<name>`, symlinks the shared files into it
(CLAUDE.md, settings.json, hooks, commands, rules, skills, agents), links its `sessions/`
to the shared registry so its sessions can message those of the other accounts (unless
this host opted out, 5d), and appends the name to `~/.claude-shared/profiles`. The
`claude()` wrapper reads that file on every call, so `claude work` works at once in every
open shell. Credentials, session history, memory, MCP servers and plugins of the new
account stay in its own directory.

Name rules: lowercase letters, digits, `-` and `_`, starting with a letter or digit.
`main` and `shared` are reserved. An invalid name is rejected before anything is written.

Several at once, or on a fresh VM: `install --profiles alt,work,client` (3c).
Running `install --profiles` on an existing host only adds; nothing is removed.

Removing an account: delete its line from `~/.claude-shared/profiles` (the name stops being
a selector at once). Its directory `~/.claude-<name>` holds the login and the history; keep
it or delete it yourself.

Per new account, as needed:

- Log in over SSH from a private browser window, or the OAuth grant lands on whichever
  account the browser is already signed into. `claude work auth login --email <addr>`
  pre-fills the address.
- MCP servers: `multi-claude sync-mcp main work` copies main's set (see 5b).
- Shared project memory: `multi-claude link-memory <project-dir> work` (see 5c).
- `clauded work` is the skip-permissions variant, same as for `alt`.

There is no cap on the number of profiles. Each one costs one directory and one login.
Rate limits are per account, so profiles run in parallel without interfering.

### 5b. MCP servers and plugins

MCP servers are user-scope per account (they live in each `.claude.json`). Configure
them once on main, then copy:

```bash
claude mcp add -s user context7 -- npx -y @upstash/context7-mcp    # example, on main
multi-claude sync-mcp main alt                                       # copies mcpServers main -> alt
```

Close the target account's Claude sessions first; a running session rewrites its
`.claude.json` on exit. A backup `.claude.json.bak-<ts>` is written every time.

Plugins are per account too: run `/plugin` under each profile, or keep the shared
`settings.json` `enabledPlugins` and let each profile install on first start.

### 5c. Shared project memory

Project memory (the `memory/` notes under `projects/<slug>/`) is per account. To let both
accounts read and write the same notes for a project directory:

```bash
multi-claude link-memory ~/code/my-project          # every profile -> main's memory
multi-claude link-memory ~/code/my-project alt      # only alt
```

### 5d. Sessions of different accounts see and message each other

Claude Code sessions on one machine can list and message each other (the ListAgents and
SendMessage tools, and peer notifications). Claude Code on its own limits that to one
account: `claude` sessions see each other, `claude alt` sessions see each other, and the
two groups are invisible to one another. multi-claude makes every session on the machine a
peer of every other, whichever account it runs on. This is on by default: `install` sets
it up and `add-profile` brings each new account in.

Verify from any session: ask Claude to list its peer sessions. Sessions of the other
accounts appear in the list, and a message to one of them arrives there as a normal peer
message. `multi-claude doctor` and the header of `multi-claude status` show the mode.

How it works. Each session registers itself in `sessions/` inside its config dir
(`<pid>.json` with name, cwd, status and socket path, plus a `<pid>.<hash>.key` peer token,
mode 0600) and discovers peers by reading that directory. The transport is a unix socket
per session under `/run/user/<uid>/cc-socks/`, which every profile of one OS user already
shares. So all it takes is one registry for all profiles:

1. `~/.claude-shared/sessions` is created with mode 0700;
2. the entries found in `~/.claude/sessions` and every `~/.claude-<profile>/sessions` are
   moved into it (an entry that already exists there is never overwritten; the local
   directory is then kept as `sessions.bak-<ts>` instead);
3. each profile's `sessions` becomes a symlink to the shared directory.

Running sessions need no restart: they keep writing to the same relative path, which now
resolves inside the shared directory. `doctor` fails if one profile has dropped out.

Turning it off, and on again:

```bash
multi-claude unshare-sessions     # one registry per account
multi-claude share-sessions       # one registry for all accounts
# on a fresh VM, to never share:  install --no-share-sessions
```

`unshare-sessions` gives every profile a `sessions/` directory of its own, hands the entry
of each running session back to the account it runs on (so those sessions keep seeing the
peers of their own account without a restart), and keeps whatever belongs to no running
session in `~/.claude-shared/sessions.off-<ts>` instead of deleting it. The choice is
written to `~/.claude-shared/multi-claude.conf`, so `install`, `add-profile` and `update`
keep the accounts apart until you run `share-sessions`. Both commands are safe while
sessions are running and accept `--dry-run`.

A host installed before sharing became the default, and never asked either way, is
switched to the shared registry by its next `install` or `update`. `doctor` warns about it
until then. Run `multi-claude unshare-sessions` first to keep such a host per account.

Know before relying on it:

- Undocumented territory. Claude Code documents that sessions must see the same registry
  files to reach each other, but offers no setting for it; a future release could change
  the registry format or start recording the config dir in each entry. `doctor` will show
  a broken link, but not a silently changed format. Checked with Claude Code 2.1.270
  through 2.1.326.
- Peer messages carry a session name, not an account. Names derive from the working
  directory, so nothing tells a main session that `myproject-65` runs on the alt account.
- Same security boundary as before: everything stays owned by one OS user, the registry
  is 0700 and the peer tokens 0600. Nothing is exposed to other users on the machine.
- Unrelated to agent teams: a lead spawns its teammates inside its own session, so a team
  always runs on one account, shared registry or not.
- Project memory and MCP servers stay per account (5b, 5c).

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `claude alt` starts the main account (or treats `alt` as a prompt) | the wrapper is not loaded: `type claude` says "is /home/.../claude" | `source ~/.zshrc` (or `~/.bashrc`); check the rc file ends with the `# >>> multi-claude >>>` block; `multi-claude doctor` |
| both profiles show the same email in `status` | logged in with the same browser session twice | `claude alt` then `/logout`, `/login` in a private window as the alt account |
| `~/.claude/.claude.json` exists (doctor warns) | something ran with `CLAUDE_CONFIG_DIR=~/.claude` | never set that variable for main; main's state is `~/.claude.json`. The stray file is harmless but stale |
| hook errors on every tool call after a bundle import | `settings.json` references a hook or tool missing on this host | `multi-claude doctor` lists them; install the tool, or remove that hook from `~/.claude-shared/settings.json` |
| status line shows an error | `claude-powerline` not installed here | `npm i -g @owloops/claude-powerline` on a node 22 toolchain, or delete `statusLine` from `settings.json` |
| dangling symlink warnings in `~/.claude-shared/skills` | the bundle kept links to repo paths that do not exist here | clone the repo to the same relative path, re-export with `--dereference`, or remove the link |
| `settings.json.bak-<ts>` appeared in a profile dir | that profile had its own settings that differed from the shared copy | diff and merge by hand, then delete the backup |
| a login shell on the new VM cannot see `claude` at all | `~/.local/bin` not on PATH yet | `exec $SHELL -l`; the wrapper file also prepends it |
| a `claude alt` session is missing from a main session's peer list (or the reverse) | this host keeps one registry per account: it opted out, or was installed before sharing became the default | `multi-claude share-sessions` (section 5d); `multi-claude doctor` shows which mode is active |
| doctor: `~/.claude-<p>/sessions is not linked to the shared registry` | sharing is on but that profile's `sessions/` was recreated as a plain dir | `multi-claude share-sessions` again; it moves the stray entries over and re-links |
| the account directory `~/.claude-<name>` exists but `claude <name>` does not select it | it was made by hand and never registered (`doctor` reports it) | `multi-claude add-profile <name>`; it keeps the login and history that are there |
| `multi-claude: command not found` | `~/.local/bin` is not on PATH in this shell, or the host still has only the pre-1.1 `claude-profiles` | `exec $SHELL -l`; on a host that only has `claude-profiles`, run the one-line installer (3a): it installs `multi-claude` and keeps the old name as an alias |
| `multi-claude` lacks a subcommand or fix that is in the repository | `~/.local/bin/multi-claude` is a copy taken at install time | `multi-claude update` (section 3f) |
| `multi-claude update`: `download failed` | no route to `raw.githubusercontent.com`, or `MULTI_CLAUDE_RAW_URL` / `MULTI_CLAUDE_REPO` point somewhere else | fix the network or the variable and run it again; nothing was changed |
| `multi-claude update`: `git pull failed` | the clone it was installed from has local commits, local changes in the way, or no upstream | fix the clone (`git -C <clone> status`) and run it again, or switch to downloads by running the one-line installer (3a) |

Uninstall (keeps every account logged in):

```bash
sed -i '/# >>> multi-claude >>>/,/# <<< multi-claude <<</d' ~/.zshrc ~/.bashrc
rm -f ~/.claude-shared/claude-profiles.sh ~/.claude-shared/multi-claude.conf \
      ~/.local/bin/multi-claude ~/.local/bin/claude-profiles
# ~/.claude, ~/.claude-alt and the symlinks into ~/.claude-shared keep working as they are;
# plain `CLAUDE_CONFIG_DIR=~/.claude-alt claude` still opens the alt account.
# A clone, if you used one, can stay or go; nothing points at it.
# The shared peer-session registry (5d) keeps working too. To split it, run
# `multi-claude unshare-sessions` before removing the command.
```

## 7. Changing the scripts

Run the sandboxed suite before shipping a change:

```bash
tests/run-tests.sh            # ~10 s; fake HOME under mktemp, fake claude and curl
KEEP_SANDBOX=1 tests/run-tests.sh   # keep the sandbox for inspection
```

The harness refuses to run with a real HOME and never touches `~/.claude*` on this host.
It tests copies of the scripts inside the sandbox, never the checkout itself: an install
records where it came from, and a test of `update` run from the checkout would `git pull`
the real repository. Downloads come from a directory in the sandbox through the fake
`curl`, and the `update`-from-a-clone tests build their own origin and clone there.

It covers: fresh install through the installer path, idempotency, adopt/backup rules,
wrapper routing under bash and zsh (12 argument shapes each), add-profile, status,
doctor pass/fail cases, sync-mcp, link-memory, session sharing (on by default, the opt-out
and its persistence, move, link, conflict backup, mode, idempotency, add-profile joining,
unshare-sessions handing entries back to the account of each running session, doctor/status
reporting, export exclusion), the `claude-profiles` alias, install.sh (plain, piped,
failed, truncated and wrong downloads), update by download and from a clone (new version,
nothing new, broken download, non-fast-forward, clone gone), dry-run, bundle export/import
with home rewriting, and shellcheck.
