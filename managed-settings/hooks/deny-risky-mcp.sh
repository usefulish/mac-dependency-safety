#!/usr/bin/env bash
# Deny MCP tool calls that target common secret paths or unpinned @latest packages.
# Installed to ~/.cursor/hooks/ by harden-deps.sh (optional). Hooks cannot grant
# auto-approval — they only add deny guardrails on top of Cursor's own prompts.

set -euo pipefail

input="$(cat)"

python3 - "$input" <<'PY'
import json
import re
import sys

def allow():
    print(json.dumps({"permission": "allow"}))
    sys.exit(0)

def deny(user_msg: str, agent_msg: str):
    print(json.dumps({
        "permission": "deny",
        "user_message": user_msg,
        "agent_message": agent_msg,
    }))
    sys.exit(0)

raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    allow()

tool_name = str(data.get("tool_name", "") or "")
tool_input = str(data.get("tool_input", "") or "")
command = str(data.get("command", "") or "")
url = str(data.get("url", "") or "")
blob = "\n".join((tool_name, tool_input, command, url))

secret_patterns = [
    # boundaries accept whitespace as well as slashes: paths arrive embedded in
    # command strings ("read .env", "cat ~/.env secrets"), not just as bare paths
    (r"(?i)(?:^|[\s/\\])\.env(?:[.\s/\\]|$)", ".env files"),
    (r"(?i)\.ssh(?:[\s/\\]|$)", "SSH directory"),
    (r"(?i)git-credentials", "git credentials"),
    (r"(?i)\.npmrc", "npm config"),
    (r"(?i)\.netrc", "netrc"),
    (r"(?i)kube/config", "kubeconfig"),
    (r"(?i)docker/config\.json", "Docker config"),
    (r"(?i)(?:^|[\s/\\])\.aws(?:[\s/\\]|$)", "AWS credentials"),
    (r"(?i)gcloud", "gcloud config"),
]
# blob joins the JSON fields with newlines, so the $ alternatives in the
# patterns above only ever match the final field without MULTILINE — ".env"
# or ".ssh" at the end of tool_input slipped through when command/url followed.
for pattern, label in secret_patterns:
    if re.search(pattern, blob, re.MULTILINE):
        deny(
            f"Blocked MCP call targeting {label} (mac-dependency-safety hook).",
            f"MCP tool blocked: arguments appear to reference {label}. "
            "Use the Read tool or shell only with explicit user approval.",
        )

if re.search(r"@latest\b", blob):
    deny(
        "Blocked MCP using @latest (pin the package version in mcp.json).",
        "MCP blocked: unpinned @latest in tool input or server command.",
    )

allow()
PY
