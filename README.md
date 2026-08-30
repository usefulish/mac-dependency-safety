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
- Packages that execute through non-npm-script build paths (native build files,
  extension hooks, compiler plugins, test hooks, etc.).
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

#### Adding or removing a permission profile — ALWAYS two files, in order

Codex's permission-profile system spans a root-owned ceiling and a user-owned
definition. Editing one side alone either does nothing or bricks Codex:

1. **Define the profile in `~/.codex/config.toml`** (user-writable, mode 600):
   ```toml
   [permissions.<name>]
   extends = ":workspace"
   [permissions.<name>.filesystem]
   "<path>" = "write"   # or "read"/"deny"
   ```
2. **Allowlist it in `/etc/codex/requirements.toml`** (root-owned, needs sudo)
   as a top-level table — a MAP of name to boolean, not a list:
   ```toml
   [allowed_permission_profiles]
   ":read-only"           = true
   ":workspace"           = true
   "<name>"               = true
   ":danger-full-access"  = false
   ```

Hard constraints, both probed (d0b38a31):
- **Every name listed in requirements.toml must already exist in user config.**
  A name listed but undefined makes Codex refuse to start:
  `requirements.toml allowed_permission_profiles refers to undefined profile '<name>'`.
  So step 1 before step 2, always.
- **Removing a profile is the same trap in reverse**: delete the user-config
  definition first and the requirements line second. Removing the definition
  while the allowlist still names it bricks Codex the same way.
- **Placement matters.** Appending `allowed_permission_profiles = {...}` to the
  end of requirements.toml silently nests it under the last table header where
  it is an unknown key, ignored with no diagnostic. Write it as a top-level
  `[allowed_permission_profiles]` table, above the first table header.
- `default_permissions` in requirements is not required once the allowlist
  includes both `:workspace` and `:read-only`.

### 0f. Hermes managed scope
File: `/etc/hermes/config.yaml`
(template: [`managed-settings/hermes.yaml`](./managed-settings/hermes.yaml))

Install by hand:
```bash
sudo mkdir -p "/etc/hermes"
sudo cp managed-settings/hermes.yaml "/etc/hermes/config.yaml"
sudo chown root:wheel "/etc/hermes/config.yaml"
sudo chmod 755        "/etc/hermes"
sudo chmod 644        "/etc/hermes/config.yaml"
```

Hermes' managed scope pins specific config keys above `~/.hermes/config.yaml`,
`~/.hermes/.env` **and** the shell environment, enforced purely by the file's
root ownership. Merging is leaf-level, so a managed list *replaces* the user's
value for that key rather than appending — fold any per-machine deny rules into
the template.

The load-bearing key is `approvals.deny`: matching terminal commands are blocked
*before* `--yolo`, `/yolo` and `approvals.mode: off` are consulted. Verified with
a user config of `mode: off` + `deny: []` still denying.

**Know what this is not.** Hermes has no path-based read guard — no equivalent of
Claude Code's `Read(...)` deny or Codex's `deny_read`. These rules match command
text seen by the `terminal` tool only, so:

- Hermes' own file-read tool is **not** covered by anything here.
- Path traversal defeats it — `cat ~/.config/../.ssh/id_rsa` is allowed.
- An agent running as root, or anyone who can set `HERMES_MANAGED_DIR`, bypasses
  the layer entirely. Fix that variable in the service unit if you depend on it.

It is a guardrail against an honest-but-wrong agent, which is the threat model
Hermes itself states for deny rules — not a sandbox against a hostile one.

Verify behaviourally rather than by presence (`approvals test` evaluates the real
guards and never executes the command; 0 allow, 2 ask, 3 deny):

```bash
hermes approvals test -- cat ~/.ssh/id_rsa   # expect exit 3
hermes approvals test -- cat .env            # expect exit 3
hermes approvals test -- cat prod.envelope   # expect exit 0  <- catches over-broad rules
hermes doctor                                # names the resolved managed dir
```

Hermes already blocks *writes* to credential paths (`~/.ssh`, `.env` anywhere,
its own `auth.json`) natively for `write_file`/`patch` — but not for `terminal`.
Layer 0f covers the read/exfil side of the same paths, as far as command-text
matching can.

### 0h. pi sandbox
Files: `/etc/pi/sandbox.sb`, `/etc/pi/bash`, `/etc/pi/ripgrep.conf` (root-owned)
and `~/.pi/agent/extensions/dependency-safety.ts` (user-owned)
(templates: [`managed-settings/pi/`](./managed-settings/pi/))

[pi](https://github.com/earendil-works/pi-mono) ships **no sandbox and no
managed settings** — its docs say so, and point at containers. Its `bash`
tool runs `bash -c <command>` as you, `read` opens any file, and an A2A-dispatched
worker gets the same tools. This layer bolts a kernel-enforced read guard onto
the tools pi already has, in two halves that are only useful together.

**Root half — the wall.** A Seatbelt profile (the same `sandbox-exec` mechanism
Codex and Antigravity use on macOS) denies reads of credential paths, and a
wrapper runs every agent command under it. Because the kernel resolves the
path, `cat ~/.config/../.ssh/id_rsa`, symlinks and `$(printf …)` tricks all
fail the same way: `Operation not permitted`. Child processes inherit it.

```bash
sudo mkdir -p /etc/pi
sudo cp managed-settings/pi/sandbox.sb   /etc/pi/sandbox.sb
sudo cp managed-settings/pi/bash         /etc/pi/bash
sudo cp managed-settings/pi/ripgrep.conf /etc/pi/ripgrep.conf
sudo chown -R root:wheel /etc/pi
sudo chmod 755 /etc/pi /etc/pi/bash
sudo chmod 644 /etc/pi/sandbox.sb /etc/pi/ripgrep.conf
```

**User half — the pointer.** A pi extension overrides the built-in `bash` tool
to use the wrapper (fail-closed: no wrapper, no bash), overrides the in-process
`read` tool with the same deny set, blocks `write`/`edit` into credential
directories and into its own directory, refuses `grep`/`find`/`ls` aimed into a
credential directory, and gives the `grep` tool's ripgrep the root-owned config
so a content sweep skips secret files.

```bash
mkdir -p ~/.pi/agent/extensions
cp managed-settings/pi/dependency-safety.ts ~/.pi/agent/extensions/
# Then RESTART every long-lived pi process (interactive sessions, the A2A
# host): the extension set is loaded once per process.
```

Install the root half **first**. The extension fails closed, so installing it
alone disables pi's bash tool until `/etc/pi` exists.

**Know what this is not.**

- The wall is root-owned; the pointer is not. Anyone who can write
  `~/.pi/agent` can delete the extension, and `pi --no-extensions` (`-ne`)
  starts a session without it. That is the standing of a user-owned toggle
  (like Antigravity's terminal-sandbox switch, checked as Layer 0g in
  `verify-install.sh`), weaker than 0a/0b/0f where the agent consults the
  root-owned file directly. pi has no managed-config path to fix that today.
  `verify-install.sh` therefore checks the installed extension byte-for-byte
  against the template and root ownership plus modes of `/etc/pi` and its
  three files — a user-writable directory would let the agent swap the
  profile for an allow-all one between two bash calls.
- **Known hole: pre-existing hard links.** Seatbelt and the guard both decide
  by path. A hard link to `~/.ssh/id_rsa` that already sits at an allowed path
  reads normally (verified 2026-08-30). Creating one from inside the sandbox
  is denied, pi's tools cannot create one, and it needs the same filesystem —
  so it takes prior local access. Symlinks are caught: the kernel resolves
  them before the deny applies, and the guard checks both the path as written
  and its resolved target (through the deepest existing parent, so a new file
  under a symlinked directory is judged by where it would really land).
- `grep` gets two extra rules because ripgrep's own precedence undoes a config
  file: an explicit file operand runs in single-file mode where `--glob`
  exclusions do not apply, and the tool's `glob` argument comes after the
  config so `**` re-includes everything. The hook applies the read deny set to
  grep targets and rejects globs that would match a secret name; it also
  blocks `grep` outright when `/etc/pi/ripgrep.conf` is missing. Note pi's
  standard tool set is `read, bash, edit, write` — `grep`/`find`/`ls` are
  guarded when enabled (`--tools` or `defaultTools`), not on by default.
- The `read`/`write`/`grep` guards are in-process path checks, not a sandbox.
  Another extension or an MCP server in the same pi process has the process's
  full permissions.
- **`~/.npmrc` is deliberately readable inside the sandbox.** Layer 1's
  `ignore-scripts=true` lives there; with it denied, npm inside the sandbox
  silently reports `ignore-scripts=false` and runs install scripts again
  (verified 2026-08-30). Project-local `.npmrc` files are still denied, and pi's
  `read` tool denies `~/.npmrc` regardless. Codex's Layer 0b denies `~/.npmrc`
  sandbox-wide — check whether npm inside a Codex sandbox still honours Layer 1
  before relying on it there.
- Parity costs, same as Codex: `gh` inside pi's bash loses its auth
  (`~/.config/gh` is denied), and `.env.example` is unreadable because 0a/0b
  deny `.env.*` and this layer matches them. Run `gh` from your own shell.
- `sandbox-exec` is deprecated by Apple. It still works on macOS 26.3.1; the
  verify probe below is what tells you when it stops.

Verify behaviourally, both directions, plus the Layer 1 interaction:

```bash
/etc/pi/bash -c 'ls ~/.ssh'                    # expect: Operation not permitted
/etc/pi/bash -c 'cat /etc/hosts'               # expect: success
/etc/pi/bash -c 'npm config get ignore-scripts' # expect: same as outside (true)
stat -f '%Su:%Sg %Lp' /etc/pi /etc/pi/*         # expect: root:wheel 755 (dir, bash) / 644 (sandbox.sb, ripgrep.conf)
cmp ~/.pi/agent/extensions/dependency-safety.ts managed-settings/pi/dependency-safety.ts  # expect: silent
bash verify-install.sh                          # Layer 0h section does all of the above
```

Live receipt (2026-08-30, pi 0.84.4, macOS 26.3.1, glm-5.3 via agentrouter):
in a `pi -p` session with the extension loaded, `bash: cat ~/.ssh/<file>`
returned `Operation not permitted`; `read` on a fixture `.env` and on a
non-existent `~/.ssh/…` path returned the guard's denial while `.envelope`
read normally; `write ~/.ssh/zzz_probe` was blocked and the file did not
appear; `write` to a scratch file succeeded. Review-driven re-run the same
day (`--tools read,grep,ls,bash`): `@`-prefixed and `file://` paths were
judged like plain ones; a `.env.link` symlink to a benign file was denied by
name; a `write` under a symlink to `~/.ssh` was blocked with no artifact;
`grep` on an explicit `.env`, `grep` with `glob **`, and `ls` through the
symlink were all denied while `grep` with `glob *.txt` and a path-less `grep`
ran with `.env` excluded. A2A child sessions load the same global extension
set but were not exercised (the host needs a restart first).

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

#### Why there is no root-owned anchor (investigated 2026-08-15)

Cursor 3.15.6 has **no admin-managed path-permission layer**, and what exists
is not usable as one:

- `~/.cursor/sandbox-policies/` looks like a config surface but is Cursor's
  **internal scratch transport**: files are written mode 0600 with a
  `sandbox-policy-*` prefix and **garbage-collected after 1 hour** by mtime
  (`packages/shell-exec/src/sandbox/policy-file.ts`, env override
  `CURSOR_SANDBOX_POLICY_DIR`). A file you place there is either ignored (wrong
  prefix) or deleted (right prefix, old). It is also user-owned (mode 700),
  which gives it no more standing than `chflags` anyway. Do not build a layer
  on it.
- The app **ships** an MDM-format profile,
  `app/policies/com.todesktop.230313mzl4w4u92.mobileconfig` (keys:
  `UpdateMode`, `SignInEnforcement`, `WorkspaceTrustEnabled`, `AllowedExtensions`,
  `AllowedLoginDomains`), which WOULD be a root-anchored layer if deployed via
  macOS profile installation — but it currently contains **no path-permission
  keys**, and the fleet has no profile-install infrastructure. Worth revisiting
  if Cursor extends that payload; until then Layer 0c stays a speed bump and
  the README says so.

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

The template uses `"failClosed": true`, so a broken or missing hook blocks the MCP
call instead of silently allowing it. Loosen to `false` only if the hook proves
too disruptive for your normal workflow.

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

Watch for native build paths. Packages with native components (`binding.gyp` /
`node-gyp`) can get install-time execution without an obvious `preinstall` or
`postinstall` script in `package.json`, especially when script blocking is
loosened for a build-on-install dependency. Treat unexpected native builds in a
new dependency as high-risk: read the tarball, prefer a known-good locked
version, or install it in a throwaway container. This is why the ceiling at the
bottom is still "isolate what you don't trust", not "set one npm flag".

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

Private/internal packages: use scoped names and explicit private registry
routing. Dependency-confusion attacks publish public packages with names or
inflated versions that beat an intended internal package. Do not rely on "this
name only exists inside our company" as a control.

If you publish npm packages, remove long-lived publish tokens where you can:
use npm Trusted Publishing/OIDC, require 2FA, consider staged publishing for CI
releases, and keep any install-only token read-only. This does not protect you
from installing a malicious dependency, but it reduces the chance that your
machine or CI runner becomes the next publisher in the chain.

Provenance is useful review signal, not a trust guarantee:
```bash
npm audit signatures
```
Run it after `npm ci` when you want to verify registry signatures/provenance for
the resolved tree. A valid attestation says where a package came from; it does
not say the package is safe.

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
If you publish Python packages, prefer PyPI Trusted Publishing and attestations
over long-lived upload tokens. Treat attestations the same way as npm
provenance: useful for origin/tamper review, not proof that the code is benign.

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
- Install Homebrew itself only from `brew.sh` or the official Homebrew GitHub
  org. Sponsored search results and lookalike "fix your install" pages are a
  separate malware delivery path.
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

## Fleet onboarding: sandbox by default

A new machine's agents should be sandboxed *because it was onboarded*, not
retrofitted later. `onboard-agents.sh` is the agent-harness step of the fleet's
machine-onboarding process (reference card `machine-onboarding.md`, Phase 4.5)
and it ends on checks that bind, not on files being present:

```bash
bash onboard-agents.sh                    # 1. harden-deps.sh (all layers this box supports; sudo once)
                                          # 2. knowfleet-gate into EVERY Hermes profile + global,
                                          #    verified via `hermes -p <p> plugins list --plain --no-bundled`
                                          # 3. verify-install.sh as the acceptance gate — any FAIL
                                          #    not named with --allow-fail exits 1
bash onboard-agents.sh --check            # existing machine: verify-only (steps 2 + 3)
bash onboard-agents.sh --allow-fail Cursor  # accept a KNOWN pre-onboarding gap; record it in the machine card
```

Step 2 lives in the knowfleet repo (`harness/hermes/install-gate.sh`; set
`KNOWFLEET_REPO` if it is not at `~/Code/active/knowfleet`) because that is
where the canonical plugin lives. Why it verifies discovery rather than
config: a `plugins.enabled: [knowfleet-gate]` entry with no plugin files is
inert and looks healthy — four profiles ran ungated that way (record
`1abe4c95`). Only Hermes's own `plugins list` proves the plugin loads.

Where the harness differs, the layer differs — say so in the machine card:

| Platform | Applies | Does not apply | Watch for |
|---|---|---|---|
| macOS (kimchi, laksa) | 0a, 0b, 0c–0e, 0f, 0g, 0h, 1–3 | — | restart pi hosts / Hermes gateways after install |
| Linux (bingsu) | 0a (`/etc/claude-code/managed-settings.json`), 0b, 0f, 1, 2 | 0h (`sandbox-exec`), Cursor, Homebrew | pi on Linux stays **unsandboxed** until a bubblewrap port exists |
| Unraid (rougamo) | as Linux, but `/etc` is rebuilt at boot | 0h, Cursor, Homebrew | re-apply root-owned files from `/boot/config/go`; agents run as **root**, which bypasses Layer 0f and makes any root-owned "ceiling" editable |

The acceptance gate is deliberately strict: a machine whose verify run shows a
FAIL is not onboarded, and a known gap has to be named on the command line —
which is the moment to write it into the machine card rather than forget it.

## Using the script (optional)

After you've read [`harden-deps.sh`](./harden-deps.sh) and the
[`managed-settings/`](./managed-settings/) templates it may install:
```bash
less harden-deps.sh        # actually read it
bash harden-deps.sh        # applies Layers 0a-0h (where the harness is installed) and 1-3; prompts for sudo once
```
Layer 4 (`AGENTS.md`) is manual — project or global install per section above.
Layer 0h's extension is installed only after its root half succeeds (it fails
closed); Layers 0f and 0h are skipped when `hermes`/`pi` are not on PATH, and 0h
is skipped on Linux.
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

## Monthly review reminder

The repo includes a GitHub Actions workflow that opens one issue on the first
day of each month:

```text
.github/workflows/monthly-threat-review.yml
```

It does not scan the internet or edit files. It creates a checklist issue so a
human can review current npm, PyPI, Homebrew, AI-agent, and MCP risks, then make
only the updates that still fit this repo's "sane baseline" scope. You can also
run it manually from GitHub: **Actions → Monthly threat baseline review → Run
workflow**.

GitHub only runs scheduled workflows from the default branch, and the repository
must have Issues enabled. If your repo or organization restricts the default
`GITHUB_TOKEN` to read-only, allow Actions to create issues in repository
settings.

To change the cadence, edit the `cron` line in that workflow. GitHub schedules
use UTC.

## License

MIT. No warranty — this is a starting point, not a guarantee.
