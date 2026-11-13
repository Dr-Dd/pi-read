import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";
import { runOnTerminal } from "../src/run.ts";
import { captureStdout, makeFakes } from "./helpers.ts";

const description = "pi-read: the agent asks to read these root-only files\n  /etc/x\nfor 15m. Reason: because";
const prompt = "Password: ";
const command = ["/usr/local/bin/pi-share", "--duration", "15m", "--pid", "1", "--", "/etc/x"];

test("runOnTerminal shows the description and runs sudo without -A", async () => {
	const fakes = makeFakes();
	try {
		const sudo = fakes.write("sudo", '#!/bin/sh\nfor a in "$@"; do echo "arg=$a"; done\necho "oops" >&2\nexit 2\n');
		const before = process.listenerCount("SIGINT");
		const { result, written } = await captureStdout(() => runOnTerminal(description, prompt, command, { sudo }));
		assert.equal(written, `\n${description}\n\n`);
		assert.equal(result.code, 2);
		assert.equal(result.stderr, "oops\n");
		assert.deepEqual(result.stdout.trimEnd().split("\n"), [
			"arg=-k",
			"arg=-p",
			`arg=${prompt}`,
			"arg=--",
			...command.map((a) => `arg=${a}`),
		]);
		// The SIGINT handler installed around sudo is gone again.
		assert.equal(process.listenerCount("SIGINT"), before);
	} finally {
		fakes.cleanup();
	}
});

test("runOnTerminal reports a sudo that cannot be spawned", async () => {
	const fakes = makeFakes();
	try {
		const { result } = await captureStdout(() =>
			runOnTerminal(description, prompt, command, { sudo: join(fakes.dir, "missing-sudo") }),
		);
		assert.equal(result.code, 1);
		assert.equal(result.stdout, "");
		assert.match(result.stderr, /ENOENT/);
	} finally {
		fakes.cleanup();
	}
});
