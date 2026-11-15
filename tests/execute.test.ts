import assert from "node:assert/strict";
import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import piRead from "../src/index.ts";
import { captureStdout, makeFakes, pathLookup, pathWith, withEnv } from "./helpers.ts";

interface SharedFile {
	requested: string;
	copy: string;
}

interface ToolResult {
	content: { type: string; text: string }[];
	details: { method?: string; shared?: SharedFile[]; expires?: string };
	isError?: boolean;
}

interface RuntimeTool {
	execute(
		toolCallId: string,
		params: { files: string[]; duration?: string; reason: string },
		signal: AbortSignal | undefined,
		onUpdate: undefined,
		ctx: ExtensionToolContext,
	): Promise<ToolResult>;
}

function loadTool(): RuntimeTool {
	let registered: ToolDefinition | undefined;
	// These tests run a fake sudo, never the installed pi-share, so its check is switched off.
	piRead(
		{
			registerTool: (tool: ToolDefinition) => {
				registered = tool;
			},
			on: () => {},
		} as unknown as ExtensionAPI,
		{ helperProblem: () => undefined, lookup: pathLookup },
	);
	assert.ok(registered, "the extension registered no tool");
	return registered as unknown as RuntimeTool;
}

const tool = loadTool();
const params = { files: ["/etc/x"], reason: "because" };
const plainContext = { mode: "print" } as unknown as ExtensionToolContext;

// No tui, tmux or display, so a test picks only the prompt methods it wants through these env values.
function env(fakesDir: string, values: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
	return {
		PATH: pathWith(fakesDir),
		TMUX: undefined,
		DISPLAY: undefined,
		WAYLAND_DISPLAY: undefined,
		SUDO_ASKPASS: undefined,
		...values,
	};
}

// An askpass program for the askpass method, plus a fake sudo that prints one shared-file line.
function askpassFakes(fakes: ReturnType<typeof makeFakes>, sudoScript: string): { env: NodeJS.ProcessEnv } {
	fakes.write("sudo", sudoScript);
	const askpass = fakes.write("askpass", "#!/bin/sh\nexit 0\n");
	return { env: env(fakes.dir, { DISPLAY: ":0", SUDO_ASKPASS: askpass }) };
}

test("execute runs the tui method on pi's terminal and reports it", async () => {
	const fakes = makeFakes();
	try {
		const log = join(fakes.dir, "order.log");
		// The fake sudo appends to the same log, so its order against stop/start is checked. The first
		// call is the probe for a remembered password (its output does not match, so no confirmation).
		fakes.write("sudo", `#!/bin/sh\necho sudo >> '${log}'\nprintf "req\\tcopy\\n"\n`);
		const record = (event: string) => () => appendFileSync(log, `${event}\n`);
		const tui = {
			stop: record("stop"),
			start: record("start"),
			requestRender: record("requestRender"),
		};
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
			withEnv(env(fakes.dir), () => tool.execute("id", params, undefined, undefined, ctx)),
		);
		assert.equal(result.isError, undefined);
		assert.equal(result.details.method, "tui");
		assert.deepEqual(result.details.shared, [{ requested: "req", copy: "copy" }]);
		assert.match(result.content[0]?.text ?? "", /^Approved\. .*\n {2}req -> copy\n/);
		assert.match(result.details.expires ?? "", /^\d{4}-\d{2}-\d{2}T.*Z$/);
		// runOnTerminal showed the request on pi's terminal between stopping and restarting the TUI.
		assert.match(written, /pi-read: the agent asks to read these root-only files/);
		assert.match(written, /\/etc\/x/);
		assert.deepEqual(readFileSync(log, "utf8").trimEnd().split("\n"), [
			"sudo",
			"stop",
			"sudo",
			"start",
			"requestRender",
		]);
	} finally {
		fakes.cleanup();
	}
});

test("execute falls through a tmux popup that did not run to the askpass method", async () => {
	const fakes = makeFakes();
	try {
		const marker = join(fakes.dir, "tmux-ran");
		const askpass = fakes.write("askpass", "#!/bin/sh\nexit 0\n");
		fakes.write("sudo", '#!/bin/sh\nprintf "req\\tcopy\\n"\n');
		fakes.write("tmux", `#!/bin/sh\necho ran > '${marker}'\nexit 0\n`);
		const result = await withEnv(
			env(fakes.dir, { TMUX: "/tmp/tmux-1/default,1,0", DISPLAY: ":0", SUDO_ASKPASS: askpass }),
			() => tool.execute("id", params, undefined, undefined, plainContext),
		);
		assert.equal(readFileSync(marker, "utf8"), "ran\n");
		assert.equal(result.isError, undefined);
		assert.equal(result.details.method, "askpass");
		assert.deepEqual(result.details.shared, [{ requested: "req", copy: "copy" }]);
	} finally {
		fakes.cleanup();
	}
});

test("execute maps a non-zero prompt result to an error naming the method and sudo's stderr", async () => {
	const fakes = makeFakes();
	try {
		const { env: askpassEnv } = askpassFakes(fakes, '#!/bin/sh\necho "no password" >&2\nexit 1\n');
		const result = await withEnv(askpassEnv, () => tool.execute("id", params, undefined, undefined, plainContext));
		assert.equal(result.isError, true);
		assert.equal(result.content[0]?.text, "The request was refused or failed (askpass prompt):\nno password");
		assert.equal(result.details.method, "askpass");
	} finally {
		fakes.cleanup();
	}
});

test("execute maps malformed and empty pi-share output to errors", async () => {
	const fakes = makeFakes();
	try {
		const { env: askpassEnv } = askpassFakes(fakes, '#!/bin/sh\necho "garbage"\n');
		const malformed = await withEnv(askpassEnv, () => tool.execute("id", params, undefined, undefined, plainContext));
		assert.equal(malformed.isError, true);
		assert.equal(malformed.content[0]?.text, 'request_root_read: unexpected pi-share output: "garbage"');
		assert.equal(malformed.details.method, "askpass");

		fakes.write("sudo", "#!/bin/sh\nexit 0\n");
		const empty = await withEnv(askpassEnv, () => tool.execute("id", params, undefined, undefined, plainContext));
		assert.equal(empty.isError, true);
		assert.equal(empty.content[0]?.text, "request_root_read: pi-share reported no copies");
		assert.equal(empty.details.method, "askpass");
	} finally {
		fakes.cleanup();
	}
});

test("execute reports no available prompt method", async () => {
	const result = await withEnv(
		{ TMUX: undefined, DISPLAY: undefined, WAYLAND_DISPLAY: undefined, SUDO_ASKPASS: undefined },
		() => tool.execute("id", params, undefined, undefined, plainContext),
	);
	assert.equal(result.isError, true);
	assert.equal(
		result.content[0]?.text,
		"No password prompt was available: pi has no terminal, is not inside tmux, and no graphical askpass was found. " +
			"Ask the user to provide the files another way.",
	);
	assert.deepEqual(result.details, {});
});
