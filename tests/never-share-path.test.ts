import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { NEVER_SHARE_LIST_PATH } from "../src/config.ts";

const run = promisify(execFile);

// install.sh installs the never-share list, pi-share reads it and the extension checks that it is
// there: all three must name the same path.
test("install.sh, pi-share and the extension agree on the installed list path", async () => {
	const install = fileURLToPath(new URL("../install.sh", import.meta.url));
	const piShare = fileURLToPath(new URL("../bin/pi-share", import.meta.url));
	const read = async (script: string, variable: string) =>
		(await run("bash", ["-c", `source "$1" && printf %s "$${variable}"`, "_", script])).stdout;
	const installed = await read(install, "NEVER_SHARE_DEST");
	const readByPiShare = await read(piShare, "NEVER_SHARE_LIST");
	assert.notEqual(installed, "");
	assert.equal(installed, NEVER_SHARE_LIST_PATH);
	assert.equal(readByPiShare, NEVER_SHARE_LIST_PATH);
});
