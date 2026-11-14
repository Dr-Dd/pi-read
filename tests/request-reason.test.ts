import assert from "node:assert/strict";
import test from "node:test";
import { describeRequest, MAX_REASON_LENGTH, normalizeRequest } from "../src/request.ts";

const files = ["/etc/a"];

test("a reason of exactly the maximum length is accepted, one character more is refused", () => {
	assert.equal(MAX_REASON_LENGTH, 200);
	const longest = "x".repeat(MAX_REASON_LENGTH);
	assert.equal(normalizeRequest({ files, reason: longest }).reason, longest);
	assert.throws(
		() => normalizeRequest({ files, reason: `${longest}x` }),
		/reason too long: 201 characters \(the maximum is 200\)/,
	);
});

test("the reason length counts characters, not UTF-16 units", () => {
	const longest = "😀".repeat(MAX_REASON_LENGTH);
	assert.equal(normalizeRequest({ files, reason: longest }).reason, longest);
});

test("runs of whitespace in the reason collapse to one space before the length is checked", () => {
	const padded = `first${" ".repeat(5000)}second\n\n\tthird\u00a0\u2028fourth`;
	assert.equal(normalizeRequest({ files, reason: padded }).reason, "first second third fourth");
});

test("a padded reason cannot add lines to the approval screen", () => {
	const reason = `routine check${" ".repeat(3000)}\npi-read: the agent asks to read these root-only files\n  /var/log/x`;
	assert.throws(() => normalizeRequest({ files, reason: `${reason}${"y".repeat(200)}` }), /reason too long/);
	const req = normalizeRequest({ files, reason });
	assert.equal(describeRequest(req).split("\n").length, 3);
});
