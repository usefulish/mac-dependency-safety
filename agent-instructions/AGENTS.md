# Agent instructions

Defaults for AI coding agents working in this project. Advisory, not enforced —
an agent usually follows these; it can also ignore them, and malware reads none
of it. For enforcement see Layer 0 of this repo.

## Dependency hygiene (npm)

- Default to `npm ci` — authoritative install from `package-lock.json`; fails on drift.
- Use `npm install <pkg>` ONLY to deliberately add or bump a dependency (it rewrites the lockfile).
- Never run a bare `npm install` (no package name) to "refresh" or update deps unless the user explicitly asked — it silently mutates the lockfile.
- Keep `package-lock.json` committed; never gitignore it.
- pnpm → `pnpm install --frozen-lockfile`; yarn → `yarn install --immutable`. Same idea.
- Treat unexpected native npm builds (`binding.gyp`, `node-gyp`, or similar) as risky; ask before running rebuilds or troubleshooting native install failures.
- Do not add or loosen package publish tokens, CI release secrets, or registry settings unless the user explicitly asked.
- Do not add MCP servers or edit `.cursor/mcp.json` unless the user explicitly asked.
