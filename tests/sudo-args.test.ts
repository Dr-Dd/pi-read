import assert from "node:assert/strict";
import test from "node:test";
import { sudoArgs } from "../src/run.ts";

test("sudoArgs drops -k only for pi's terminal; the tmux popup and askpass keep it", () => {
	const command = ["/usr/local/bin/pi-share", "--", "/etc/x"];
	// pi's terminal (runOnTerminal passes remember): sudo may use the password it remembers.
	assert.deepEqual(sudoArgs("P: ", command, { remember: true }), ["-p", "P: ", "--", ...command]);
	// The tmux popup (no options) and askpass always ask.
	assert.deepEqual(sudoArgs("P: ", command), ["-k", "-p", "P: ", "--", ...command]);
	assert.deepEqual(sudoArgs("P: ", command, { askpass: true }), ["-k", "-A", "-p", "P: ", "--", ...command]);
});
