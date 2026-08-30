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
 */

import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
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

/** Absolute, `~`-expanded, symlink-resolved where the path exists. */
function canonical(path: string, cwd: string): string {
	const expanded = path === "~" ? HOME : path.startsWith("~/") ? join(HOME, path.slice(2)) : path;
	const abs = resolve(cwd, expanded);
	try {
		return realpathSync.native(abs);
	} catch {
		return abs;
	}
}

function readDenied(abs: string): string | undefined {
	if (DENIED_DIRS.some((d) => underDir(abs, d))) return "credential directory";
	if (DENIED_FILES.includes(abs)) return "credential file";
	if (DENIED_BASENAMES.some((re) => re.test(basename(abs)))) return "secret file pattern";
	return undefined;
}

function writeDenied(abs: string): string | undefined {
	if (DENIED_DIRS.some((d) => underDir(abs, d))) return "credential directory";
	if (WRITE_PROTECTED_DIRS.some((d) => underDir(abs, d))) return "dependency-safety extension directory";
	return undefined;
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
	if (settings.shellPath) process.env.PI_SANDBOX_INNER_SHELL = settings.shellPath;
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
			const abs = canonical(params.path, cwd);
			const why = readDenied(abs);
			if (why) return denyResult("read", params.path, why);
			return createReadToolDefinition(cwd).execute(toolCallId, params, signal, onUpdate, ctx);
		},
	});

	// --- 3/4. write/edit into, and grep/find/ls of, credential locations -------
	pi.on("tool_call", (event, ctx) => {
		const input = event.input as { path?: unknown };
		if (typeof input?.path !== "string") return undefined;
		const abs = canonical(input.path, ctx.cwd);
		let why: string | undefined;
		if (event.toolName === "write" || event.toolName === "edit") {
			why = writeDenied(abs);
		} else if (event.toolName === "grep" || event.toolName === "find" || event.toolName === "ls") {
			why = DENIED_DIRS.some((d) => underDir(abs, d)) ? "credential directory" : undefined;
		}
		if (!why) return undefined;
		return {
			block: true,
			reason: `${LAYER}: ${event.toolName} on "${input.path}" denied — ${why}.`,
		};
	});
}
