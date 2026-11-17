# multi-claude

Run several Claude Code accounts on one Linux machine, side by side:

```bash
claude          # main account
claude alt      # second account
claude work     # any other account you add
```

Every account shares one set of instructions, settings, hooks, commands, rules, skills and
agents, so you maintain them once. Logins, history, memory, MCP servers and plugins stay
separate per account. Sessions of all accounts can list and message each other.

## Install

One line, nothing to clone:

```bash
curl -fsSL https://raw.githubusercontent.com/robinsound/multi-claude/master/install.sh | bash
```

Then reload the shell and log in each account once:

```bash
exec $SHELL -l
claude          # main account: type /login
claude alt      # second account: type /login (sign in from a private browser window)
multi-claude status      # shows which account each profile is logged in as
```

That is the whole setup. The installer adds Claude Code itself if it is missing, creates
the `main` and `alt` accounts, and leaves a `multi-claude` command in `~/.local/bin`. It
deletes nothing, and running it again is safe.

Requirements: Linux, bash or zsh as your shell, `curl`, `tar`, `python3`. Run it as the
user who will use Claude, not as root.

<details>
<summary>Install options, and installing from a clone</summary>

Options go after `bash -s --`:

```bash
curl -fsSL .../install.sh | bash -s -- --profiles alt,work    # three accounts from the start
curl -fsSL .../install.sh | bash -s -- --dry-run              # show the plan, change nothing
curl -fsSL .../install.sh | bash -s -- --no-share-sessions    # sessions do not cross accounts
curl -fsSL .../install.sh | bash -s -- --bundle ~/shared.tar.gz   # start from another machine's shared config
```

From a clone instead (updates then come through `git pull`):

```bash
git clone https://github.com/robinsound/multi-claude.git ~/apps/multi-claude
~/apps/multi-claude/setup-multi-claude.sh install
```

`multi-claude help` lists every option. [RUNBOOK.md](RUNBOOK.md) section 3 walks through
each step, including how to carry your shared config over from another machine.

</details>

## Use

| Command | What it does |
|---------|--------------|
| `claude` | main account |
| `claude alt` | the `alt` account; any claude flag works after it, e.g. `claude alt --resume <id>` |
| `clauded alt` | the same, with `--dangerously-skip-permissions` |
| `multi-claude status` | which account each profile is logged in as |
| `multi-claude doctor` | checks the whole setup and says how to fix what it finds |
| `multi-claude exec alt -p "..."` | run an account from cron, scripts or `ssh host '...'`, where the shell function is not loaded |

Run the accounts at the same time in separate terminals; rate limits are per account.

## Add an account

```bash
multi-claude add-profile work     # 1. create the account profile "work"
claude work                       # 2. start it and type /login as that account
multi-claude status               # 3. check: "work" shows the right email
```

Pick any name made of lowercase letters, digits, `-` and `_` (`main` and `shared` are
taken). `claude work` works at once in every open shell, with no reinstall and no reload,
and there is no limit on the number of accounts.

Step 2 opens a login URL. Open it in a private browser window and sign in as the new
account; a normal window is usually still signed in to another account, and the login
would land there. `claude work auth login --email you@example.com` pre-fills the address.

The new account starts with the shared instructions, settings and hooks, and its sessions
can message the sessions of the other accounts. Optional extras:

```bash
multi-claude sync-mcp main work               # copy main's MCP servers to it
multi-claude link-memory ~/code/my-project    # share one project's memory notes across accounts
```

## Sessions talk across accounts

Claude Code sessions on one machine can see and message each other (the ListAgents and
SendMessage tools). Out of the box that stops at the account boundary. multi-claude removes
the boundary: every session on the machine is a peer of every other, whichever account it
runs on. Ask any session to list its peer sessions to see it.

It is on by default. To keep the accounts apart, and to bring them back together:

```bash
multi-claude unshare-sessions     # one registry per account again; remembered across updates
multi-claude share-sessions       # back to one registry for all accounts
```

Both are safe while sessions are running. Details and caveats: RUNBOOK section 5d.

## Update

```bash
multi-claude update
```

It fetches the latest multi-claude (a download, or `git pull` when you installed from a
clone) and re-applies it. Accounts, logins and settings are left as they are. Claude Code
itself is updated separately with `claude update`.

## What is shared, what is not

| Shared by every account (`~/.claude-shared`) | Separate per account (`~/.claude`, `~/.claude-<name>`) |
|---|---|
| `CLAUDE.md`, `settings.json`, `hooks/`, `commands/`, `rules/`, `skills/`, `agents/` | login and credentials |
| the registry sessions use to find each other | session history and project memory |
| | MCP servers and plugins |

## More

- [RUNBOOK.md](RUNBOOK.md): step-by-step install, moving your config to another machine,
  MCP servers and memory, troubleshooting, uninstall.
- `multi-claude help`: every command and option.
- `tests/run-tests.sh`: the sandboxed test suite; run it after changing the scripts.

Files in this repository: `install.sh` (the one-line installer), `setup-multi-claude.sh`
(everything else; it installs itself as `multi-claude`), `export-shared-bundle.sh` (packs
`~/.claude-shared` for another machine, never with credentials).
