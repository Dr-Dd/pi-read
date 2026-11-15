/**
 * pi-read: lets the agent request time-limited, read-only copies of root-only files.
 * See README.md.
 */

import type { ExtensionAPI, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { PI_SHARE_PATH } from "./config.ts";
import { confirmComponent } from "./confirm.ts";
import { forAgent, forUser, type InstallProblem, installProblem } from "./helper.ts";
import { choosePromptMethods, findAskpass, type PromptMethod, pathWhich } from "./prompt.ts";
import {
	describeListRequest,
	describeRequest,
	durationSeconds,
	formatListResult,
	formatResult,
	type ListRequest,
	listArgs,
	listPrompt,
	MAX_LIST_DEPTH,
	MAX_REASON_LENGTH,
	normalizeListRequest,
	normalizeRequest,
	PASSWORD_QUESTION,
	parseShareOutput,
	type SharedFile,
	type ShareOutput,
	type ShareRequest,
	shareArgs,
	sudoPrompt,
} from "./request.ts";
import {
	drainTerminalInput,
	type RunResult,
	runAskpass,
	runOnTerminal,
	runTmuxPopup,
	sudoRemembers,
	type TerminalInput,
} from "./run.ts";

interface Details {
	method?: PromptMethod;
	shared?: SharedFile[];
	expires?: string;
}

const parameters = Type.Object({
	files: Type.Array(Type.String({ description: "Absolute path of a root-only file" }), {
		minItems: 1,
		maxItems: 64,
		description: "Absolute paths of the files to read",
	}),
	duration: Type.Optional(
		Type.String({
			description: "How long the copies last, like sleep takes it: 90, 90s, 15m, 1h. Default 15m, max 1h",
		}),
	),
	reason: Type.String({
		description: `Why you need the files, in at most ${MAX_REASON_LENGTH} characters; shown to the user`,
	}),
});

const listParameters = Type.Object({
	directories: Type.Array(Type.String({ description: "Absolute path of a root-only directory" }), {
		minItems: 1,
		maxItems: 16,
		description: "Absolute paths of the directories to list",
	}),
	depth: Type.Optional(
		Type.Integer({
			minimum: 1,
			maximum: MAX_LIST_DEPTH,
			description: `How many levels to list: 1 (default) for the directory's own entries, up to ${MAX_LIST_DEPTH}`,
		}),
	),
	duration: Type.Optional(
		Type.String({
			description: "How long the listings last, like sleep takes it: 90, 90s, 15m, 1h. Default 15m, max 1h",
		}),
	),
	reason: Type.String({
		description: `Why you need the listings, in at most ${MAX_REASON_LENGTH} characters; shown to the user`,
	}),
});

/** What a request shows the user: the description printed before sudo, and the askpass prompt. */
interface Approval {
	description: string;
	askpassPrompt: string;
}

function fail(text: string, details: Details = {}) {
	return { content: [{ type: "text" as const, text }], details, isError: true };
}

/** The user answered No to the yes/no question; sudo did not run. */
const REFUSED = "refused";

/**
 * On pi's terminal, when sudo still remembers the password, it would approve without asking: pi
 * asks yes/no first instead. Esc, or No, refuses.
 */
async function confirmIfRemembered(description: string, ctx: ExtensionToolContext): Promise<boolean> {
	if (!(await sudoRemembers(PI_SHARE_PATH))) return true;
	return ctx.ui.custom<boolean>(
		(tui, theme, _kb, done) => confirmComponent(description, theme, done, () => tui.requestRender()),
		{ blocked: { kind: "permission", message: "pi-read: approve the request?" } },
	);
}

async function runWith(
	method: PromptMethod,
	approval: Approval,
	command: string[],
	ctx: ExtensionToolContext,
	signal: AbortSignal | undefined,
	input: TerminalInput,
): Promise<RunResult | typeof REFUSED | undefined> {
	// The terminal and the popup print the request once, then sudo asks only the question (also on
	// a retry after a wrong password). The askpass dialog has to carry the request in its prompt.
	const { description } = approval;
	switch (method) {
		case "tui":
			if (!(await confirmIfRemembered(description, ctx))) return REFUSED;
			return ctx.ui.custom<RunResult>((tui, _theme, _kb, done) => {
				tui.stop();
				// Drain input still on its way (mouse-wheel reports, key releases) before sudo reads the
				// password, then start the TUI again whatever happened, and only then report.
				const run = async (): Promise<RunResult> => {
					try {
						await drainTerminalInput(input);
						return runOnTerminal(description, PASSWORD_QUESTION, command);
					} catch (err) {
						return { code: 1, stdout: "", stderr: err instanceof Error ? err.message : String(err) };
					}
				};
				void run().then((result) => {
					try {
						tui.start();
						tui.requestRender(true);
					} finally {
						done(result);
					}
				});
				return { render: () => [], invalidate: () => {} };
			});
		case "tmux":
			return runTmuxPopup(description, PASSWORD_QUESTION, command);
		case "askpass": {
			const askpass = findAskpass(process.env, pathWhich(process.env));
			return askpass ? runAskpass(askpass, approval.askpassPrompt, command, { signal }) : undefined;
		}
	}
}

/**
 * Run sudo pi-share with the first prompt method that works and turn its output into the tool
 * result. duration is the one asked for, the deadline when an older pi-share reports none.
 */
async function share(
	tool: string,
	approval: Approval,
	command: string[],
	duration: string,
	format: (files: SharedFile[], expires: Date) => string,
	ctx: ExtensionToolContext,
	signal: AbortSignal | undefined,
	input: TerminalInput,
) {
	const methods = choosePromptMethods(process.env, ctx.mode, pathWhich(process.env));
	for (const method of methods) {
		const result = await runWith(method, approval, command, ctx, signal, input);
		if (!result) continue;
		if (result === REFUSED) return fail(`The request was refused (${method} confirmation).`, { method });
		if (result.code !== 0) {
			const why = result.stderr.trim() || `exit code ${result.code}`;
			return fail(`The request was refused or failed (${method} prompt):\n${why}`, { method });
		}
		let output: ShareOutput;
		try {
			output = parseShareOutput(result.stdout);
		} catch (err) {
			return fail(`${tool}: ${(err as Error).message}`, { method });
		}
		// pi-share reports when the cleanup unit will remove the copies. An older installed
		// helper prints no deadline; fall back to the duration we asked for.
		const expires = output.expires ?? new Date(Date.now() + durationSeconds(duration) * 1000);
		return {
			content: [{ type: "text" as const, text: format(output.files, expires) }],
			details: { method, shared: output.files, expires: expires.toISOString() },
		};
	}
	return fail(
		"No password prompt was available: pi has no terminal, is not inside tmux, and no graphical askpass was found. " +
			"Ask the user to provide the files another way.",
	);
}

export interface PiReadOptions {
	/**
	 * Why the installed pi-share or never-share list cannot be used, if so. Tests replace it: they run
	 * no real pi-share.
	 */
	helperProblem?: () => InstallProblem | undefined;
	/** pi's terminal input, drained before sudo asks on it. Tests replace it. */
	terminalInput?: TerminalInput;
}

/** session_start reasons that warn: pi starting, and /reload (when a fresh pi update takes effect). */
const WARN_REASONS = new Set(["startup", "reload"]);

export default function piRead(pi: ExtensionAPI, options: PiReadOptions = {}): void {
	const checkHelper = options.helperProblem ?? (() => installProblem());
	const input = options.terminalInput ?? process.stdin;
	// Tell the user when install.sh has to run, before the agent's first request fails. Only tells:
	// running install.sh needs the user's sudo password.
	pi.on("session_start", (event, ctx) => {
		if (!ctx.hasUI || !WARN_REASONS.has(event.reason)) return;
		const problem = checkHelper();
		if (problem) ctx.ui.notify(forUser(problem), "warning");
	});
	// Registered before request_root_read: tests that load one tool take the last one registered.
	pi.registerTool({
		name: "request_root_list",
		label: "Request root list",
		description:
			"Ask the user for listings of root-only directories, one level or recursively. The user approves with their sudo password. " +
			"Returns the path of each listing (ls -l style, symlinks not followed); the listings are deleted when the duration ends or pi exits.",
		promptSnippet: "Request time-limited listings of root-only directories (user approves with sudo)",
		promptGuidelines: [
			"Use request_root_list only when a directory you need is unreadable as the current user; prefer depth 1 and go deeper only when needed.",
			"request_root_list leaves out never-shared entries (only counting them) and stops at 5000 entries per directory; read the # lines at the end of a listing.",
		],
		parameters: listParameters,
		executionMode: "sequential",
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			let req: ListRequest;
			try {
				req = normalizeListRequest(params);
			} catch (err) {
				return fail(`request_root_list: ${(err as Error).message}`);
			}
			const problem = checkHelper();
			if (problem) return fail(`request_root_list: ${forAgent(problem)}`);
			const approval = { description: describeListRequest(req), askpassPrompt: listPrompt(req) };
			const command = [PI_SHARE_PATH, ...listArgs(req, process.pid)];
			return share("request_root_list", approval, command, req.duration, formatListResult, ctx, signal, input);
		},
	});
	pi.registerTool({
		name: "request_root_read",
		label: "Request root read",
		description:
			"Ask the user for temporary read-only copies of root-only files. The user approves with their sudo password. " +
			"Returns the path of each copy; the copies are snapshots and are deleted when the duration ends or pi exits.",
		promptSnippet: "Request time-limited read-only copies of root-only files (user approves with sudo)",
		promptGuidelines: [
			"Use request_root_read only when a file you need is unreadable as the current user; request only the files you need, with a short reason.",
			"Prefer short request_root_read durations (the default 15m is usually enough; the maximum is 1h).",
			"After request_root_read succeeds, read the returned copy paths with your normal read tools; ask again for a fresh copy.",
			"The copies are filtered: a line gitleaks flags reads [REDACTED] instead of its content, and a request whose filtering fails shares nothing.",
		],
		parameters,
		executionMode: "sequential",
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			let req: ShareRequest;
			try {
				req = normalizeRequest(params);
			} catch (err) {
				return fail(`request_root_read: ${(err as Error).message}`);
			}
			const problem = checkHelper();
			if (problem) return fail(`request_root_read: ${forAgent(problem)}`);
			const approval = { description: describeRequest(req), askpassPrompt: sudoPrompt(req) };
			const command = [PI_SHARE_PATH, ...shareArgs(req, process.pid)];
			return share("request_root_read", approval, command, req.duration, formatResult, ctx, signal, input);
		},
	});
}
