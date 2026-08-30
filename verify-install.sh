#!/usr/bin/env bash
#
# verify-install.sh - checks for the mac-dependency-safety baseline.
#
# This does not install or change settings. It checks whether the controls this
# repo documents are present and EFFECTIVE on the current Mac. Where a control
# is behavioural (Codex deny_read, Hermes approvals.deny), the check runs the
# tool's own probe inside that tool's sandbox — a sandboxed read installs and
# changes nothing. The one execution outside a sandbox is `codex ... doctor`,
# which is read-only by design.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

cursor_hook_fail_closed() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

hooks = data.get("hooks", {}).get("beforeMCPExecution", [])
for hook in hooks:
    if hook.get("command") == "./hooks/deny-risky-mcp.sh":
        sys.exit(0 if hook.get("failClosed") is True else 2)
sys.exit(1)
PY
}

say "Layer 0: AI agent managed settings"

if [[ "$(uname -s)" == "Darwin" ]]; then
  CLAUDE_MANAGED="/Library/Application Support/ClaudeCode/managed-settings.json"
else
  CLAUDE_MANAGED="/etc/claude-code/managed-settings.json"   # Linux location
fi
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

CODEX_REQUIREMENTS="/etc/codex/requirements.toml"
CODEX_OLD_PATH="/etc/codex/codex.toml"
if [[ -f "$CODEX_REQUIREMENTS" ]]; then
  pass "Codex requirements file exists: $CODEX_REQUIREMENTS"
  # A "managed" ceiling the agent's own user can rewrite is not managed. The
  # README installs this root:wheel; drift back to user ownership has been seen
  # in the field, and nothing else in this script notices.
  if [[ -w "$CODEX_REQUIREMENTS" ]]; then
    fail "Codex requirements file is writable by $(id -un): $(ls -l "$CODEX_REQUIREMENTS" | awk '{print $3":"$4, $1}') — run: sudo chown root:wheel $CODEX_REQUIREMENTS"
  else
    pass "Codex requirements file is not writable by the current user"
  fi
  if file_contains "$CODEX_REQUIREMENTS" 'allowed_permission_profiles'; then
    pass "Codex requirements constrain permission profiles"
  else
    fail "Codex requirements does not mention allowed_permission_profiles — user-config profiles can widen write scope past allowed_sandbox_modes"
  fi
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
  if ! file_contains "$CODEX_REQUIREMENTS" 'deny_read'; then
    fail "Codex requirements does not mention filesystem deny_read rules — nothing to probe"
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

  # Behavioural Layer 0b probe (3fc92706): grep for the deny_read key proved
  # structurally blind — requirements.toml accepted three inert bare-`**/` globs
  # for months and the old check reported PASS. Probe what binds, per c3289fd5
  # (verify by artifact, keep a control row). A sandboxed `cat` installs and
  # changes nothing; the codex sandbox isolates the probe the same way it
  # isolates the agent.
  # Deny path must be refused, control path must succeed — the two rows
  # together distinguish a working deny from a blanket lockdown.
  # Fixtures are created at runtime: a machine-specific file like
  # ~/.ssh/<key>.pub may not exist, and cat's ENOENT is indistinguishable from
  # a sandbox denial by exit code alone. The deny fixture sits under $HOME
  # because the template's rules are ~/-rooted; the control is /etc/hosts,
  # present on every macOS/Linux install. Deny must show the kernel's
  # "Operation not permitted", not merely a non-zero status.
  codex_probe_dir="$(mktemp -d "$HOME/.codex-probe.XXXXXX")"
  printf 'PROBE=1\n' > "$codex_probe_dir/.env"
  probe_deny="$(codex sandbox --include-managed-config -P :workspace -C "$(pwd)" -- /bin/cat "$codex_probe_dir/.env" 2>&1)"
  deny_rc=$?
  probe_control="$(codex sandbox --include-managed-config -P :workspace -C "$(pwd)" -- /bin/cat /etc/hosts 2>&1)"
  control_rc=$?
  rm -rf "$codex_probe_dir"
  if [[ "$deny_rc" -ne 0 && "$probe_deny" == *"Operation not permitted"* && "$control_rc" -eq 0 ]]; then
    pass "Codex deny_read binds: ~/**/.env fixture denied with EPERM, /etc/hosts control readable"
  elif [[ "$deny_rc" -eq 0 ]]; then
    fail "Codex deny_read is inert: a ~/**/.env fixture was readable in the sandbox"
  else
    warn "Could not confirm Codex deny_read behaviour (deny_rc=$deny_rc control_rc=$control_rc: ${probe_deny:0:80})"
  fi
else
  warn "codex command not found"
fi

say "Layer 0f: Hermes managed scope"

# Hermes reads managed config from /etc/hermes, relocatable via HERMES_MANAGED_DIR.
# Honour the override here so the check follows the same resolution the agent does
# — and flag it, because a user-settable override defeats the whole layer.
HERMES_MANAGED="${HERMES_MANAGED_DIR:-/etc/hermes}/config.yaml"
if [[ -n "${HERMES_MANAGED_DIR:-}" ]]; then
  warn "HERMES_MANAGED_DIR is set to '$HERMES_MANAGED_DIR'; managed scope can be repointed by whoever sets it"
fi

if [[ -f "$HERMES_MANAGED" ]]; then
  pass "Hermes managed config exists: $HERMES_MANAGED"
  if [[ -w "$HERMES_MANAGED" ]]; then
    fail "Hermes managed config is writable by $(id -un) — run: sudo chown root:wheel $HERMES_MANAGED"
  else
    pass "Hermes managed config is not writable by the current user"
  fi
  if file_contains "$HERMES_MANAGED" 'deny:'; then
    pass "Hermes managed config pins approvals.deny rules"
  else
    fail "Hermes managed config has no approvals.deny rules — nothing survives --yolo without them"
  fi
else
  warn "Hermes managed config not found: $HERMES_MANAGED"
fi

# Behavioural probe, not a grep. `hermes approvals test` evaluates the real
# runtime guards and never executes the command, prompts, or persists anything.
# Exit codes: 0 allow, 2 ask, 3 deny. The benign probe matters as much as the
# secret one — it separates a working rule set from an unusably broad one.
if have hermes; then
  hermes approvals test -- cat "$HOME/.ssh/id_rsa" >/dev/null 2>&1
  secret_verdict=$?
  hermes approvals test -- cat prod.envelope >/dev/null 2>&1
  benign_verdict=$?
  if [[ "$secret_verdict" -eq 3 ]]; then
    pass "Hermes denies reading ~/.ssh via the terminal tool"
  else
    fail "Hermes allows reading ~/.ssh via the terminal tool (verdict $secret_verdict; expected 3=deny)"
  fi
  if [[ "$benign_verdict" -eq 3 ]]; then
    fail "Hermes deny rules are over-broad: a benign 'prod.envelope' read is blocked"
  else
    pass "Hermes deny rules leave benign commands alone"
  fi
else
  warn "hermes command not found"
fi

say "Layer 0e: Cursor MCP"

# Layer 0c/0d verdicts depend on whether Cursor is actually installed: a
# missing layer on a machine that does not run Cursor is a WARN (correctly
# absent), on one that does it is a FAIL (layer should exist). Mirrors how the
# script treats codex/npm presence.
if [[ -d "/Applications/Cursor.app" ]]; then
  cursor_installed=1
else
  cursor_installed=0
fi

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
  if (( cursor_installed )); then
    fail "Cursor permissions.json not found (Cursor is installed): $CURSOR_PERMS"
  else
    warn "Cursor permissions.json not found: $CURSOR_PERMS"
  fi
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
  if (( cursor_installed )); then
    fail "Cursor mcp.json not found (Cursor is installed): $CURSOR_MCP"
  else
    warn "Cursor mcp.json not found: $CURSOR_MCP"
  fi
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
  if (( cursor_installed )); then
    fail "Cursor deny-risky-mcp hook not installed (Cursor is installed): $CURSOR_HOOK"
  else
    warn "Cursor deny-risky-mcp hook not executable: $CURSOR_HOOK"
  fi
fi

CURSOR_HOOKS_JSON="$HOME/.cursor/hooks.json"
if [[ -f "$CURSOR_HOOKS_JSON" ]]; then
  if json_valid "$CURSOR_HOOKS_JSON"; then
    pass "Cursor hooks.json exists and is valid JSON"
    if cursor_hook_fail_closed "$CURSOR_HOOKS_JSON"; then
      pass "Cursor deny-risky-mcp hook is configured fail-closed"
    else
      warn "Cursor deny-risky-mcp hook is missing or not fail-closed in hooks.json"
    fi
  else
    fail "Cursor hooks.json exists but is not valid JSON: $CURSOR_HOOKS_JSON"
  fi
else
  if (( cursor_installed )); then
    fail "Cursor hooks.json not found (Cursor is installed): $CURSOR_HOOKS_JSON"
  else
    warn "Cursor hooks.json not found: $CURSOR_HOOKS_JSON"
  fi
fi

say "Layer 0g: Antigravity sandboxing"

# Antigravity (Google agent IDE) has a native terminal sandbox (Seatbelt on
# macOS) plus a fine-grained permissions engine. The toggle is USER-owned
# (~/.gemini/config/config.json, guru:staff) — this is defense-in-depth, NOT a
# root-anchored layer like 0a/0b/0f. Artifact check only: behavioural
# enforcement needs the IDE running (sandbox-exec wraps commands the AGENT
# runs, not shell commands from this script). See record 923afca2.
ANTIGRAVITY_APP="/Applications/Antigravity.app"
ANTIGRAVITY_SETTINGS="$HOME/.gemini/config/config.json"
if [[ -d "$ANTIGRAVITY_APP" ]]; then
  antigravity_installed=1
else
  antigravity_installed=0
fi

if (( antigravity_installed )); then
  if [[ -f "$ANTIGRAVITY_SETTINGS" ]]; then
    if json_valid "$ANTIGRAVITY_SETTINGS"; then
      pass "Antigravity user settings exist and are valid JSON"
    else
      fail "Antigravity user settings exists but is not valid JSON: $ANTIGRAVITY_SETTINGS"
    fi
    if python3 -c "
import json, sys
with open('$ANTIGRAVITY_SETTINGS') as f:
    d = json.load(f)
sys.exit(0 if d.get('userSettings', {}).get('enableTerminalSandbox') is True else 1)
"; then
      pass "Antigravity terminal sandbox is enabled (enableTerminalSandbox)"
    else
      fail "Antigravity terminal sandbox is NOT enabled (enableTerminalSandbox missing or false)"
    fi
  else
    fail "Antigravity user settings not found (Antigravity is installed): $ANTIGRAVITY_SETTINGS"
  fi
else
  warn "Antigravity not installed; layer 0g not applicable"
fi

say "Layer 0h: pi sandbox"

# pi (earendil-works/pi-coding-agent) ships no sandbox and no managed
# settings; its bash/read/write tools run with the user's full permissions.
# Layer 0h is two halves: a ROOT-owned /etc/pi (Seatbelt profile, bash
# wrapper, ripgrep config) that the kernel enforces, and a USER-owned
# extension in ~/.pi/agent/extensions that points pi's tools at it. Only the
# root half is a wall; the extension is a pointer (delete it, or start
# `pi --no-extensions`, and the session is unsandboxed), so both are checked.
#
# The probes below run the REAL wrapper — a sandboxed read installs and
# changes nothing — and assert both directions plus one interaction:
#   deny path must fail with EPERM ("Operation not permitted", i.e. the kernel
#   refused, not a shell error), a benign near-miss (.envelope) and a control
#   (/etc/hosts) must succeed, and npm must report the same ignore-scripts
#   inside the sandbox as outside — a ~/.npmrc read-deny silently flips it to
#   false and hands install scripts back to Layer 1's attacker.
# Probe fixtures are created at runtime so nothing here reads a real secret.
PI_SANDBOX_DIR="/etc/pi"
PI_SANDBOX_PROFILE="$PI_SANDBOX_DIR/sandbox.sb"
PI_SANDBOX_WRAPPER="$PI_SANDBOX_DIR/bash"
PI_SANDBOX_RG="$PI_SANDBOX_DIR/ripgrep.conf"
PI_EXTENSION="$HOME/.pi/agent/extensions/dependency-safety.ts"
PI_EXTENSION_TEMPLATE="$SCRIPT_DIR/managed-settings/pi/dependency-safety.ts"
if have pi; then
  pi_installed=1
else
  pi_installed=0
fi

# The root-owned boundary is only a wall if root owns it AND nobody else can
# write it — including the directory: a user-writable /etc/pi lets the agent
# unlink a root-owned sandbox.sb and drop an allow-all profile in its place.
# `-w` only reports the current user's effective access, so check owner and
# mode bits explicitly. stat -f is BSD (macOS); Layer 0h is macOS-only.
pi_root_artifact_ok() {
  local path="$1" want_mode="$2" owner mode
  owner="$(stat -f '%u' "$path" 2>/dev/null)" || return 1
  mode="$(stat -f '%Lp' "$path" 2>/dev/null)" || return 1
  [[ "$owner" == "0" && "$mode" == "$want_mode" ]]
}

if [[ -f "$PI_SANDBOX_PROFILE" && -x "$PI_SANDBOX_WRAPPER" && -f "$PI_SANDBOX_RG" ]]; then
  pass "pi sandbox profile, wrapper and ripgrep config exist under $PI_SANDBOX_DIR"
  for spec in "$PI_SANDBOX_DIR:755" "$PI_SANDBOX_WRAPPER:755" "$PI_SANDBOX_PROFILE:644" "$PI_SANDBOX_RG:644"; do
    pi_file="${spec%%:*}"
    pi_mode="${spec##*:}"
    if pi_root_artifact_ok "$pi_file" "$pi_mode"; then
      pass "pi sandbox artifact is root-owned mode $pi_mode: $pi_file"
    else
      fail "pi sandbox artifact is not root-owned mode $pi_mode: $pi_file ($(stat -f '%Su:%Sg %Lp' "$pi_file" 2>/dev/null)) — run: sudo chown root:wheel $pi_file && sudo chmod $pi_mode $pi_file"
    fi
  done

  pi_probe_dir="$(mktemp -d)"
  printf 'PROBE=1\n' > "$pi_probe_dir/.env"
  printf 'benign\n' > "$pi_probe_dir/.envelope"
  pi_deny_out="$("$PI_SANDBOX_WRAPPER" -c "ls \"$HOME/.ssh\"" 2>&1)"
  pi_deny_rc=$?
  pi_env_out="$("$PI_SANDBOX_WRAPPER" -c "cat \"$pi_probe_dir/.env\"" 2>&1)"
  pi_env_rc=$?
  "$PI_SANDBOX_WRAPPER" -c "cat \"$pi_probe_dir/.envelope\"" >/dev/null 2>&1
  pi_benign_rc=$?
  "$PI_SANDBOX_WRAPPER" -c "cat /etc/hosts" >/dev/null 2>&1
  pi_control_rc=$?
  rm -rf "$pi_probe_dir"

  if [[ "$pi_deny_rc" -ne 0 && "$pi_deny_out" == *"Operation not permitted"* ]]; then
    pass "pi sandbox denies ~/.ssh with EPERM"
  else
    fail "pi sandbox did not deny ~/.ssh with EPERM (rc=$pi_deny_rc: ${pi_deny_out:0:80})"
  fi
  if [[ "$pi_env_rc" -ne 0 && "$pi_env_out" == *"Operation not permitted"* ]]; then
    pass "pi sandbox denies .env with EPERM"
  else
    fail "pi sandbox did not deny .env with EPERM (rc=$pi_env_rc: ${pi_env_out:0:80})"
  fi
  if [[ "$pi_benign_rc" -eq 0 && "$pi_control_rc" -eq 0 ]]; then
    pass "pi sandbox leaves benign reads alone (.envelope, /etc/hosts)"
  else
    fail "pi sandbox is over-broad or broken (benign_rc=$pi_benign_rc control_rc=$pi_control_rc)"
  fi
  if have npm; then
    pi_npm_outside="$(cd / && npm config get ignore-scripts 2>/dev/null)"
    pi_npm_inside="$("$PI_SANDBOX_WRAPPER" -c "cd / && npm config get ignore-scripts" 2>/dev/null)"
    if [[ -n "$pi_npm_inside" && "$pi_npm_inside" == "$pi_npm_outside" ]]; then
      pass "npm reports the same ignore-scripts inside the pi sandbox ($pi_npm_inside) — Layer 1 intact"
    else
      fail "Layer 1 defeated inside the pi sandbox: ignore-scripts is '${pi_npm_inside:-<none>}' inside vs '$pi_npm_outside' outside — ~/.npmrc must stay readable"
    fi
  fi
else
  if (( pi_installed )); then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      fail "pi sandbox not installed (pi is installed): need $PI_SANDBOX_PROFILE, $PI_SANDBOX_WRAPPER and $PI_SANDBOX_RG"
    else
      warn "pi is installed but Layer 0h is not applicable on $(uname -s) (sandbox-exec is macOS-only) — pi runs UNSANDBOXED here"
    fi
  else
    warn "pi sandbox not found: $PI_SANDBOX_DIR (pi not installed)"
  fi
fi

# The extension is the user-owned pointer to the root-owned wall. A stale,
# edited or replaced copy is a gap, not a warning: compare it byte-for-byte
# with this checkout's template, which is what the README installs.
if [[ -f "$PI_EXTENSION" ]]; then
  if [[ ! -f "$PI_EXTENSION_TEMPLATE" ]]; then
    warn "pi extension template missing from this checkout ($PI_EXTENSION_TEMPLATE); cannot validate $PI_EXTENSION"
  elif cmp -s "$PI_EXTENSION" "$PI_EXTENSION_TEMPLATE"; then
    pass "pi dependency-safety extension matches the Layer 0h template: $PI_EXTENSION"
  else
    fail "pi dependency-safety extension differs from the Layer 0h template (stale, edited or replaced): $PI_EXTENSION — re-copy managed-settings/pi/dependency-safety.ts and restart pi"
  fi
  if [[ ! -f "$PI_SANDBOX_PROFILE" || ! -x "$PI_SANDBOX_WRAPPER" || ! -f "$PI_SANDBOX_RG" ]]; then
    fail "pi extension installed without a complete $PI_SANDBOX_DIR — pi's bash and grep tools are fail-closed (disabled) until the root half is installed"
  fi
else
  if (( pi_installed )); then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      fail "pi dependency-safety extension not installed (pi is installed): $PI_EXTENSION"
    else
      warn "pi dependency-safety extension not applicable on $(uname -s) (it needs /etc/pi's sandbox-exec wrapper)"
    fi
  else
    warn "pi dependency-safety extension not found: $PI_EXTENSION"
  fi
fi

say "Layer 0.5: Immutable config files"

CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"
for protected_file in "$CURSOR_SETTINGS" "$CURSOR_MCP" "$CURSOR_PERMS"; do
  if [[ -e "$protected_file" ]]; then
    if is_immutable "$protected_file"; then
      pass "Immutable flag set: $protected_file"
    else
      if (( cursor_installed )); then
        fail "Immutable flag not set (Cursor is installed): $protected_file"
      else
        warn "Immutable flag not set: $protected_file"
      fi
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
