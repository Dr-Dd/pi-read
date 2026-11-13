import assert from "node:assert/strict";
import test from "node:test";
import { formatResult, parseShareOutput } from "../src/request.ts";

test("parseShareOutput returns the expiry pi-share reported and the rows in order", () => {
	const output = parseShareOutput("expires\t1700000000\n\n/a\t/run/pi-share/x/a\n/b\t/run/pi-share/x/b\n");
	assert.deepEqual(output.files, [
		{ requested: "/a", copy: "/run/pi-share/x/a" },
		{ requested: "/b", copy: "/run/pi-share/x/b" },
	]);
	assert.equal(output.expires?.toISOString(), "2023-11-14T22:13:20.000Z");
});

test("parseShareOutput accepts output from an older pi-share with no expiry line", () => {
	const output = parseShareOutput("/a\t/run/pi-share/x/a\n");
	assert.deepEqual(output.files, [{ requested: "/a", copy: "/run/pi-share/x/a" }]);
	assert.equal(output.expires, undefined);
});

test("parseShareOutput throws on a malformed or repeated expiry line", () => {
	for (const stdout of [
		"expires\tnot-a-time\n/a\t/run/pi-share/x/a\n",
		"expires\t0\n/a\t/run/pi-share/x/a\n",
		"expires\t1700000000\nexpires\t1700000000\n/a\t/run/pi-share/x/a\n",
	]) {
		assert.throws(() => parseShareOutput(stdout), /unexpected pi-share output/);
	}
});

test("parseShareOutput throws when no copy is reported", () => {
	assert.throws(() => parseShareOutput(""), /no copies/);
	assert.throws(() => parseShareOutput("expires\t1700000000\n"), /no copies/);
});

test("formatResult prints the deadline it is given", () => {
	const text = formatResult([{ requested: "/a", copy: "/run/pi-share/x/a" }], new Date("2026-01-02T03:04:05.000Z"));
	assert.match(text, /deleted at 2026-01-02T03:04:05\.000Z/);
	assert.match(text, /\/a -> \/run\/pi-share\/x\/a/);
});
