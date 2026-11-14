import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { forAgent, forUser, type InstallProblem, installProblem } from "../src/helper.ts";
import piRead from "../src/index.ts";
import { makeFakes, pathWith, withEnv } from "./helpers.ts";

const installScript = fileURLToPath(new URL("../install.sh", import.meta.url));
const repoPiShare = fileURLToPath(new URL("../bin/pi-share", import.meta.url));

type Handler = (event: { type: "session_start"; reason: string }, ctx: unknown) => unknown;

/** Load the extension with the given check and return its session_start handler. */
function startHandler(problem: InstallProblem | undefined): Handler {
	let handler: Handler | undefined;
	piRead(
		{
			registerTool: () => {},
			on: (event: string, fn: Handler) => {
				if (event === "session_start") handler = fn;
			},
		} as unknown as ExtensionAPI,
		{ helperProblem: () => problem },
	);
	assert.ok(handler, "session_start handler registered");
	return handler;
}

/** Run the handler for a reason and return the notify calls it made. */
async function start(problem: InstallProblem | undefined, reason: string, hasUI = true) {
	const calls: [string, string | undefined][] = [];
	const ctx = { hasUI, ui: { notify: (message: string, type?: string) => calls.push([message, type]) } };
	await startHandler(problem)({ type: "session_start", reason }, ctx);
	return calls;
}

const stale: InstallProblem = { problem: "pi-share is stale", again: true };

test("startup with a problem warns once with the user wording and the install.sh path", async () => {
	const calls = await start(stale, "startup");
	assert.deepEqual(calls, [[forUser(stale), "warning"]]);
	assert.ok(calls[0]?.[0].includes(installScript));
});

test("reload with a problem warns the same way", async () => {
	assert.deepEqual(await start(stale, "reload"), [[forUser(stale), "warning"]]);
});

test("new, resume and fork with a problem show nothing", async () => {
	for (const reason of ["new", "resume", "fork"]) {
		assert.deepEqual(await start(stale, reason), [], reason);
	}
});

test("startup with no problem shows nothing", async () => {
	assert.deepEqual(await start(undefined, "startup"), []);
});

test("startup with a problem and no UI shows nothing and does not throw", async () => {
	assert.deepEqual(await start(stale, "startup", false), []);
	// A ctx without ui at all must not be touched either.
	await startHandler(stale)({ type: "session_start", reason: "startup" }, { hasUI: false });
});

test("the startup handler starts no process", async () => {
	const fakes = makeFakes();
	try {
		const marker = join(fakes.dir, "ran");
		for (const name of ["sudo", "bash", "sh"]) fakes.write(name, `#!/bin/sh\necho ${name} >> '${marker}'\n`);
		await withEnv({ PATH: pathWith(fakes.dir) }, () => start(stale, "startup"));
		assert.throws(() => readFileSync(marker), /ENOENT/);
	} finally {
		fakes.cleanup();
	}
});

test("forUser tells the user to run install.sh, again when needed, without 'Ask the user'", () => {
	const once = forUser({ problem: "x is missing", again: false });
	assert.equal(once, `pi-read: x is missing. Run ${installScript}`);
	assert.equal(forUser({ problem: "x differs", again: true }), `pi-read: x differs. Run ${installScript} again`);
	assert.doesNotMatch(once, /Ask the user/);
});

test("forAgent keeps the agent wording", () => {
	assert.equal(
		forAgent({ problem: "x is missing", again: false }),
		`x is missing. Ask the user to run ${installScript}`,
	);
	assert.equal(
		forAgent({ problem: "x differs", again: true }),
		`x differs. Ask the user to run ${installScript} again`,
	);
});

test("installProblem reports pi-share first, then the list, then nothing", () => {
	const fakes = makeFakes();
	try {
		const piShare = join(fakes.dir, "pi-share");
		const list = join(fakes.dir, "never-share.list");
		assert.match(installProblem(piShare, repoPiShare, list)?.problem ?? "", /^pi-share is not installed/);
		fakes.write("pi-share", readFileSync(repoPiShare, "utf8"));
		assert.match(installProblem(piShare, repoPiShare, list)?.problem ?? "", /^the never-share list is not installed/);
		fakes.write("never-share.list", "/root\n");
		assert.equal(installProblem(piShare, repoPiShare, list), undefined);
	} finally {
		fakes.cleanup();
	}
});
