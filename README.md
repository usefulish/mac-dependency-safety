# mac-dependency-safety

Opinionated, macOS-only hardening to reduce the blast radius of installing
untrusted packages (npm / pip / Homebrew) and to stop malware from weaponizing
your local AI coding agents.

This is a pragmatic **something rather than nothing** baseline for macOS
developers, especially people moving quickly with AI coding agents. It blocks
the easiest install-script and agent-bypass failure modes, makes risky
dependency changes more visible, and adds friction around common secret paths.
It is not a sandbox and does not make untrusted packages safe.

> **Read this before running anything here.** This repo exists because package
> managers run arbitrary code as you at install time. Piping a stranger's setup
> script into your shell to defend against *that* is self-defeating. So: the
> README is the deliverable. Every step below is a hand-runnable command. The
> script (`harden-deps.sh`) is a convenience that does exactly what's documented
> here and nothing more — read it, then decide. It's short on purpose.

## What this is (and isn't)

It is layered friction plus one hard block. It is **not** a force field.
Every install below still runs as your user, with your files and tokens in
reach. The only thing that truly *contains* a bad package is installing it
where there's nothing to steal (a throwaway container). Treat these settings as
the everyday guard that catches careless mistakes, and a container as the
seatbelt for installs you don't trust.

Things this does **not** protect against:

- Malicious code you deliberately run outside these defaults.
- Packages that execute through non-npm-script build paths.
- Browser/session-cookie theft, malicious editor extensions, shell profile
  tampering, or secrets already loaded into environment variables.
- Tool config drift. AI CLI and editor policy formats change; verify after
  installing and after upgrading tools.

Scope: **macOS only.** Tested against **Claude Code v2.1.x** — these settings
drift, so check the [Claude Code docs](https://code.claude.com/docs/en/permission-modes)
if a key doesn't behave as described.

## Why (the nx hack)

In August 2025, compromised `nx` npm packages shipped a `postinstall` hook that
harvested SSH keys, `.env` files, and GitHub/npm tokens — and, novelly, invoked
locally installed AI CLIs (`claude --dangerously-skip-permissions`,
`gemini --yolo`, `q --trust-all-tools`) to do the filesystem recon for it. Live
for ~5 hours before removal. This repo is the set of defaults that would have
blunted it.

---

## Layer 0 — Stop AI Agents being turned into accomplices

System-level managed settings that **no user or project config can override**.
Blocks bypass modes (flags like `--yolo` or `--dangerously-skip-permissions`) and
denies the agent permission to read common secret files.

### 0a. Claude Code
File: `/Library/Application Support/ClaudeCode/managed-settings.json`
(template: [`managed-settings/claude.json`](./managed-settings/claude.json))

Install by hand:
```bash
sudo mkdir -p "/Library/Application Support/ClaudeCode"
sudo cp managed-settings/claude.json "/Library/Application Support/ClaudeCode/managed-settings.json"
sudo chown root:wheel "/Library/Application Support/ClaudeCode/managed-settings.json"
sudo chmod 644        "/Library/Application Support/ClaudeCode/managed-settings.json"
```

### 0b. Codex
File: `/etc/codex/requirements.toml`
(template: [`managed-settings/codex.toml`](./managed-settings/codex.toml))

Install by hand:
```bash
sudo mkdir -p "/etc/codex"
sudo cp managed-settings/codex.toml "/etc/codex/requirements.toml"
sudo chown root:wheel "/etc/codex/requirements.toml"
sudo chmod 644        "/etc/codex/requirements.toml"
```

### 0c. Cursor settings (a speed bump, not a wall)
Cursor stores its settings in user-writable JSON files. A malicious `postinstall`
script can `sed` these to enable bypass modes. Setting your safety defaults and
then making the file **immutable** raises the bar — but be honest about how high.

```bash
# Lock Cursor settings (see Lock ritual in 0d for the full file list)
chflags uchg "$HOME/Library/Application Support/Cursor/User/settings.json"
```
*`chflags uchg` is the **user** immutable flag: its owner can clear it without
root (`chflags nouchg <file>`), so a targeted payload running as you can unset
it, edit, and re-set it. This stops unsophisticated scripts that blindly `sed`,
not a determined attacker. Contrast with 0a/0b above, whose root-owned files a
non-root process genuinely cannot touch — those are the real walls; this is a
speed bump. You must also run `chflags nouchg <file>` to unlock before making
legitimate changes.*

### 0d. Cursor MCP (friction without enterprise MDM)

MCP servers are install-time-equivalent risk: each one is a long-lived process
that can read files, call APIs, and run shell commands as you. Unlike Claude
Code, Cursor has no macOS **managed** MCP policy for personal accounts — so the
playbook is: **keep default approvals**, **allowlist only boring tools for
auto-run**, **pin server packages**, and **lock the config files** malware would
edit.

#### Defaults (do this in Cursor Settings first)

1. **Settings → Agents → Auto-run:** use **Ask every time** or **Allowlist
   (sandboxed)** — not **Run everything**.
2. **Settings → Tools & MCP:** disable servers you do not use (toggle off, do not
   delete — easy to turn back on).

#### 0d-1. MCP auto-run allowlist (small on purpose)

File: `~/.cursor/permissions.json`
(template: [`managed-settings/cursor-permissions.json`](./managed-settings/cursor-permissions.json))

The `mcpAllowlist` array uses `server:tool` entries (`context7:*`, `myserver:search`,
etc.). **Never add `*:*`.** That auto-runs every MCP tool without prompts.

Install by hand (only if the file does not exist yet — edit the template first):

```bash
mkdir -p "$HOME/.cursor"
cp managed-settings/cursor-permissions.json "$HOME/.cursor/permissions.json"
# Edit: replace "context7" with servers you actually use and trust for auto-run.
```

Loosen: remove entries from `mcpAllowlist`, or delete the file.

#### 0d-2. Global MCP servers (pinned)

File: `~/.cursor/mcp.json`
(example: [`managed-settings/mcp.json.example`](./managed-settings/mcp.json.example))

- Prefer a **small** global file for personal utilities; put stack-specific servers
  in **`.cursor/mcp.json` inside the repo** (commit it so the team reviews it).
- Pin versions in `args` (`@scope/pkg@1.2.3`), not `@latest` — pairs with Layer 1
  `ignore-scripts`.
- Put secrets in the environment (`${env:GITHUB_TOKEN}`), not in the JSON file.
- Avoid `envFile` pointing at a project `.env` for third-party servers.

```bash
mkdir -p "$HOME/.cursor"
cp managed-settings/mcp.json.example "$HOME/.cursor/mcp.json"
# Edit: pin real versions (npm view @upstash/context7-mcp version), add only what you need.
```

Project-level (per repo): `.cursor/mcp.json` in the project root overrides global
entries with the same server name. Do not open untrusted repos with Agent enabled
if the repo ships its own `.cursor/mcp.json` — treat that like a dependency you
did not review.

#### 0d-3. Optional deny hook (secret paths + @latest)

Hooks can **deny** risky MCP calls; they cannot grant auto-approval. Templates:

- [`managed-settings/cursor-hooks.json`](./managed-settings/cursor-hooks.json)
- [`managed-settings/hooks/deny-risky-mcp.sh`](./managed-settings/hooks/deny-risky-mcp.sh)

Install by hand:

```bash
mkdir -p "$HOME/.cursor/hooks"
cp managed-settings/hooks/deny-risky-mcp.sh "$HOME/.cursor/hooks/"
chmod +x "$HOME/.cursor/hooks/deny-risky-mcp.sh"
# Merge beforeMCPExecution into ~/.cursor/hooks.json, or copy the template if you have no hooks yet:
cp managed-settings/cursor-hooks.json "$HOME/.cursor/hooks.json"
```

If you already have `~/.cursor/hooks.json`, add the `beforeMCPExecution` block from
the template instead of overwriting.

#### Lock ritual (after you are happy with the files)

Unlock → edit → restart Cursor → verify → lock. Same idea as 0c; includes MCP files.

```bash
CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"
MCP_JSON="$HOME/.cursor/mcp.json"
MCP_PERMS="$HOME/.cursor/permissions.json"

# Unlock (only when adding/changing MCP or agent settings)
chflags nouchg "$CURSOR_SETTINGS" "$MCP_JSON" "$MCP_PERMS" 2>/dev/null || true

# ... edit files, quit and reopen Cursor, confirm MCP still works ...

# Lock (blocks postinstall from silently adding servers or widening auto-run)
chflags uchg "$CURSOR_SETTINGS"
[[ -f "$MCP_JSON" ]]   && chflags uchg "$MCP_JSON"
[[ -f "$MCP_PERMS" ]]  && chflags uchg "$MCP_PERMS"
```

`harden-deps.sh` prints these paths and copies templates when safe; it does **not**
run `chflags` for you (you should verify MCP works before locking).

---

## Layer 1 — npm

Disable lifecycle scripts globally (this alone stops the nx pattern):
```bash
npm config set ignore-scripts true
```
Tradeoff: packages that legitimately build on install must be run by hand.
```bash
npx puppeteer browsers install chrome   # e.g. puppeteer's chromium download
npm rebuild <pkg>                        # native modules (sharp, better-sqlite3)
npx can-i-ignore-scripts                 # audit which deps actually need scripts
```
Cooldown (bad versions are usually pulled within hours/days):
```bash
npm install <pkg> --before="$(date -v-7d +%Y-%m-%d)"   # version as of a week ago
```
(pnpm has a native `minimumReleaseAge` setting that does this automatically.)
pnpm frozen install: `pnpm install --frozen-lockfile` (same discipline as `npm ci`).
yarn: `yarn install --immutable`.

Commit the lockfile and install with `npm ci`, not `npm install`. `ci` treats
`package-lock.json` as authoritative and fails on drift; `install` rewrites it
silently. This pins you *between* updates so a freshly-published malicious
version can't slip in on a routine install, and any change to the tree lands in
a reviewable diff (same idea as the Brewfile in Layer 3, one layer down).
```bash
npm ci                # reproducible install from the lockfile — CI and local default
npm install <pkg>     # only when deliberately adding or bumping a dep
```
Pairs with the cooldown above: the lockfile guards the gap *between* updates,
the `--before` window guards the *moment* you update. Neither neuters a payload
that already landed — that's what `ignore-scripts` is for. Three cheap layers,
different points in the chain.

Loosen: `npm config delete ignore-scripts`

---

## Layer 2 — pip

There's no clean `ignore-scripts` equivalent: for source distributions the build
*is* arbitrary code execution. Two defaults that hold up:

Refuse installs outside a virtualenv (prevents accidental system/global installs):
```bash
python3 -m pip config set global.require-virtualenv true
```
> Note: this is deliberately chosen over a global `--only-binary :all:`, which
> would break editable installs of your own projects (`pip install -e .` builds
> from source). Keep `--only-binary` as a per-install habit instead.

For untrusted packages, prefer pre-built wheels (skip install-time code):
```bash
python3 -m pip install --only-binary :all: <pkg>
```
Pin real dependencies with hashes so a package can't silently swap versions:
```bash
pip install --require-hashes -r requirements.txt   # lockfile via pip-compile or uv
```
Also: never `sudo pip`.

Loosen: `python3 -m pip config unset global.require-virtualenv`

---

## Layer 3 — Homebrew

`brew` runs as your user on its own prefix, so most installs never get root —
good. **But** formulae run arbitrary Ruby, and **casks that ship a `.pkg` run
the macOS installer as root** once you enter your password. There's no
ignore-scripts equivalent; the lever is *source trust*.

- Stick to `homebrew/core` and `homebrew/cask` — reviewed, CI'd, PR process.
- Treat any third-party `brew tap` like a random npm package: unreviewed code.
- Extra scrutiny for casks installing `.pkg` (root execution).
- Inspect before installing from an untrusted tap:
  ```bash
  brew info <formula>
  brew cat  <formula>        # read the actual Ruby
  brew deps --tree <formula>
  ```
- Checksums protect against tampered downloads, not a compromised upstream whose
  formula was updated to match.

Curate instead of accumulate:
```bash
brew bundle dump --file=~/Brewfile               # snapshot current installs
brew bundle cleanup --file=~/Brewfile            # dry run: list cruft not listed
brew bundle cleanup --file=~/Brewfile --force    # actually remove it
```
Version-control the Brewfile → the machine's software becomes a reviewable
allowlist.

---

## Layer 4 — Agent defaults (soft)

A shared instruction file that nudges AI coding agents (Claude Code, Cursor,
Codex) toward the Layer 1 lockfile hygiene (`npm ci` by default,
`npm install <pkg>` only to add/bump) and Layer 0d MCP hygiene (no new servers
unless asked).

> **Softest layer in the repo — a default, not a control.** Agents usually follow
> these instructions; they can also ignore them, and malware doesn't read them at
> all. Layer 0 *distrusts* the agent and hard-blocks it; this layer *cooperates*
> with the agent and asks nicely. Don't mistake one for the other. This is a
> sibling to Layer 1's npm guidance, not to Layer 0's enforcement.

One file, three tools. `AGENTS.md` is read natively by Codex and Cursor; Claude
Code pulls it in via its `@import` syntax. Write the rule once
(template: [`agent-instructions/AGENTS.md`](./agent-instructions/AGENTS.md)),
import it everywhere — no three-way drift.

### Project scope (per repo — the clean case)

Drop the file at your repo root and point the two import-based tools at it:
```bash
cp agent-instructions/AGENTS.md ./AGENTS.md     # Codex + Cursor read this directly
grep -qF '@AGENTS.md' ./CLAUDE.md 2>/dev/null || printf '@AGENTS.md\n' >> ./CLAUDE.md
```
Commit both. Anyone opening the repo in any of the three tools gets the same
default.

### Global scope (default across all your projects)

Each tool has its own home dir; point them all at one canonical copy:
```bash
mkdir -p ~/.config/agent-instructions
cp agent-instructions/AGENTS.md ~/.config/agent-instructions/AGENTS.md
AGENTS="$HOME/.config/agent-instructions/AGENTS.md"

ln -sf "$AGENTS" ~/.codex/AGENTS.md              # Codex reads it natively
# Append once — re-running duplicates the import line. Check the file first:
grep -qF "@$AGENTS" ~/.claude/CLAUDE.md 2>/dev/null || printf '@%s\n' "$AGENTS" >> ~/.claude/CLAUDE.md
```
**Cursor is the holdout:** its global rules live in Settings → Rules (a UI field,
not a file), so paste the rule there by hand. It's five lines.

> Formats drift and not every version's `@import` takes an absolute path. If an
> import doesn't resolve, symlink the tool's file to the canonical one or just
> paste the five lines in — then confirm it actually loaded (Claude Code:
> `/memory`; Codex: it echoes the instruction files it read on start).

Loosen: delete the stub/import line, or the rule block inside `AGENTS.md`.

---

## The ceiling: isolate what you don't trust

Everything above runs as you. For anything genuinely sketchy, install it in a
throwaway Docker container or scratch VM where there's nothing worth stealing.
When in doubt, container.

---

## Using the script (optional)

After you've read [`harden-deps.sh`](./harden-deps.sh) and the
[`managed-settings/`](./managed-settings/) templates it may install:
```bash
less harden-deps.sh        # actually read it
bash harden-deps.sh        # applies Layers 0a-0d and 1-3; prompts for sudo once
```
Layer 4 (`AGENTS.md`) is manual — project or global install per section above.
It guards each tool behind a presence check, won't clobber an existing
`~/Brewfile` or existing `~/.cursor/mcp.json`, tags every loosenable line with
`# LOOSEN:`, and prints final state. Nothing in it isn't in this README.

## Verify the install

After installing, run the read-only verification:
```bash
bash verify-install.sh
```

This checks that the expected safety settings are installed, confirms that Codex
dangerous bypass requests are constrained, and points out anything still worth
reviewing. Treat warnings as a review queue, not automatic failure; some tools
may simply not be installed on your machine.

## License

MIT. No warranty — this is a starting point, not a guarantee.
