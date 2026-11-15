import assert from "node:assert/strict";
import test from "node:test";
import { choosePromptMethods, findAskpass, type Which } from "../src/prompt.ts";
import { makeFakes } from "./helpers.ts";

const which =
	(...names: string[]): Which =>
	(name) =>
		names.includes(name) ? `/usr/bin/${name}` : undefined;

const asRoot = process.getuid?.() === 0;

test("findAskpass ignores a user-owned $SUDO_ASKPASS and falls back to a known askpass from which", {
	skip: asRoot && "runs as root",
}, () => {
	const fakes = makeFakes();
	try {
		const planted = fakes.write("askpass", "#!/bin/sh\necho captured\n");
		assert.equal(findAskpass({ SUDO_ASKPASS: planted }, which("ksshaskpass")), "/usr/bin/ksshaskpass");
	} finally {
		fakes.cleanup();
	}
});

test("findAskpass returns a trusted $SUDO_ASKPASS (/bin/sh stands in for it)", () => {
	assert.equal(findAskpass({ SUDO_ASKPASS: "/bin/sh" }, which("ksshaskpass")), "/bin/sh");
});

test("choosePromptMethods offers no askpass when $SUDO_ASKPASS is untrusted and no known askpass is found", {
	skip: asRoot && "runs as root",
}, () => {
	const fakes = makeFakes();
	try {
		const planted = fakes.write("askpass", "#!/bin/sh\n");
		assert.deepEqual(choosePromptMethods({ DISPLAY: ":0", SUDO_ASKPASS: planted }, "print", which()), []);
	} finally {
		fakes.cleanup();
	}
});
