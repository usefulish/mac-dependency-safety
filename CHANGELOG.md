# Changelog

## Unreleased

- Fix three `deny_read` entries in the Codex template that never matched anything: `**/.env`, `**/.env.*` and `**/.npmrc` are re-rooted as `~/**/.env`, `~/**/.env.*` and `~/**/.npmrc`. Codex requires filesystem paths to be absolute, `~/`-rooted or `:`-prefixed; the permission-profile parser rejects the bare form outright, but `requirements.toml` accepted it silently, so a quarter of the deny list was inert while `verify-install.sh` reported PASS. Probe files at `$HOME/<dir>/.env` and a workspace `.env` were readable under managed settings before the fix. Verified on codex-cli 0.147.0, macOS 15.3.

- Add `allowed_permission_profiles` to the Codex template. Codex 0.147 resolves write scope through named permission profiles, an axis `allowed_sandbox_modes` does not cover, and the template left it unconstrained — a profile defined in the user-writable `~/.codex/config.toml` (`"~/" = "write"`) obtained write access to all of `$HOME` with managed settings loaded. Read denials held throughout, so this widened writes only. The allowlist includes `repo-git`, the audited `.git` relaxation; drop that entry if you do not install the companion user profile.

  Two schema traps, both found the hard way and both fatal to Codex startup: the key is a **map of profile name to bool**, not a list (a list fails the requirements layer with `invalid type: sequence, expected a map`), and every profile it names must already be defined — including ones that live in user config — or Codex refuses to start with `refers to undefined profile`. Install the user-config profile first. Note also that appending a bare `key = value` to the end of this file nests it under `[permissions.filesystem]` and is silently ignored; use a table header.

- Document that `managed-settings/gemini.json` was removed intentionally (in the earlier "cleann up" commit): Gemini CLI has been retired by Google, so the repo no longer ships a Gemini managed-settings template.

- Fix the Cursor MCP deny hook missing secret paths embedded in command strings: the `.env`/`.ssh`/`.aws` patterns only matched at line boundaries of the final JSON field (no `re.MULTILINE`) and did not accept whitespace as a path boundary, so payloads like `read .env` or `cat ~/.env secrets` were allowed. The hook's argv plumbing was fine — `verify-install.sh`'s `.env` test payload now denies as intended.

- Add a monthly GitHub Actions reminder that opens a pragmatic threat-baseline review issue.
- Document native npm build-path risk (`binding.gyp` / `node-gyp`), dependency-confusion basics, package publisher token hygiene, provenance limits, and fake Homebrew installer risk.
- Make the Cursor MCP deny hook template fail closed and teach verification to flag fail-open hook configuration.
- Extend agent defaults to avoid unexpected native npm rebuilds and registry/publish-token changes without explicit user intent.
- Fix Codex `requirements.toml` template for current Codex CLI schema: use top-level allowlists and requirements-level filesystem deny rules instead of named permission profiles.
- Add a read-only install verification script for installed controls.
- Clarify that the repo is a pragmatic hardening baseline, not containment, and document important non-goals.
