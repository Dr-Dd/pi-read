import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import piRead from "../src/index.ts";
import type { Lookup } from "../src/trusted.ts";
import { type Fakes, makeFakes, pathWith, withEnv } from "./helpers.ts";

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

function loadTool(lookup: Lookup): RuntimeTool {
	let registered: ToolDefinition | undefined;
	// Fake commands stand in for sudo and pi-share, so the installation check is switched off.
	piRead(
		{
			registerTool: (tool: ToolDefinition) => {
				registered = tool;
			},
			on: () => {},
		} as unknown as ExtensionAPI,
		{ helperProblem: () => undefined, lookup },
	);
	assert.ok(registered, "the extension registered no tool");
	return registered as unknown as RuntimeTool;
}

const params = { files: ["/etc/x"], reason: "because" };
const plainContext = { mode: "print" } as unknown as ExtensionToolContext;
const noPrompt = { TMUX: undefined, DISPLAY: undefined, WAYLAND_DISPLAY: undefined, SUDO_ASKPASS: undefined };

/**
 * Two directories: "trusted" holds the programs the lookup returns, "planted" the ones an agent put
 * first on PATH. A planted program leaves a marker when it runs.
 */
function setup(): { trusted: Fakes; planted: Fakes; plantedRan: string; cleanup(): void } {
	const trusted = makeFakes();
	const planted = makeFakes();
	const plantedRan = join(planted.dir, "planted-ran");
	for (const name of ["sudo", "tmux", "sh", "askpass", "ksshaskpass"]) {
		planted.write(name, `#!/bin/sh\necho ${name} >> '${plantedRan}'\nexit 0\n`);
	}
	return {
		trusted,
		planted,
		plantedRan,
		cleanup: () => {
			trusted.cleanup();
			planted.cleanup();
		},
	};
}

function lookupIn(dir: string, file: Lookup["file"] = () => undefined): Lookup {
	return {
		command: (name) => (existsSync(join(dir, name)) ? join(dir, name) : undefined),
		file,
	};
}

test("execute runs the sudo the lookup returns, never a sudo planted first on PATH", async () => {
	const s = setup();
	try {
		s.trusted.write("sudo", '#!/bin/sh\nprintf "req\\tcopy\\n"\n');
		s.trusted.write("ksshaskpass", "#!/bin/sh\n");
		const tool = loadTool(lookupIn(s.trusted.dir));
		const result = await withEnv({ ...noPrompt, PATH: pathWith(s.planted.dir), DISPLAY: ":0" }, () =>
			tool.execute("id", params, undefined, undefined, plainContext),
		);
		assert.equal(result.isError, undefined);
		assert.equal(result.details.method, "askpass");
		assert.equal(existsSync(s.plantedRan), false);
	} finally {
		s.cleanup();
	}
});

test("execute runs the tmux and sh the lookup returns, never ones planted first on PATH", async () => {
	const s = setup();
	try {
		const log = join(s.trusted.dir, "ran.log");
		s.trusted.write("sudo", `#!/bin/sh\necho sudo >> '${log}'\nprintf "req\\tcopy\\n"\n`);
		s.trusted.write("sh", `#!/bin/sh\necho sh >> '${log}'\nexec /bin/sh "$@"\n`);
		// The trusted tmux runs the popup command (its last argument) with the system shell.
		s.trusted.write("tmux", `#!/bin/sh\necho tmux >> '${log}'\nfor last; do :; done\nexec /bin/sh -c "$last"\n`);
		const tool = loadTool(lookupIn(s.trusted.dir));
		const result = await withEnv({ ...noPrompt, PATH: pathWith(s.planted.dir), TMUX: "/tmp/tmux-1/default,1,0" }, () =>
			tool.execute("id", params, undefined, undefined, plainContext),
		);
		assert.equal(result.isError, undefined);
		assert.equal(result.details.method, "tmux");
		assert.deepEqual(readFileSync(log, "utf8").trimEnd().split("\n"), ["tmux", "sh", "sudo"]);
		assert.equal(existsSync(s.plantedRan), false);
	} finally {
		s.cleanup();
	}
});

test("execute uses $SUDO_ASKPASS only when lookup.file accepts it, passing the path lookup.file returned", async () => {
	const s = setup();
	try {
		const log = join(s.trusted.dir, "askpass.log");
		s.trusted.write("sudo", `#!/bin/sh\necho "$SUDO_ASKPASS" >> '${log}'\nprintf "req\\tcopy\\n"\n`);
		s.trusted.write("ksshaskpass", "#!/bin/sh\n");
		const configured = join(s.planted.dir, "askpass");
		const env = { ...noPrompt, PATH: pathWith(s.planted.dir), DISPLAY: ":0", SUDO_ASKPASS: configured };

		const refusing = loadTool(lookupIn(s.trusted.dir, () => undefined));
		await withEnv(env, () => refusing.execute("id", params, undefined, undefined, plainContext));
		const accepting = loadTool(lookupIn(s.trusted.dir, (p) => (p === configured ? "/checked/askpass" : undefined)));
		await withEnv(env, () => accepting.execute("id", params, undefined, undefined, plainContext));

		assert.deepEqual(readFileSync(log, "utf8").trimEnd().split("\n"), [
			join(s.trusted.dir, "ksshaskpass"),
			"/checked/askpass",
		]);
		assert.equal(existsSync(s.plantedRan), false);
	} finally {
		s.cleanup();
	}
});

test("execute fails with the no-trusted-sudo message, running nothing, when the lookup finds no sudo", async () => {
	const s = setup();
	try {
		s.trusted.write("ksshaskpass", `#!/bin/sh\necho ran >> '${s.plantedRan}'\n`);
		const tool = loadTool(lookupIn(s.trusted.dir));
		const result = await withEnv({ ...noPrompt, PATH: pathWith(s.planted.dir), DISPLAY: ":0" }, () =>
			tool.execute("id", params, undefined, undefined, plainContext),
		);
		assert.equal(result.isError, true);
		assert.equal(
			result.content[0]?.text,
			"No trusted sudo was found: pi-read runs only a root-owned sudo, not writable by group or others, " +
				"from /usr/local/sbin, /usr/local/bin, /usr/sbin, /usr/bin, /sbin or /bin. " +
				"Ask the user to provide the files another way.",
		);
		assert.equal(existsSync(s.plantedRan), false);
	} finally {
		s.cleanup();
	}
});
