import assert from "node:assert/strict";
import test from "node:test";
import {
	describeListRequest,
	formatListResult,
	listArgs,
	listPrompt,
	normalizeListRequest,
	PASSWORD_QUESTION,
} from "../src/request.ts";

test("normalizeListRequest defaults depth to 1 and duration to 15m, strips @ and removes duplicates", () => {
	const req = normalizeListRequest({ directories: ["@/etc/a", "/etc/a", "/var/b"], reason: " why " });
	assert.deepEqual(req, { directories: ["/etc/a", "/var/b"], depth: 1, duration: "15m", reason: "why" });
});

test("normalizeListRequest rejects depth 0, 11, 1.5 and non-numbers", () => {
	for (const depth of [0, 11, 1.5, Number.NaN, "2" as unknown as number]) {
		assert.throws(() => normalizeListRequest({ directories: ["/etc"], depth, reason: "r" }), /invalid depth/);
	}
});

test("normalizeListRequest rejects relative, control-char and invisible-char paths, and an empty list", () => {
	assert.throws(() => normalizeListRequest({ directories: ["etc"], reason: "r" }), /absolute/);
	assert.throws(() => normalizeListRequest({ directories: ["/etc\n/var"], reason: "r" }), /control/);
	assert.throws(() => normalizeListRequest({ directories: ["/etc\u202e"], reason: "r" }), /invisible/);
	assert.throws(() => normalizeListRequest({ directories: [], reason: "r" }), /no directories/);
});

test("describeListRequest names the dirs, the depth, the duration and the reason", () => {
	const one = describeListRequest({ directories: ["/etc/a", "/var/b"], depth: 1, duration: "5m", reason: "why" });
	assert.equal(
		one,
		"pi-read: the agent asks to list these root-only directories, one level\n  /etc/a\n  /var/b\nfor 5m. Reason: why",
	);
	const three = describeListRequest({ directories: ["/etc/a"], depth: 3, duration: "5m", reason: "why" });
	assert.match(three, /3 levels deep/);
});

test("listPrompt escapes % and ends with the password question", () => {
	const prompt = listPrompt({ directories: ["/etc/x%y"], depth: 1, duration: "5m", reason: "100% needed" });
	assert.match(prompt, /\/etc\/x%%y/);
	assert.match(prompt, /100%% needed/);
	assert.doesNotMatch(prompt.replaceAll("%%", ""), /%/);
	assert.ok(prompt.endsWith(`\n${PASSWORD_QUESTION}`));
});

test("listArgs builds --duration D --pid P --list --depth N -- dirs", () => {
	assert.deepEqual(listArgs({ directories: ["/a", "/b"], depth: 3, duration: "1h", reason: "r" }, 42), [
		"--duration",
		"1h",
		"--pid",
		"42",
		"--list",
		"--depth",
		"3",
		"--",
		"/a",
		"/b",
	]);
});

test("formatListResult names each directory, its listing and the deadline", () => {
	const text = formatListResult(
		[
			{ requested: "/etc", copy: "/run/pi-share/x/listing-0" },
			{ requested: "/var", copy: "/run/pi-share/x/listing-1" },
		],
		new Date(1_700_000_000_000),
	);
	assert.match(text, /2023-11-14T22:13:20\.000Z/);
	assert.match(text, /\n {2}\/etc -> \/run\/pi-share\/x\/listing-0\n {2}\/var -> \/run\/pi-share\/x\/listing-1\n/);
});
