import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const SOURCE = "git:github.com/Dr-Dd/pi-read";

const readme = readFileSync(fileURLToPath(new URL("../README.md", import.meta.url)), "utf8");
const version = (
	JSON.parse(readFileSync(fileURLToPath(new URL("../package.json", import.meta.url)), "utf8")) as {
		version: string;
	}
).version;

// An unpinned git package follows the default branch on `pi update`, moving the code that drives
// the sudo prompts without the user choosing to. The README must only ever install a pinned tag.
test("every pi install of pi-read in README.md is pinned to the package.json version's tag", () => {
	const installs = [...readme.matchAll(/pi install (\S+)/g)]
		.map((m) => m[1] ?? "")
		.filter((source) => source.startsWith(SOURCE));
	assert.ok(installs.length > 0, "README.md never installs pi-read from git");
	for (const source of installs) {
		assert.equal(source, `${SOURCE}@v${version}`);
	}
});

test("install.sh's PI_SOURCE has no ref and is the source README.md installs", async () => {
	const install = fileURLToPath(new URL("../install.sh", import.meta.url));
	const { stdout } = await run("bash", ["-c", 'source "$1" && printf %s "$PI_SOURCE"', "_", install]);
	assert.equal(stdout, SOURCE);
	assert.ok(!stdout.includes("@"));
	assert.ok(readme.includes(`pi install ${stdout}@v${version}`));
});
