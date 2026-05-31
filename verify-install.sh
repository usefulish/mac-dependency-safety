#!/usr/bin/env bash
#
# verify-install.sh - read-only checks for the mac-dependency-safety baseline.
#
# This does not install or change settings. It checks whether the controls this
# repo documents appear to be present and effective on the current Mac.

set -u

pass_count=0
warn_count=0
fail_count=0

say() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

pass() {
  pass_count=$((pass_count + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}

warn() {
  warn_count=$((warn_count + 1))
  printf '  \033[33mWARN\033[0m %s\n' "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

file_contains() {
  local file="$1"
  local needle="$2"
  [[ -f "$file" ]] && grep -qF "$needle" "$file"
}

is_immutable() {
  local file="$1"
  [[ -e "$file" ]] || return 1
  ls -ldO "$file" 2>/dev/null | awk '{print $5}' | grep -qw 'uchg'
}

json_valid() {
  local file="$1"
  python3 -m json.tool "$file" >/dev/null 2>&1
}

say "Layer 0: AI agent managed settings"

CLAUDE_MANAGED="/Library/Application Support/ClaudeCode/managed-settings.json"
if [[ -f "$CLAUDE_MANAGED" ]]; then
  if json_valid "$CLAUDE_MANAGED"; then
    pass "Claude Code managed settings file exists and is valid JSON"
  else
    fail "Claude Code managed settings exists but is not valid JSON: $CLAUDE_MANAGED"
  fi
  if file_contains "$CLAUDE_MANAGED" "disableBypassPermissionsMode"; then
    pass "Claude Code bypass mode control is present"
  else
    warn "Claude Code managed settings does not mention disableBypassPermissionsMode"
  fi
else
  warn "Claude Code managed settings not found: $CLAUDE_MANAGED"
fi

GEMINI_MANAGED="/Library/Application Support/GeminiCli/settings.json"
if [[ -f "$GEMINI_MANAGED" ]]; then
  if json_valid "$GEMINI_MANAGED"; then
    pass "Gemini CLI managed settings file exists and is valid JSON"
  else
    fail "Gemini CLI managed settings exists but is not valid JSON: $GEMINI_MANAGED"
  fi
  if file_contains "$GEMINI_MANAGED" "secureModeEnabled"; then
    pass "Gemini CLI secure mode control is present"
  else
    warn "Gemini CLI managed settings does not mention secureModeEnabled"
  fi
else
  warn "Gemini CLI managed settings not found: $GEMINI_MANAGED"
fi

CODEX_REQUIREMENTS="/etc/codex/requirements.toml"
CODEX_OLD_PATH="/etc/codex/codex.toml"
if [[ -f "$CODEX_REQUIREMENTS" ]]; then
  pass "Codex requirements file exists: $CODEX_REQUIREMENTS"
  if file_contains "$CODEX_REQUIREMENTS" 'allowed_sandbox_modes'; then
    pass "Codex requirements constrain sandbox modes"
  else
    fail "Codex requirements does not mention allowed_sandbox_modes"
  fi
  if file_contains "$CODEX_REQUIREMENTS" 'allowed_approval_policies'; then
    pass "Codex requirements constrain approval policies"
  else
    fail "Codex requirements does not mention allowed_approval_policies"
  fi
  if file_contains "$CODEX_REQUIREMENTS" 'deny_read'; then
    pass "Codex requirements include filesystem deny_read rules"
  else
    warn "Codex requirements does not mention filesystem deny_read rules"
  fi
else
  fail "Codex requirements file not found: $CODEX_REQUIREMENTS"
fi

if [[ -f "$CODEX_OLD_PATH" ]]; then
  warn "Found $CODEX_OLD_PATH; Codex managed requirements are loaded from $CODEX_REQUIREMENTS"
fi

if have codex; then
  codex_summary="$(codex --dangerously-bypass-approvals-and-sandbox doctor --summary 2>&1)"
  if printf '%s\n' "$codex_summary" | grep -q 'unrestricted fs + enabled network · approval Never'; then
    fail "Codex dangerous bypass mode is still effective"
  elif printf '%s\n' "$codex_summary" | grep -q 'restricted fs'; then
    pass "Codex dangerous bypass request is constrained to restricted filesystem"
  else
    warn "Could not confirm Codex dangerous bypass constraint from doctor output"
  fi
else
  warn "codex command not found"
fi

say "Layer 0e: Cursor MCP"

CURSOR_PERMS="$HOME/.cursor/permissions.json"
if [[ -f "$CURSOR_PERMS" ]]; then
  if json_valid "$CURSOR_PERMS"; then
    pass "Cursor permissions.json exists and is valid JSON"
  else
    fail "Cursor permissions.json exists but is not valid JSON: $CURSOR_PERMS"
  fi
  if grep -q '"\*:\*"' "$CURSOR_PERMS"; then
    fail "Cursor mcpAllowlist contains *:*"
  else
    pass "Cursor mcpAllowlist does not contain *:*"
  fi
else
  warn "Cursor permissions.json not found: $CURSOR_PERMS"
fi

CURSOR_MCP="$HOME/.cursor/mcp.json"
if [[ -f "$CURSOR_MCP" ]]; then
  if json_valid "$CURSOR_MCP"; then
    pass "Cursor mcp.json exists and is valid JSON"
  else
    fail "Cursor mcp.json exists but is not valid JSON: $CURSOR_MCP"
  fi
  if grep -q '@latest\b' "$CURSOR_MCP"; then
    fail "Cursor mcp.json references @latest; pin MCP server versions"
  else
    pass "Cursor mcp.json does not reference @latest"
  fi
else
  warn "Cursor mcp.json not found: $CURSOR_MCP"
fi

CURSOR_HOOK="$HOME/.cursor/hooks/deny-risky-mcp.sh"
if [[ -x "$CURSOR_HOOK" ]]; then
  hook_output="$(printf '{"tool_name":"mcp","tool_input":"read .env","command":"","url":""}' | "$CURSOR_HOOK" 2>/dev/null)"
  if printf '%s\n' "$hook_output" | grep -q '"permission"[[:space:]]*:[[:space:]]*"deny"'; then
    pass "Cursor deny-risky-mcp hook blocks secret-path MCP calls"
  else
    fail "Cursor deny-risky-mcp hook did not deny a .env test call"
  fi
else
  warn "Cursor deny-risky-mcp hook not executable: $CURSOR_HOOK"
fi

say "Layer 0.5: Immutable config files"

CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"
COPILOT_CONFIG="$HOME/.copilot/config.json"
for protected_file in "$CURSOR_SETTINGS" "$CURSOR_MCP" "$CURSOR_PERMS" "$COPILOT_CONFIG"; do
  if [[ -e "$protected_file" ]]; then
    if is_immutable "$protected_file"; then
      pass "Immutable flag set: $protected_file"
    else
      warn "Immutable flag not set: $protected_file"
    fi
  fi
done

say "Layer 1: npm"

if have npm; then
  npm_ignore="$(npm config get ignore-scripts 2>/dev/null || true)"
  if [[ "$npm_ignore" == "true" ]]; then
    pass "npm ignore-scripts is true"
  else
    fail "npm ignore-scripts is '$npm_ignore' (expected true)"
  fi
else
  warn "npm not found"
fi

say "Layer 2: pip"

if have python3; then
  pip_requires_venv="$(python3 -m pip config get global.require-virtualenv 2>/dev/null || true)"
  if [[ "$pip_requires_venv" == "true" ]]; then
    pass "pip global.require-virtualenv is true"
  else
    warn "pip global.require-virtualenv is '${pip_requires_venv:-unset}'"
  fi
else
  warn "python3 not found"
fi

say "Layer 3: Homebrew"

if have brew; then
  if [[ -f "$HOME/Brewfile" ]]; then
    pass "Brewfile exists at $HOME/Brewfile"
  else
    warn "No $HOME/Brewfile found; run brew bundle dump when ready"
  fi
else
  warn "brew not found"
fi

say "Result"
printf '  PASS: %d\n' "$pass_count"
printf '  WARN: %d\n' "$warn_count"
printf '  FAIL: %d\n' "$fail_count"

if (( fail_count > 0 )); then
  exit 1
fi
