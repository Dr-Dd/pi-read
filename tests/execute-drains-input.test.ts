import assert from "node:assert/strict";
import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import piRead from "../src/index.ts";
import type { TerminalInput } from "../src/run.ts";
import { captureStdout, makeFakes, pathWith, withEnv } from "./helpers.ts";

interface ToolResult {
	content: { type: string; text: string }[];
	details: { method?: string };
	isError?: boolean;
}

interface RuntimeTool {
	execute(
		toolCallId: string,
		params: { files: string[]; reason: string },
		signal: undefined,
		onUpdate: undefined,
		ctx: ExtensionToolContext,
	): Promise<ToolResult>;
}

function loadTool(terminalInput: TerminalInput): RuntimeTool {
	let registered: ToolDefinition | undefined;
	piRead(
		{
			registerTool: (tool: ToolDefinition) => {
				registered = tool;
			},
			on: () => {},
		} as unknown as ExtensionAPI,
		{ helperProblem: () => undefined, terminalInput },
	);
	assert.ok(registered);
	return registered as unknown as RuntimeTool;
}

const params = { files: ["/etc/x"], reason: "because" };
const noPrompt = { TMUX: undefined, DISPLAY: undefined, WAYLAND_DISPLAY: undefined, SUDO_ASKPASS: undefined };

function tuiContext(record: (event: string) => () => void): ExtensionToolContext {
	const tui = { stop: record("stop"), start: record("start"), requestRender: record("requestRender") };
	return {
		mode: "tui",
		ui: {
			custom: (factory: (tui: unknown, theme: unknown, kb: unknown, done: (result: unknown) => void) => unknown) =>
				new Promise((resolve) => {
					factory(tui, undefined, undefined, resolve);
				}),
		},
	} as unknown as ExtensionToolContext;
}

test("the tui method stops the TUI, drains the input, runs sudo, then starts the TUI again", async () => {
	const fakes = makeFakes();
	try {
		const log = join(fakes.dir, "order.log");
		// The remembered-password probe (sudo -n ... --probe) runs before the TUI stops: it reports
		// "not remembered" without counting as the sudo run whose order this test checks.
		fakes.write(
			"sudo",
			`#!/bin/sh\nfor a; do [ "$a" = --probe ] && exit 1; done\necho sudo >> '${log}'\nprintf "req\\tcopy\\n"\n`,
		);
		const record = (event: string) => () => appendFileSync(log, `${event}\n`);
		const input: TerminalInput = {
			isTTY: true,
			isRaw: false,
			setRawMode: (mode: boolean) => record(`raw:${mode}`)(),
			on: record("drain-on"),
			off: record("drain-off"),
			resume: () => {},
			pause: () => {},
		};
		const tool = loadTool(input);
		const { result } = await captureStdout(() =>
			withEnv({ ...noPrompt, PATH: pathWith(fakes.dir) }, () =>
				tool.execute("id", params, undefined, undefined, tuiContext(record)),
			),
		);
		assert.equal(result.isError, undefined);
		assert.equal(result.details.method, "tui");
		assert.deepEqual(readFileSync(log, "utf8").trimEnd().split("\n"), [
			"stop",
			"raw:true",
			"drain-on",
			"drain-off",
			"raw:false",
			"sudo",
			"start",
			"requestRender",
		]);
	} finally {
		fakes.cleanup();
	}
});

test("a drain that throws fails the request with its error and starts the TUI again", async () => {
	const fakes = makeFakes();
	try {
		const ran = join(fakes.dir, "sudo-ran");
		// The remembered-password probe (sudo -n ... --probe) runs before the drain: it reports
		// "not remembered" without counting as the sudo run this test checks for.
		fakes.write(
			"sudo",
			`#!/bin/sh\nfor a; do [ "$a" = --probe ] && exit 1; done\ntouch '${ran}'\nprintf "req\\tcopy\\n"\n`,
		);
		const events: string[] = [];
		const record = (event: string) => () => {
			events.push(event);
		};
		const input: TerminalInput = {
			isTTY: true,
			setRawMode: () => {
				throw new Error("setRawMode EIO");
			},
			on: () => {},
			off: () => {},
			resume: () => {},
			pause: () => {},
		};
		const tool = loadTool(input);
		const { result } = await captureStdout(() =>
			withEnv({ ...noPrompt, PATH: pathWith(fakes.dir) }, () =>
				tool.execute("id", params, undefined, undefined, tuiContext(record)),
			),
		);
		assert.equal(result.isError, true);
		assert.match(result.content[0]?.text ?? "", /refused or failed \(tui prompt\):\nsetRawMode EIO/);
		assert.deepEqual(events, ["stop", "start", "requestRender"]);
		assert.throws(() => readFileSync(ran));
	} finally {
		fakes.cleanup();
	}
});
