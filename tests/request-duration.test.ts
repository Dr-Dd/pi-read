import assert from "node:assert/strict";
import test from "node:test";
import { normalizeRequest } from "../src/request.ts";

const rangeError = /between 1s and 1h/;
const formatError = /invalid duration/;

test("normalizeRequest accepts durations at the 1s and 1h bounds", () => {
	for (const duration of ["1", "1s", "3600", "3600s", "60m", "1h"]) {
		assert.deepEqual(normalizeRequest({ files: ["/etc/a"], duration, reason: "r" }), {
			files: ["/etc/a"],
			duration,
			reason: "r",
		});
	}
});

test("normalizeRequest rejects durations below 1s with the range error", () => {
	for (const duration of ["0", "0s", "0m", "0h"]) {
		assert.throws(() => normalizeRequest({ files: ["/etc/a"], duration, reason: "r" }), rangeError, duration);
	}
});

test("normalizeRequest rejects durations above 1h with the range error", () => {
	for (const duration of ["2h", "61m", "3601", "3601s", "999999"]) {
		assert.throws(() => normalizeRequest({ files: ["/etc/a"], duration, reason: "r" }), rangeError, duration);
	}
});

test("normalizeRequest keeps malformed durations on the format error", () => {
	for (const duration of ["1d", "abc", "1000000"]) {
		assert.throws(
			() => normalizeRequest({ files: ["/etc/a"], duration, reason: "r" }),
			(err: Error) => formatError.test(err.message) && !rangeError.test(err.message),
			duration,
		);
	}
});
