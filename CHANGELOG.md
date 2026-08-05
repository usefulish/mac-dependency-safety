# Changelog

## Unreleased

- Add a monthly GitHub Actions reminder that opens a pragmatic threat-baseline review issue.
- Document native npm build-path risk (`binding.gyp` / `node-gyp`), dependency-confusion basics, package publisher token hygiene, provenance limits, and fake Homebrew installer risk.
- Make the Cursor MCP deny hook template fail closed and teach verification to flag fail-open hook configuration.
- Extend agent defaults to avoid unexpected native npm rebuilds and registry/publish-token changes without explicit user intent.
- Fix Codex `requirements.toml` template for current Codex CLI schema: use top-level allowlists and requirements-level filesystem deny rules instead of named permission profiles.
- Add a read-only install verification script for installed controls.
- Clarify that the repo is a pragmatic hardening baseline, not containment, and document important non-goals.
