import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import piRead from "../src/index.ts";
import { captureStdout, makeFakes, pathWith, withEnv } from "./helpers.ts";

interface RuntimeTool {
	execute(
		toolCallId: string,
		params: { files: string[]; reason: string },
		signal: undefined,
		onUpdate: undefined,
		ctx: ExtensionToolContext,
	): Promise<{ isError?: boolean; details: { method?: string } }>;
}

function loadTool(): RuntimeTool {
	let registered: ToolDefinition | undefined;
	// A fake sudo runs here, never the installed pi-share, so its check is switched off.
	piRead(
		{
			registerTool: (tool: ToolDefinition) => {
				registered = tool;
			},
		} as unknown as ExtensionAPI,
		{ helperProblem: () => undefined },
	);
	assert.ok(registered, "the extension registered no tool");
	return registered as unknown as RuntimeTool;
}

const tool = loadTool();
const params = { files: ["/etc/x"], reason: "because" };
const question = "Password to approve (cancel to refuse): ";
const header = "pi-read: the agent asks to read these root-only files";
// A fake sudo that saves its -p argument (the third one, after -k [-A] -p) and reports one copy.
const sudoSavingPrompt = (log: string, promptArg: number) =>
	`#!/bin/sh\nprintf '%s' "$${promptArg}" > '${log}'\nprintf "req\\tcopy\\n"\n`;
const noPrompt = { TMUX: undefined, DISPLAY: undefined, WAYLAND_DISPLAY: undefined, SUDO_ASKPASS: undefined };

test("on pi's terminal the request is printed once and sudo asks only the question", async () => {
	const fakes = makeFakes();
	try {
		const log = join(fakes.dir, "prompt");
		fakes.write("sudo", sudoSavingPrompt(log, 3));
		const tui = { stop: () => {}, start: () => {}, requestRender: () => {} };
		const ctx = {
			mode: "tui",
			ui: {
				custom: (factory: (tui: unknown, theme: unknown, kb: unknown, done: (result: unknown) => void) => unknown) =>
					new Promise((resolve) => {
						factory(tui, undefined, undefined, resolve);
					}),
			},
		} as unknown as ExtensionToolContext;
		const { result, written } = await captureStdout(() =>
			withEnv({ ...noPrompt, PATH: pathWith(fakes.dir) }, () => tool.execute("id", params, undefined, undefined, ctx)),
		);
		assert.equal(result.details.method, "tui");
		assert.equal(written.split(header).length - 1, 1);
		assert.equal(readFileSync(log, "utf8"), question);
	} finally {
		fakes.cleanup();
	}
});

test("the askpass prompt carries the request, since nothing else shows it", async () => {
	const fakes = makeFakes();
	try {
		const log = join(fakes.dir, "prompt");
		fakes.write("sudo", sudoSavingPrompt(log, 4));
		const askpass = fakes.write("askpass", "#!/bin/sh\nexit 0\n");
		const ctx = { mode: "print" } as unknown as ExtensionToolContext;
		const result = await withEnv({ ...noPrompt, PATH: pathWith(fakes.dir), DISPLAY: ":0", SUDO_ASKPASS: askpass }, () =>
			tool.execute("id", params, undefined, undefined, ctx),
		);
		assert.equal(result.details.method, "askpass");
		assert.equal(readFileSync(log, "utf8"), `${header}\n  /etc/x\nfor 15m. Reason: because\n${question}`);
	} finally {
		fakes.cleanup();
	}
});
