/**
 * Layer 0h — pi dependency-safety extension (mac-dependency-safety).
 *
 * Install to ~/.pi/agent/extensions/dependency-safety.ts (pi auto-discovers
 * that directory for every session: interactive, `pi -p`, and A2A-dispatched
 * children created through the SDK in the same process). Restart long-lived
 * pi hosts afterwards — the extension set is loaded once per process.
 *
 * What it does, in order of how much you should trust it:
 *
 * 1. `bash` — routed through /etc/pi/bash, a ROOT-OWNED wrapper that runs the
 *    command under the Seatbelt profile /etc/pi/sandbox.sb. Reads of
 *    credential paths fail with EPERM inside the kernel, for the command and
 *    every child process. This is the load-bearing control: it does not look
 *    at command text, so traversal, symlinks and obfuscation do not help.
 *    Fail-closed: if the wrapper is missing, `bash` returns an error instead
 *    of running unsandboxed.
 * 2. `read` — pi's in-process file reader is not a subprocess, so Seatbelt
 *    cannot see it. Overridden here with the same deny set (Layer 0a parity,
 *    including ~/.npmrc which the bash sandbox deliberately exempts — see
 *    sandbox.sb). Allowed paths delegate to the built-in implementation, so
 *    images, truncation and rendering are unchanged.
 * 3. `write`/`edit` — blocked under credential directories (authorized_keys
 *    persistence, planted cloud contexts) and under ~/.pi/agent/extensions
 *    (so the agent cannot remove this file with its own tools).
 * 4. `grep`/`find`/`ls` — blocked when pointed INTO a credential directory.
 *    `grep` additionally gets RIPGREP_CONFIG_PATH=/etc/pi/ripgrep.conf so a
 *    content sweep from a parent directory skips secret files.
 *
 * What it is NOT (read before trusting it):
 *   - This file is USER-owned. Anyone who can write ~/.pi/agent can delete it,
 *     and `pi --no-extensions` / `pi -ne` starts a session without it. The
 *     ROOT-owned half (/etc/pi) is the wall; this file is the pointer to it —
 *     the same standing as Layer 0g's Antigravity toggle, weaker than 0a/0b/0f
 *     where the root-owned file is itself consulted by the agent.
 *   - Items 2–4 are in-process path checks, not a sandbox: an extension or
 *     MCP server loaded into the same pi process has the process's full
 *     permissions and is not covered by anything here.
 *   - Parity costs: inside pi's bash, `gh` loses its auth (~/.config/gh is
 *     denied, exactly as under Codex Layer 0b), and `.env.example` is
 *     unreadable because 0a/0b deny `.env.*` and this layer matches them.
 *   - KNOWN HOLE — pre-existing hard links. Seatbelt and this guard both
 *     decide by path; a hard link to ~/.ssh/id_rsa that already sits at an
 *     allowed path reads normally (verified 2026-08-30). Creating such a
 *     link from inside the sandbox is denied (sandbox.sb), and pi's own
 *     tools cannot create one, so the hole needs a link planted beforehand
 *     on the same filesystem. Symlinks are NOT a hole: the kernel resolves
 *     them before the deny applies, and the in-process guard checks both
 *     the path as written and its resolved target.
 */

import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
	createBashToolDefinition,
	createLocalBashOperations,
	createReadToolDefinition,
	getAgentDir,
} from "@earendil-works/pi-coding-agent";

const LAYER = "Layer 0h (mac-dependency-safety)";
const WRAPPER = "/etc/pi/bash";
const PROFILE = "/etc/pi/sandbox.sb";
const RG_CONFIG = "/etc/pi/ripgrep.conf";
const HOME = homedir();

// Keep these three lists in step with sandbox.sb — the .sb file is what the
// kernel enforces for bash; these are the in-process mirror for pi's own tools.
const DENIED_DIRS = [
	".ssh",
	".aws",
	".gnupg",
	".kube",
	".config/gcloud",
	".config/gh",
	"Library/Keychains",
	".bitcoin",
	".ethereum",
	".electrum",
	".config/solana",
	"Library/Application Support/Bitcoin",
	"Library/Application Support/Electrum",
	"Library/Application Support/Exodus",
	"Library/Application Support/Ledger Live",
].map((rel) => join(HOME, rel));

const DENIED_FILES = [
	".netrc",
	".git-credentials",
	".pypirc",
	".npmrc", // read tool only — the bash sandbox exempts ~/.npmrc (Layer 1 dependency)
	".docker/config.json",
	".pi/agent/auth.json",
	".codex/auth.json",
	".claude/.credentials.json",
	".hermes/auth.json",
].map((rel) => join(HOME, rel));

// Anywhere on disk, by final path component.
const DENIED_BASENAMES = [/^\.env(\..*)?$/, /^\.envrc$/, /^\.npmrc$/];

// Write-protected in addition to the credential dirs: this layer's own files.
const WRITE_PROTECTED_DIRS = [join(getAgentDir(), "extensions")];

function underDir(abs: string, dir: string): boolean {
	return abs === dir || abs.startsWith(`${dir}/`);
}

// pi's own path normalisation (utils/paths.js normalizePath with the options
// the tools use: unicode spaces → " ", leading "@" stripped, "~" expanded,
// file:// URLs converted). Not exported by the package, so mirrored here —
// the guard must see the same path the tool will open.
const UNICODE_SPACES = /[\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]/g;
function normalizeLikePi(input: string): string {
	let p = input.replace(UNICODE_SPACES, " ");
	if (p.startsWith("@")) p = p.slice(1);
	if (p === "~") return HOME;
	if (p.startsWith("~/")) return join(HOME, p.slice(2));
	if (/^file:\/\//.test(p)) {
		try {
			return fileURLToPath(p);
		} catch {
			return p;
		}
	}
	return p;
}

/**
 * Resolve symlinks through the deepest EXISTING ancestor, so a not-yet-
 * existing target under a symlinked parent (`/tmp/link/new-key` where
 * /tmp/link → ~/.ssh) still lands on its real destination.
 */
function realpathDeep(abs: string): string {
	let probe = abs;
	const tail: string[] = [];
	for (;;) {
		try {
			const real = realpathSync.native(probe);
			return tail.length ? join(real, ...tail) : real;
		} catch {
			const parent = dirname(probe);
			if (parent === probe) return abs;
			tail.unshift(basename(probe));
			probe = parent;
		}
	}
}

/**
 * Both views of a tool path: the absolute path as written (lexical) and its
 * symlink-resolved destination. Every guard checks BOTH — a `.env` symlink
 * whose target has a benign name is caught lexically, a benign name that
 * points into ~/.ssh is caught by the resolved view.
 */
function views(path: string, cwd: string): string[] {
	const lexical = resolve(cwd, normalizeLikePi(path));
	const resolved = realpathDeep(lexical);
	return resolved === lexical ? [lexical] : [lexical, resolved];
}

function readDeniedOne(abs: string): string | undefined {
	if (DENIED_DIRS.some((d) => underDir(abs, d))) return "credential directory";
	if (DENIED_FILES.includes(abs)) return "credential file";
	if (DENIED_BASENAMES.some((re) => re.test(basename(abs)))) return "secret file pattern";
	return undefined;
}

function writeDeniedOne(abs: string): string | undefined {
	if (DENIED_DIRS.some((d) => underDir(abs, d))) return "credential directory";
	if (WRITE_PROTECTED_DIRS.some((d) => underDir(abs, d))) return "dependency-safety extension directory";
	return undefined;
}

function dirDeniedOne(abs: string): string | undefined {
	return DENIED_DIRS.some((d) => underDir(abs, d)) ? "credential directory" : undefined;
}

function firstDenial(paths: string[], check: (abs: string) => string | undefined): string | undefined {
	for (const p of paths) {
		const why = check(p);
		if (why) return why;
	}
	return undefined;
}

/**
 * A user `glob` for the grep tool is passed to rg AFTER the config file, and
 * rg's last matching glob wins — so `glob: "**"` re-includes every file the
 * root-owned ripgrep.conf excluded (verified 2026-08-30: `rg --glob '**'`
 * listed .env). Rather than parse rg's glob dialect exactly, reject any glob
 * that would match a representative secret name; narrow globs (`*.ts`,
 * `src/**`) pass untouched.
 */
const SECRET_SAMPLES = [
	".env",
	".env.local",
	".envrc",
	".npmrc",
	".netrc",
	".git-credentials",
	".pypirc",
	"auth.json",
	".credentials.json",
	"hosts.yml",
	"config.json",
	"id_rsa",
	"id_ed25519",
	"credentials",
	"keystore",
	"login.keychain-db",
];
function globReincludesSecrets(glob: string): boolean {
	if (glob.startsWith("!")) return false; // an exclusion can only narrow further
	const alternatives = glob.split(",").map((g) => g.trim()).filter(Boolean);
	for (const alt of alternatives) {
		const re = new RegExp(
			`^${alt
				.replace(/[.+^$()|[\]\\]/g, "\\$&")
				.replace(/\{([^}]*)\}/g, (_m, inner: string) => `(?:${inner.split(",").map((x) => x.trim()).join("|")})`)
				.replace(/\*\*\/?/g, "\u0000")
				.replace(/\*/g, "[^/]*")
				.replace(/\?/g, "[^/]")
				.replace(/\u0000/g, ".*")}$`,
		);
		for (const name of SECRET_SAMPLES) {
			if (re.test(name) || re.test(`dir/${name}`) || re.test(`${HOME}/.ssh/${name}`)) return true;
		}
	}
	return false;
}

function denyResult(what: string, path: string, why: string) {
	return {
		content: [
			{
				type: "text" as const,
				text: `${LAYER}: ${what} of "${path}" denied — ${why}. Credential paths (~/.ssh, ~/.aws, cloud/CLI auth stores, .env*, .npmrc, wallets) are off-limits to the agent on this machine.`,
			},
		],
		details: { blocked: true, layer: "0h", why },
		isError: true,
	};
}

/** User shell settings that the built-in bash tool would have honoured. */
function shellSettings(): { commandPrefix?: string; shellPath?: string } {
	try {
		const raw = JSON.parse(readFileSync(join(getAgentDir(), "settings.json"), "utf-8"));
		const shellPath = typeof raw.shellPath === "string" ? raw.shellPath.replace(/^~(?=\/|$)/, HOME) : undefined;
		return {
			commandPrefix: typeof raw.shellCommandPrefix === "string" ? raw.shellCommandPrefix : undefined,
			shellPath,
		};
	} catch {
		return {};
	}
}

export default function (pi: ExtensionAPI) {
	const settings = shellSettings();
	// A user who already pointed settings.shellPath at the wrapper would make
	// the wrapper exec itself under sandbox-exec forever; treat that as the
	// default-shell case.
	if (settings.shellPath && settings.shellPath !== WRAPPER) process.env.PI_SANDBOX_INNER_SHELL = settings.shellPath;
	// Root-owned ripgrep policy for the grep tool. When it is missing the
	// tool_call hook below blocks grep outright (fail closed) rather than
	// letting rg run with whatever config the environment supplies.
	if (existsSync(RG_CONFIG)) process.env.RIPGREP_CONFIG_PATH = RG_CONFIG;

	// --- 1. bash: root-owned Seatbelt wrapper --------------------------------
	// Definitions are built per call with ctx.cwd: the extension factory runs
	// once per process, but A2A child sessions in the same process have their
	// own cwd, and a tool bound to the host's cwd would run commands in the
	// wrong directory.
	const bashPrompt = createBashToolDefinition(process.cwd());
	pi.registerTool({
		name: "bash",
		label: "bash (sandboxed)",
		description: bashPrompt.description,
		parameters: bashPrompt.parameters,
		promptSnippet: bashPrompt.promptSnippet,
		promptGuidelines: bashPrompt.promptGuidelines,
		async execute(toolCallId, params, signal, onUpdate, ctx) {
			if (!existsSync(WRAPPER) || !existsSync(PROFILE)) {
				return {
					content: [
						{
							type: "text" as const,
							text: `${LAYER}: ${WRAPPER} or ${PROFILE} is missing, so bash is disabled (fail-closed). Install per mac-dependency-safety README §0h (sudo) or remove ~/.pi/agent/extensions/dependency-safety.ts to run unsandboxed.`,
						},
					],
					details: { blocked: true, layer: "0h", why: "wrapper missing" },
					isError: true,
				};
			}
			const cwd = ctx?.cwd ?? process.cwd();
			const def = createBashToolDefinition(cwd, {
				operations: createLocalBashOperations({ shellPath: WRAPPER }),
				commandPrefix: settings.commandPrefix,
			});
			return def.execute(toolCallId, params, signal, onUpdate, ctx);
		},
	});

	// --- 2. read: in-process path deny, delegate when allowed -----------------
	const readPrompt = createReadToolDefinition(process.cwd());
	pi.registerTool({
		name: "read",
		label: "read (guarded)",
		description: readPrompt.description,
		parameters: readPrompt.parameters,
		promptSnippet: readPrompt.promptSnippet,
		promptGuidelines: readPrompt.promptGuidelines,
		async execute(toolCallId, params, signal, onUpdate, ctx) {
			const cwd = ctx?.cwd ?? process.cwd();
			const why = firstDenial(views(params.path, cwd), readDeniedOne);
			if (why) return denyResult("read", params.path, why);
			return createReadToolDefinition(cwd).execute(toolCallId, params, signal, onUpdate, ctx);
		},
	});

	// --- 3/4. write/edit into, and grep/find/ls of, credential locations -------
	pi.on("tool_call", (event, ctx) => {
		const input = event.input as { path?: unknown; glob?: unknown };
		const tool = event.toolName;
		if (tool !== "write" && tool !== "edit" && tool !== "grep" && tool !== "find" && tool !== "ls") return undefined;
		// grep/find/ls default to the cwd when path is omitted — check that,
		// never skip the guard.
		const rawPath = typeof input?.path === "string" && input.path.length > 0 ? input.path : tool === "write" || tool === "edit" ? undefined : ".";
		if (rawPath === undefined) return undefined;
		const paths = views(rawPath, ctx.cwd);
		let why: string | undefined;
		if (tool === "write" || tool === "edit") {
			why = firstDenial(paths, writeDeniedOne);
		} else if (tool === "grep") {
			if (!existsSync(RG_CONFIG)) {
				why = `${RG_CONFIG} is missing, so grep is disabled (fail-closed); install per README §0h`;
			} else {
				// An explicit file operand puts rg in single-file mode where the
				// config's --glob exclusions do not apply — so grep targets get the
				// full read deny set, same as the read tool.
				why = firstDenial(paths, readDeniedOne);
				if (!why && typeof input.glob === "string" && globReincludesSecrets(input.glob)) {
					why = `glob "${input.glob}" would re-include secret files excluded by ${RG_CONFIG}; narrow it or omit it`;
				}
			}
		} else {
			why = firstDenial(paths, dirDeniedOne);
		}
		if (!why) return undefined;
		return {
			block: true,
			reason: `${LAYER}: ${tool} on "${rawPath}" denied — ${why}.`,
		};
	});
}
