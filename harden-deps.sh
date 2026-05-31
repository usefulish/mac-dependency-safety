#!/usr/bin/env bash
#
# harden-deps.sh - apply strict dependency-install safety settings (macOS).
# Companion to the README in this repo. READ BOTH BEFORE RUNNING.
#
# This uses sudo (Layer 0) and changes global npm/pip config. It does only what
# the README documents. Re-runnable. Loosen later by reversing lines marked LOOSEN.
#
# Run from the repo directory:  bash harden-deps.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  – %s\n' "$1"; }

# ---------------------------------------------------------------------------
say "Layer 0: AI Agent managed settings (block bypass mode + secret reads)"

# 0a. Claude Code
SRC_CLAUDE="$SCRIPT_DIR/managed-settings/claude.json"
DEST_DIR_CLAUDE="/Library/Application Support/ClaudeCode"
DEST_CLAUDE="$DEST_DIR_CLAUDE/managed-settings.json"
if [[ -f "$SRC_CLAUDE" ]]; then
  echo "  Installing Claude Code managed settings..."
  sudo mkdir -p "$DEST_DIR_CLAUDE" \
    && sudo cp "$SRC_CLAUDE" "$DEST_CLAUDE" \
    && sudo chown root:wheel "$DEST_CLAUDE" \
    && sudo chmod 644 "$DEST_CLAUDE" \
    && ok "Claude Code: Installed (verify with /status)"
else
  skip "Claude template not found at $SRC_CLAUDE"
fi

# 0b. Codex
SRC_CODEX="$SCRIPT_DIR/managed-settings/codex.toml"
DEST_DIR_CODEX="/etc/codex"
DEST_CODEX="$DEST_DIR_CODEX/requirements.toml"
if [[ -f "$SRC_CODEX" ]]; then
  echo "  Installing Codex managed settings..."
  sudo mkdir -p "$DEST_DIR_CODEX" \
    && sudo cp "$SRC_CODEX" "$DEST_CODEX" \
    && sudo chown root:wheel "$DEST_CODEX" \
    && sudo chmod 644 "$DEST_CODEX" \
    && ok "Codex: Installed (bypass modes disabled)"
else
  skip "Codex template not found at $SRC_CODEX"
fi

# ---------------------------------------------------------------------------
say "Layer 0e: Cursor MCP (templates + optional deny hook)"
CURSOR_DIR="$HOME/.cursor"
MCP_JSON="$CURSOR_DIR/mcp.json"
MCP_PERMS="$CURSOR_DIR/permissions.json"
SRC_MCP_EXAMPLE="$SCRIPT_DIR/managed-settings/mcp.json.example"
SRC_MCP_PERMS="$SCRIPT_DIR/managed-settings/cursor-permissions.json"
SRC_HOOKS_JSON="$SCRIPT_DIR/managed-settings/cursor-hooks.json"
SRC_DENY_HOOK="$SCRIPT_DIR/managed-settings/hooks/deny-risky-mcp.sh"

mkdir -p "$CURSOR_DIR/hooks"

if [[ -f "$SRC_MCP_PERMS" ]]; then
  if [[ -f "$MCP_PERMS" ]]; then
    skip "permissions.json exists — edit it or remove before copying template"
  else
    cp "$SRC_MCP_PERMS" "$MCP_PERMS"
    ok "Wrote $MCP_PERMS (edit mcpAllowlist, then lock with chflags — see README 0e)"
  fi
else
  skip "cursor-permissions.json template not found"
fi

if [[ -f "$SRC_MCP_EXAMPLE" ]]; then
  if [[ -f "$MCP_JSON" ]]; then
    skip "mcp.json exists — compare with managed-settings/mcp.json.example manually"
  else
    cp "$SRC_MCP_EXAMPLE" "$MCP_JSON"
    ok "Wrote $MCP_JSON from example (pin versions, trim servers, then lock)"
  fi
else
  skip "mcp.json.example not found"
fi

if [[ -f "$SRC_DENY_HOOK" ]]; then
  cp "$SRC_DENY_HOOK" "$CURSOR_DIR/hooks/deny-risky-mcp.sh"
  chmod +x "$CURSOR_DIR/hooks/deny-risky-mcp.sh"
  ok "Installed deny hook at $CURSOR_DIR/hooks/deny-risky-mcp.sh"
  if [[ -f "$CURSOR_DIR/hooks.json" ]]; then
    echo "    Merge beforeMCPExecution from managed-settings/cursor-hooks.json into hooks.json"
  elif [[ -f "$SRC_HOOKS_JSON" ]]; then
    cp "$SRC_HOOKS_JSON" "$CURSOR_DIR/hooks.json"
    ok "Wrote $CURSOR_DIR/hooks.json"
  fi
else
  skip "deny-risky-mcp.sh template not found"
fi

echo "    In Cursor: Agents → Auto-run = Ask every time or Allowlist (sandboxed), not Run everything."

# ---------------------------------------------------------------------------
say "Layer 0.5: Lock Cursor config (manual chflags)"
CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"

echo "  After MCP and agent settings work, lock (README 0c/0d Lock ritual):"
echo "    chflags uchg \"$CURSOR_SETTINGS\""
[[ -f "$MCP_JSON" ]]  && echo "    chflags uchg \"$MCP_JSON\""
[[ -f "$MCP_PERMS" ]] && echo "    chflags uchg \"$MCP_PERMS\""

# ---------------------------------------------------------------------------
say "Layer 1: npm - disable lifecycle scripts globally"
if command -v npm >/dev/null 2>&1; then
  npm config set ignore-scripts true            # LOOSEN: npm config delete ignore-scripts
  ok "npm ignore-scripts = $(npm config get ignore-scripts)"
  echo "    Build-on-install packages must now be run by hand, e.g.:"
  echo "      npx puppeteer browsers install chrome"
  echo "      npm rebuild <pkg>          # native modules (sharp, better-sqlite3, ...)"
  echo "      npx can-i-ignore-scripts   # audit which deps actually need scripts"
  echo "    Commit package-lock.json and install with 'npm ci' (not 'npm install'):"
  echo "      npm ci                     # authoritative lockfile install; fails on drift"
  echo "      npm install <pkg>          # only when deliberately adding/bumping a dep"
else
  skip "npm not found - skipping"
fi

# ---------------------------------------------------------------------------
say "Layer 2: pip - refuse installs outside a virtualenv"
if command -v python3 >/dev/null 2>&1; then
  # LOOSEN: python3 -m pip config unset global.require-virtualenv
  if python3 -m pip config set global.require-virtualenv true >/dev/null 2>&1; then
    ok "pip require-virtualenv = true (no accidental system/global installs)"
  else
    skip "Could not set pip config - set it manually (see README)"
  fi
  echo "    For untrusted packages, prefer wheels (skip install-time code):"
  echo "      python3 -m pip install --only-binary :all: <pkg>"
  echo "    Pin real deps with hashes:"
  echo "      pip install --require-hashes -r requirements.txt"
else
  skip "python3 not found - skipping"
fi

# ---------------------------------------------------------------------------
say "Layer 3: Homebrew - snapshot current installs as a starting allowlist"
if command -v brew >/dev/null 2>&1; then
  if [[ -e "$HOME/Brewfile" ]]; then
    BREWFILE="$HOME/Brewfile.$(date +%Y%m%d)"
    echo "  ~/Brewfile exists - writing snapshot to $BREWFILE instead (won't clobber)."
  else
    BREWFILE="$HOME/Brewfile"
  fi
  if brew bundle dump --file="$BREWFILE" 2>/dev/null; then
    ok "Wrote $BREWFILE"
  else
    skip "brew bundle dump failed (file may already exist) - run it manually"
  fi
  echo "    Review/trim, version-control it, then prune extras later with:"
  echo "      brew bundle cleanup --file=\"$BREWFILE\"           # dry run"
  echo "      brew bundle cleanup --file=\"$BREWFILE\" --force   # actually remove"
  echo "    Brew safety is mostly behavioral: avoid random 'brew tap's, and"
  echo "    scrutinize casks that install .pkg - those can run as root."
else
  skip "brew not found - skipping"
fi

# ---------------------------------------------------------------------------
say "Result"
command -v npm     >/dev/null 2>&1 && echo "  npm ignore-scripts:       $(npm config get ignore-scripts)"
command -v python3 >/dev/null 2>&1 && echo "  pip require-virtualenv:   $(python3 -m pip config get global.require-virtualenv 2>/dev/null || echo '(unset)')"
[[ -f "${DEST_CLAUDE:-}" ]] && echo "  Claude managed settings:  installed" || echo "  Claude managed settings:  NOT installed"
[[ -f "${DEST_CODEX:-}" ]]  && echo "  Codex managed settings:   installed" || echo "  Codex managed settings:   NOT installed"
[[ -f "${MCP_PERMS:-}" ]]   && echo "  Cursor permissions.json:  present" || echo "  Cursor permissions.json:  not present"
[[ -f "${MCP_JSON:-}" ]]     && echo "  Cursor mcp.json:            present" || echo "  Cursor mcp.json:            not present"
printf '\nLoosen anything cumbersome via the LOOSEN notes above. See README.md.\n'
printf 'Lock Cursor/MCP when ready: README section 0e (chflags uchg).\n'
printf 'Layer 4 (AGENTS.md): README — copy agent-instructions/AGENTS.md per repo or globally.\n'
