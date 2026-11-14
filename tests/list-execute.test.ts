import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import piRead from "../src/index.ts";
import { makeFakes, pathWith, withEnv } from "./helpers.ts";

interface ToolResult {
	content: { type: string; text: string }[];
	details: { method?: string; shared?: { requested: string; copy: string }[]; expires?: string };
	isError?: boolean;
}

interface RuntimeTool {
	name: string;
	execute(
		toolCallId: string,
		params: { directories: string[]; depth?: number; duration?: string; reason: string },
		signal: AbortSignal | undefined,
		onUpdate: undefined,
		ctx: ExtensionToolContext,
	): Promise<ToolResult>;
}

function loadTools(): Map<string, RuntimeTool> {
	const tools = new Map<string, RuntimeTool>();
	// A fake sudo stands in for pi-share, so its installation check is switched off.
	piRead(
		{
			registerTool: (tool: ToolDefinition) => {
				tools.set(tool.name, tool as unknown as RuntimeTool);
			},
			on: () => {},
		} as unknown as ExtensionAPI,
		{ helperProblem: () => undefined },
	);
	return tools;
}

const ctx = { mode: "print" } as unknown as ExtensionToolContext;

function askpassEnv(dir: string, askpass: string): NodeJS.ProcessEnv {
	return {
		PATH: pathWith(dir),
		TMUX: undefined,
		WAYLAND_DISPLAY: undefined,
		DISPLAY: ":0",
		SUDO_ASKPASS: askpass,
	};
}

test("the extension registers both request_root_list and request_root_read", () => {
	assert.deepEqual([...loadTools().keys()].sort(), ["request_root_list", "request_root_read"]);
});

test("request_root_list runs sudo pi-share with --list --depth and returns the listing paths", async () => {
	const fakes = makeFakes();
	try {
		const args = join(fakes.dir, "args");
		fakes.write(
			"sudo",
			`#!/bin/sh\nprintf '%s\\n' "$@" > '${args}'\nprintf "expires\\t1700000000\\n/etc\\t/run/pi-share/x/listing-0\\n"\n`,
		);
		const askpass = fakes.write("askpass", "#!/bin/sh\nexit 0\n");
		const tool = loadTools().get("request_root_list");
		assert.ok(tool);
		const result = await withEnv(askpassEnv(fakes.dir, askpass), () =>
			tool.execute("id", { directories: ["/etc"], depth: 2, reason: "why" }, undefined, undefined, ctx),
		);
		assert.equal(result.isError, undefined);
		assert.deepEqual(result.details.shared, [{ requested: "/etc", copy: "/run/pi-share/x/listing-0" }]);
		assert.equal(result.details.expires, "2023-11-14T22:13:20.000Z");
		assert.match(result.content[0]?.text ?? "", /\/etc -> \/run\/pi-share\/x\/listing-0/);
		const passed = readFileSync(args, "utf8").trimEnd().split("\n");
		const command = passed.slice(passed.indexOf("--") + 1);
		assert.deepEqual(command, [
			"/usr/local/bin/pi-share",
			"--duration",
			"15m",
			"--pid",
			String(process.pid),
			"--list",
			"--depth",
			"2",
			"--",
			"/etc",
		]);
		assert.match(passed[passed.indexOf("-p") + 1] ?? "", /list these root-only directories, 2 levels deep/);
	} finally {
		fakes.cleanup();
	}
});

test("request_root_list maps a refusal to an error and an invalid depth to an error before sudo runs", async () => {
	const fakes = makeFakes();
	try {
		const marker = join(fakes.dir, "sudo-ran");
		fakes.write("sudo", `#!/bin/sh\necho ran > '${marker}'\necho "pi-share: not a directory: /etc/x" >&2\nexit 1\n`);
		const askpass = fakes.write("askpass", "#!/bin/sh\nexit 0\n");
		const tool = loadTools().get("request_root_list");
		assert.ok(tool);
		const bad = await withEnv(askpassEnv(fakes.dir, askpass), () =>
			tool.execute("id", { directories: ["/etc"], depth: 11, reason: "why" }, undefined, undefined, ctx),
		);
		assert.equal(bad.isError, true);
		assert.match(bad.content[0]?.text ?? "", /^request_root_list: invalid depth/);
		assert.throws(() => readFileSync(marker), /ENOENT/);

		const refused = await withEnv(askpassEnv(fakes.dir, askpass), () =>
			tool.execute("id", { directories: ["/etc/x"], reason: "why" }, undefined, undefined, ctx),
		);
		assert.equal(refused.isError, true);
		assert.equal(
			refused.content[0]?.text,
			"The request was refused or failed (askpass prompt):\npi-share: not a directory: /etc/x",
		);
	} finally {
		fakes.cleanup();
	}
});
