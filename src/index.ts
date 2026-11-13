/**
 * pi-read: lets the agent request time-limited, read-only copies of root-only files.
 * See README.md.
 */

import type { ExtensionAPI, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { PI_SHARE_PATH } from "./config.ts";
import { choosePromptMethods, findAskpass, type PromptMethod, pathWhich } from "./prompt.ts";
import {
	describeRequest,
	durationSeconds,
	formatResult,
	normalizeRequest,
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
	reason: Type.String({ description: "Why you need the files; shown to the user" }),
});

function fail(text: string, details: Details = {}) {
	return { content: [{ type: "text" as const, text }], details, isError: true };
}

async function runWith(
	method: PromptMethod,
	req: ShareRequest,
	command: string[],
	ctx: ExtensionToolContext,
	signal: AbortSignal | undefined,
): Promise<RunResult | undefined> {
	const description = describeRequest(req);
	const prompt = sudoPrompt(req);
	switch (method) {
		case "tui":
			return ctx.ui.custom<RunResult>((tui, _theme, _kb, done) => {
				tui.stop();
				let result: RunResult;
				try {
					result = runOnTerminal(description, prompt, command);
				} finally {
					tui.start();
					tui.requestRender(true);
				}
				done(result);
				return { render: () => [], invalidate: () => {} };
			});
		case "tmux":
			return runTmuxPopup(description, prompt, command);
		case "askpass": {
			const askpass = findAskpass(process.env, pathWhich(process.env));
			return askpass ? runAskpass(askpass, prompt, command, { signal }) : undefined;
		}
	}
}

export default function piRead(pi: ExtensionAPI): void {
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
			const command = [PI_SHARE_PATH, ...shareArgs(req, process.pid)];
			const methods = choosePromptMethods(process.env, ctx.mode, pathWhich(process.env));
			for (const method of methods) {
				const result = await runWith(method, req, command, ctx, signal);
				if (!result) continue;
				if (result.code !== 0) {
					const why = result.stderr.trim() || `exit code ${result.code}`;
					return fail(`The request was refused or failed (${method} prompt):\n${why}`, { method });
				}
				let output: ShareOutput;
				try {
					output = parseShareOutput(result.stdout);
				} catch (err) {
					return fail(`request_root_read: ${(err as Error).message}`, { method });
				}
				// pi-share reports when the cleanup unit will remove the copies. An older installed
				// helper prints no deadline; fall back to the duration we asked for.
				const expires = output.expires ?? new Date(Date.now() + durationSeconds(req.duration) * 1000);
				return {
					content: [{ type: "text" as const, text: formatResult(output.files, expires) }],
					details: { method, shared: output.files, expires: expires.toISOString() },
				};
			}
			return fail(
				"No password prompt was available: pi has no terminal, is not inside tmux, and no graphical askpass was found. " +
					"Ask the user to provide the files another way.",
			);
		},
	});
}
