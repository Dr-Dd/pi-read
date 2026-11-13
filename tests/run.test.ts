import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { runAskpass } from "../src/run.ts";

// A fake sudo that echoes its askpass and arguments, then exits with $FAKE_SUDO_EXIT.
function fakeSudo(): { path: string; cleanup: () => void } {
	const dir = mkdtempSync(join(tmpdir(), "pi-read-test-"));
	const path = join(dir, "sudo");
	writeFileSync(
		path,
		'#!/bin/sh\necho "askpass=$SUDO_ASKPASS"\nfor a in "$@"; do echo "arg=$a"; done\necho "oops" >&2\nexit "$FAKE_SUDO_EXIT"\n',
	);
	chmodSync(path, 0o755);
	return { path, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test("runAskpass runs sudo -A with SUDO_ASKPASS and the arguments", async () => {
	const sudo = fakeSudo();
	try {
		const result = await runAskpass("/usr/bin/ksshaskpass", "Prompt: ", ["/bin/pi-share", "--", "/etc/x"], {
			sudo: sudo.path,
			env: { ...process.env, FAKE_SUDO_EXIT: "0" },
		});
		assert.equal(result.code, 0);
		assert.equal(
			result.stdout,
			[
				"askpass=/usr/bin/ksshaskpass",
				"arg=-k",
				"arg=-A",
				"arg=-p",
				"arg=Prompt: ",
				"arg=--",
				"arg=/bin/pi-share",
				"arg=--",
				"arg=/etc/x",
				"",
			].join("\n"),
		);
	} finally {
		sudo.cleanup();
	}
});

test("runAskpass returns the nonzero code and stderr on failure", async () => {
	const sudo = fakeSudo();
	try {
		const result = await runAskpass("/x", "P", ["/bin/pi-share"], {
			sudo: sudo.path,
			env: { ...process.env, FAKE_SUDO_EXIT: "1" },
		});
		assert.equal(result.code, 1);
		assert.equal(result.stderr, "oops\n");
	} finally {
		sudo.cleanup();
	}
});
