import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { choosePromptMethods, findAskpass, type Which } from "../src/prompt.ts";

const which =
	(...names: string[]): Which =>
	(name) =>
		names.includes(name) ? `/usr/bin/${name}` : undefined;

function fakeExecutable(): { path: string; cleanup: () => void } {
	const dir = mkdtempSync(join(tmpdir(), "pi-read-test-"));
	const path = join(dir, "my-askpass");
	writeFileSync(path, "#!/bin/sh\n");
	chmodSync(path, 0o755);
	return { path, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test("tui mode picks tui first, then tmux and askpass as available", () => {
	const env = { TMUX: "/tmp/tmux-1/default,1,0", DISPLAY: ":0" };
	assert.deepEqual(choosePromptMethods(env, "tui", which("tmux", "ksshaskpass")), ["tui", "tmux", "askpass"]);
	assert.deepEqual(choosePromptMethods({}, "tui", which("tmux", "ksshaskpass")), ["tui"]);
});

test("outside tui, inside tmux with tmux on PATH: tmux before askpass", () => {
	const env = { TMUX: "/tmp/tmux-1/default,1,0", WAYLAND_DISPLAY: "wayland-0" };
	assert.deepEqual(choosePromptMethods(env, "rpc", which("tmux", "ksshaskpass")), ["tmux", "askpass"]);
	assert.deepEqual(choosePromptMethods(env, "rpc", which("ksshaskpass")), ["askpass"]);
});

test("without TMUX, with a display and SUDO_ASKPASS: askpass uses SUDO_ASKPASS", () => {
	const fake = fakeExecutable();
	try {
		const env = { DISPLAY: ":0", SUDO_ASKPASS: fake.path };
		assert.deepEqual(
			choosePromptMethods(env, "print", which(), (p) => p),
			["askpass"],
		);
		assert.equal(
			findAskpass(env, which("ksshaskpass"), (p) => p),
			fake.path,
		);
	} finally {
		fake.cleanup();
	}
});

test("without SUDO_ASKPASS, findAskpass finds ksshaskpass on PATH", () => {
	assert.equal(findAskpass({}, which("ksshaskpass")), "/usr/bin/ksshaskpass");
});

test("no display: no askpass; nothing available: empty list", () => {
	assert.deepEqual(choosePromptMethods({}, "print", which("ksshaskpass")), []);
	assert.deepEqual(choosePromptMethods({ DISPLAY: ":0" }, "json", which()), []);
});
