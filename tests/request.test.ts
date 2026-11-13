import assert from "node:assert/strict";
import test from "node:test";
import { normalizeRequest, parseShareOutput, shareArgs, sudoPrompt } from "../src/request.ts";

test("normalizeRequest strips @, removes duplicates, defaults duration to 15m", () => {
	const req = normalizeRequest({ files: ["@/etc/a", "/etc/a", "/etc/b"], reason: " why " });
	assert.deepEqual(req, { files: ["/etc/a", "/etc/b"], duration: "15m", reason: "why" });
});

test("normalizeRequest rejects relative paths, empty lists, newlines and bad durations", () => {
	assert.throws(() => normalizeRequest({ files: ["etc/a"], reason: "r" }), /absolute/);
	assert.throws(() => normalizeRequest({ files: [], reason: "r" }), /no files/);
	assert.throws(() => normalizeRequest({ files: ["/etc/a\n/etc/b"], reason: "r" }), /control/);
	for (const duration of ["1d", "1.5h", "abc"]) {
		assert.throws(() => normalizeRequest({ files: ["/etc/a"], duration, reason: "r" }), /invalid duration/);
	}
});

test("sudoPrompt names files, duration and reason, escaping %", () => {
	const prompt = sudoPrompt({ files: ["/etc/x%y"], duration: "5m", reason: "100% needed" });
	assert.match(prompt, /\/etc\/x%%y/);
	assert.match(prompt, /5m/);
	assert.match(prompt, /100%% needed/);
	assert.doesNotMatch(prompt.replaceAll("%%", ""), /%/);
});

test("shareArgs builds --duration D --pid P -- files", () => {
	assert.deepEqual(shareArgs({ files: ["/a", "/b"], duration: "1h", reason: "r" }, 42), [
		"--duration",
		"1h",
		"--pid",
		"42",
		"--",
		"/a",
		"/b",
	]);
});

test("parseShareOutput parses tab-separated lines and skips blank lines", () => {
	assert.deepEqual(parseShareOutput("/a\t/run/pi-share/x/a\n\n/b\t/run/pi-share/x/b\n"), {
		files: [
			{ requested: "/a", copy: "/run/pi-share/x/a" },
			{ requested: "/b", copy: "/run/pi-share/x/b" },
		],
		expires: undefined,
	});
});

test("parseShareOutput throws on a malformed line", () => {
	assert.throws(() => parseShareOutput("no tab here\n"), /unexpected pi-share output/);
});
