import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { PI_SHARE_PATH } from "../src/config.ts";

const run = promisify(execFile);

// install.sh installs pi-share somewhere; the extension has to call it there. Both read the path
// from a constant, so the two must agree.
test("install.sh installs pi-share at the path the extension calls", async () => {
	const install = fileURLToPath(new URL("../install.sh", import.meta.url));
	const { stdout } = await run("bash", ["-c", 'source "$1" && printf %s "$PI_SHARE_DEST"', "_", install]);
	assert.notEqual(stdout, "");
	assert.equal(stdout, PI_SHARE_PATH);
});
