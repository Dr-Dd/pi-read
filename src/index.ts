/**
 * pi-read: lets the agent request time-limited, read-only copies of root-only files.
 * See README.md.
 */

import type { ExtensionAPI, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { PI_SHARE_PATH } from "./config.ts";
import { helperProblem, neverShareProblem } from "./helper.ts";
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
import { type RunResult, runAskpass, runOnTerminal, runTmuxPopup } from "./run.ts";

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

async function runWith(
	method: PromptMethod,
	approval: Approval,
	command: string[],
	ctx: ExtensionToolContext,
	signal: AbortSignal | undefined,
): Promise<RunResult | undefined> {
	// The terminal and the popup print the request once, then sudo asks only the question (also on
	// a retry after a wrong password). The askpass dialog has to carry the request in its prompt.
	const { description } = approval;
	switch (method) {
		case "tui":
			return ctx.ui.custom<RunResult>((tui, _theme, _kb, done) => {
				tui.stop();
				let result: RunResult;
				try {
					result = runOnTerminal(description, PASSWORD_QUESTION, command);
				} finally {
					tui.start();
					tui.requestRender(true);
				}
				done(result);
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
) {
	const methods = choosePromptMethods(process.env, ctx.mode, pathWhich(process.env));
	for (const method of methods) {
		const result = await runWith(method, approval, command, ctx, signal);
		if (!result) continue;
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
	helperProblem?: () => string | undefined;
}

export default function piRead(pi: ExtensionAPI, options: PiReadOptions = {}): void {
	const checkHelper = options.helperProblem ?? (() => helperProblem() ?? neverShareProblem());
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
			if (problem) return fail(`request_root_list: ${problem}`);
			const approval = { description: describeListRequest(req), askpassPrompt: listPrompt(req) };
			const command = [PI_SHARE_PATH, ...listArgs(req, process.pid)];
			return share("request_root_list", approval, command, req.duration, formatListResult, ctx, signal);
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
			if (problem) return fail(`request_root_read: ${problem}`);
			const approval = { description: describeRequest(req), askpassPrompt: sudoPrompt(req) };
			const command = [PI_SHARE_PATH, ...shareArgs(req, process.pid)];
			return share("request_root_read", approval, command, req.duration, formatResult, ctx, signal);
		},
	});
}
