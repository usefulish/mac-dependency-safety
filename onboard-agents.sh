#!/usr/bin/env bash
#
# onboard-agents.sh - sandbox a machine's AI agents BY DEFAULT, then prove it.
#
# The fleet onboarding step for agent harnesses (fleet task #282). Before this
# existed, a new machine got its profiles and plugins provisioned and its
# agents ran with the user's full permissions until someone remembered to
# retrofit the layer stack — and the knowfleet-gate was found "installed" as
# an inert config entry on four profiles (record 1abe4c95). This script makes
# both things happen in the flow, and ends on checks that bind.
#
#   1. harden-deps.sh          apply every layer this machine's harnesses
#                              support (0a Claude Code, 0b Codex, 0f Hermes,
#                              0h pi on macOS, Cursor templates, 1-3)
#   2. install-gate.sh         copy the knowfleet-gate into every Hermes
#                              profile + global (librarian excepted by policy,
#                              record bab5e39a), and verify Hermes discovers
#                              it (canonical: knowfleet repo, harness/hermes/)
#   3. verify-install.sh       the acceptance gate — read-only, behavioural
#                              probes; any FAIL not explicitly allowed, and
#                              any verifier exit not explained by its FAIL
#                              rows, makes this script exit 1. Onboarding is
#                              not done until it passes.
#
# Usage:
#   bash onboard-agents.sh                      # full run (sudo once)
#   bash onboard-agents.sh --check              # steps 2 (verify-only) + 3 only
#   bash onboard-agents.sh --allow-fail 'Cursor permissions.json not found'
#                                              # accept ONE known FAIL line by an
#                                              # exact substring (repeat per line);
#                                              # every accepted line is printed —
#                                              # record each in the machine card
#   KNOWFLEET_REPO=<dir>                        # where install-gate.sh lives
#                                              # (default ~/Code/active/knowfleet)
#   --skip-gate                                 # machine has no Hermes and no
#                                              # knowfleet checkout
#
# Platform notes (verified 2026-08-30, see README "Fleet onboarding"):
#   - Linux: 0a/0b/0f/1/2 apply (Claude Code reads /etc/claude-code/
#     managed-settings.json); 0h (sandbox-exec) and the Cursor layers are
#     macOS-only, so pi on Linux stays unsandboxed and this script says so.
#   - Unraid rebuilds /etc at boot: root-owned layers must be re-applied from
#     /boot/config/go or they vanish on the next reboot. Agents there run as
#     root, which bypasses Hermes Layer 0f entirely (README 0f).
#   - Run as the user the agents run as. Managed files are root-owned; the
#     user-owned halves (pi extension, Cursor files) land in that user's HOME.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWFLEET_REPO="${KNOWFLEET_REPO:-$HOME/Code/active/knowfleet}"
GATE_INSTALLER="$KNOWFLEET_REPO/harness/hermes/install-gate.sh"

check_only=0
skip_gate=0
allow_fail=()
while (($#)); do
  case "$1" in
    --check) check_only=1 ;;
    --skip-gate) skip_gate=1 ;;
    --allow-fail) shift; allow_fail+=("${1:?--allow-fail needs a pattern}") ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
note() { printf '  – %s\n' "$1"; }

overall=0

# --- 1. Apply the layer stack ------------------------------------------------
say "1/3 Layer stack ($(uname -s))"
if (( check_only )); then
  note "--check: not applying layers"
else
  if bash "$SCRIPT_DIR/harden-deps.sh"; then
    ok "harden-deps.sh completed"
  else
    bad "harden-deps.sh returned non-zero — read its output above"
    overall=1
  fi
fi

# --- 2. knowfleet-gate in every Hermes profile ------------------------------
say "2/3 knowfleet-gate in every Hermes profile"
if (( skip_gate )); then
  note "--skip-gate: not checking Hermes profiles"
elif ! command -v hermes >/dev/null 2>&1; then
  note "hermes not installed on this machine — nothing to gate (pass --skip-gate to silence)"
elif [[ ! -x "$GATE_INSTALLER" ]]; then
  bad "install-gate.sh not found at $GATE_INSTALLER — clone the knowfleet repo or set KNOWFLEET_REPO"
  overall=1
else
  gate_args=(--all --global)
  (( check_only )) && gate_args=(--check "${gate_args[@]}")
  if "$GATE_INSTALLER" "${gate_args[@]}"; then
    ok "every Hermes profile (librarian excepted by policy) discovers knowfleet-gate"
  else
    bad "at least one Hermes profile runs ungated — see rows above"
    overall=1
  fi
fi

# --- 3. Acceptance gate ------------------------------------------------------
say "3/3 Acceptance: verify-install.sh"
verify_out="$(bash "$SCRIPT_DIR/verify-install.sh" 2>&1)"
verify_rc=$?
printf '%s\n' "$verify_out"

# Strip colour codes so patterns match plain text. The ESC byte is injected
# by bash ($'\e'), not by sed's escape parser, so BSD and GNU sed behave alike.
esc=$'\e'
plain="$(printf '%s\n' "$verify_out" | sed "s/${esc}\[[0-9;]*m//g")"
fail_lines="$(printf '%s\n' "$plain" | grep '^  FAIL ' || true)"
unexpected=""
accepted_lines=""
accepted=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  matched=0
  for pat in "${allow_fail[@]:-}"; do
    [[ -n "$pat" && "$line" == *"$pat"* ]] && { matched=1; break; }
  done
  if (( matched )); then
    accepted=$((accepted + 1)); accepted_lines+="$line"$'\n'
  else
    unexpected+="$line"$'\n'
  fi
done <<<"$fail_lines"

say "Onboarding result"
if (( accepted > 0 )); then
  note "$accepted FAIL line(s) accepted as known pre-onboarding gaps (--allow-fail) — record each in the machine card:"
  printf '%s' "$accepted_lines" | sed 's/^/      /'
fi
if [[ -n "$unexpected" ]]; then
  bad "unaccepted FAIL(s):"
  printf '%s' "$unexpected" | sed 's/^/      /'
  overall=1
else
  ok "verify-install.sh: no unaccepted FAIL"
fi
# The verifier's exit status must be fully explained by the FAIL rows above:
# 0 is clean, 1 is "at least one FAIL row" (acceptable only when every row was
# accepted), anything else — a crash, an unbound variable, a missing script
# (127) — proves nothing and must not onboard the machine.
case "$verify_rc" in
  0) ;;
  1)
    if [[ -z "$fail_lines" ]]; then
      bad "verify-install.sh exited 1 without printing a FAIL row — treat as a broken verifier, not a pass"
      overall=1
    fi ;;
  *)
    bad "verify-install.sh exited $verify_rc (abnormal termination or missing script) — no acceptance without a complete run"
    overall=1 ;;
esac
if (( overall )); then
  echo
  echo "  NOT onboarded. Fix the items above (or name a genuinely pre-existing one with --allow-fail) and re-run."
  exit 1
fi
echo
echo "  Agents on this machine are sandboxed by default. Next: restart running harness processes"
echo "  (pi hosts, Hermes gateways), then re-run: bash onboard-agents.sh --check"
