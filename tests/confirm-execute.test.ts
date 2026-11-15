import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import piRead from "../src/index.ts";
import { captureStdout, makeFakes, pathWith, withEnv } from "./helpers.ts";

interface ToolResult {
	content: { type: string; text: string }[];
	details: { method?: string; shared?: { requested: string; copy: string }[] };
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

interface Component {
	render(width: number): string[];
	handleInput?(data: string): void;
}

function loadTool(): RuntimeTool {
	let registered: ToolDefinition | undefined;
	// A fake sudo stands in for pi-share, so its installation check is switched off.
	piRead(
		{
			registerTool: (tool: ToolDefinition) => {
				registered = tool;
			},
			on: () => {},
		} as unknown as ExtensionAPI,
		{ helperProblem: () => undefined },
	);
	assert.ok(registered, "the extension registered no tool");
	return registered as unknown as RuntimeTool;
}

const tool = loadTool();
const params = { files: ["/etc/x"], reason: "because" };
const noPrompt = { TMUX: undefined, DISPLAY: undefined, WAYLAND_DISPLAY: undefined, SUDO_ASKPASS: undefined };
const theme = { fg: (_c: string, t: string) => t, bold: (t: string) => t };

// A fake sudo that logs each call's arguments, answers `-n -- pi-share --probe` with PROBE (exit
// 0), and otherwise reports one copy.
function fakeSudo(log: string, probe: string): string {
	return [
		"#!/bin/sh",
		`echo "$*" >> '${log}'`,
		`if [ "$1" = -n ] && [ "$4" = --probe ]; then printf '${probe}'; exit 0; fi`,
		'printf "req\\tcopy\\n"',
		"",
	].join("\n");
}

// A tui context whose custom() runs each factory; a component with handleInput (the confirmation)
// is shown and gets the given keys, and every confirmation is recorded.
function tuiContext(keys: string[], shown: string[][]): ExtensionToolContext {
	const tui = { stop: () => {}, start: () => {}, requestRender: () => {} };
	return {
		mode: "tui",
		ui: {
			custom: (factory: (tui: unknown, theme: unknown, kb: unknown, done: (result: unknown) => void) => Component) =>
				new Promise((resolve) => {
					const component = factory(tui, theme, undefined, resolve);
					if (component.handleInput) {
						shown.push(component.render(200));
						for (const key of keys) component.handleInput(key);
					}
				}),
		},
	} as unknown as ExtensionToolContext;
}

async function run(probe: string, keys: string[]) {
	const fakes = makeFakes();
	try {
		const log = join(fakes.dir, "sudo.log");
		fakes.write("sudo", fakeSudo(log, probe));
		const shown: string[][] = [];
		const { result } = await captureStdout(() =>
			withEnv({ ...noPrompt, PATH: pathWith(fakes.dir) }, () =>
				tool.execute("id", params, undefined, undefined, tuiContext(keys, shown)),
			),
		);
		return { result, shown, calls: readFileSync(log, "utf8").trimEnd().split("\n") };
	} finally {
		fakes.cleanup();
	}
}

const PROBE_OK = "pi-share: probe\\n";

test("with the password remembered, No refuses without running sudo pi-share", async () => {
	const { result, shown, calls } = await run(PROBE_OK, ["\x1b[C", "\r"]);
	assert.equal(shown.length, 1);
	assert.ok(shown[0]?.some((l) => l.includes("/etc/x")));
	assert.equal(result.isError, true);
	assert.equal(result.details.method, "tui");
	assert.match(result.content[0]?.text ?? "", /refused \(tui confirmation\)/);
	assert.deepEqual(calls, ["-n -- /usr/local/bin/pi-share --probe"]);
});

test("with the password remembered, Yes runs sudo pi-share without -k and reports the copies", async () => {
	const { result, shown, calls } = await run(PROBE_OK, ["\x1b[D", "\r"]);
	assert.equal(shown.length, 1);
	assert.equal(result.isError, undefined);
	assert.deepEqual(result.details.shared, [{ requested: "req", copy: "copy" }]);
	assert.equal(calls.length, 2);
	assert.match(calls[1] ?? "", /^-p .* -- \/usr\/local\/bin\/pi-share /);
	assert.doesNotMatch(calls[1] ?? "", /(^| )-k( |$)/);
});

test("without the password remembered, no confirmation is shown and sudo asks as before", async () => {
	const fakes = makeFakes();
	try {
		const log = join(fakes.dir, "sudo.log");
		// sudo -n fails, as when a password is needed.
		fakes.write(
			"sudo",
			`#!/bin/sh\necho "$*" >> '${log}'\nif [ "$1" = -n ]; then echo "sudo: a password is required" >&2; exit 1; fi\nprintf "req\\tcopy\\n"\n`,
		);
		const shown: string[][] = [];
		const { result } = await captureStdout(() =>
			withEnv({ ...noPrompt, PATH: pathWith(fakes.dir) }, () =>
				tool.execute("id", params, undefined, undefined, tuiContext([], shown)),
			),
		);
		assert.equal(shown.length, 0);
		assert.equal(result.isError, undefined);
		assert.deepEqual(result.details.shared, [{ requested: "req", copy: "copy" }]);
		assert.equal(readFileSync(log, "utf8").trimEnd().split("\n").length, 2);
	} finally {
		fakes.cleanup();
	}
});

test("a probe that prints anything else counts as not remembered", async () => {
	const { result, shown } = await run("req\\tcopy\\n", []);
	assert.equal(shown.length, 0);
	assert.equal(result.isError, undefined);
	assert.deepEqual(result.details.shared, [{ requested: "req", copy: "copy" }]);
});
