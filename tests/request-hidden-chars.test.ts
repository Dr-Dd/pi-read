import assert from "node:assert/strict";
import test from "node:test";
import { normalizeRequest, sudoPrompt } from "../src/request.ts";

// biome-ignore lint/suspicious/noControlCharactersInRegex: checking that control characters are gone is the point
const CONTROL = /[\x00-\x1f\x7f-\x9f]/u;
const INVISIBLE = /\p{Cf}/u;

/** The message normalizeRequest throws for this path. */
function pathError(file: string): string {
	try {
		normalizeRequest({ files: [file], reason: "r" });
	} catch (err) {
		return (err as Error).message;
	}
	assert.fail(`expected the path ${JSON.stringify(file)} to be rejected`);
}

test("a path with a bidi override is rejected as invisible", () => {
	const message = pathError("/etc/shadow\u202Egnp.exe");
	assert.match(message, /invisible character/);
});

test("every bidi override and isolate in a path is rejected", () => {
	const codes = [
		...Array.from({ length: 5 }, (_, i) => 0x202a + i),
		...Array.from({ length: 4 }, (_, i) => 0x2066 + i),
	];
	for (const code of codes) {
		const message = pathError(`/etc/a${String.fromCodePoint(code)}b`);
		assert.match(message, /invisible character/, `U+${code.toString(16)} should be rejected`);
	}
});

test("zero-width characters in a path are rejected", () => {
	for (const code of [0x200b, 0x200c, 0x200d, 0x2060, 0xfeff]) {
		const message = pathError(`/etc/pa${String.fromCodePoint(code)}sswd`);
		assert.match(message, /invisible character/, `U+${code.toString(16)} should be rejected`);
	}
});

test("the rejection message spells the invisible character out", () => {
	const message = pathError("/etc/shadow\u202Eb");
	assert.match(message, /\\u\{202e\}/);
	assert.doesNotMatch(message, INVISIBLE);
});

test("a relative path with an invisible character reports the invisible character", () => {
	const message = pathError("etc/\u202Ea");
	assert.match(message, /invisible character/);
	assert.doesNotMatch(message, /not an absolute path/);
	assert.doesNotMatch(message, INVISIBLE);
});

test("bidi and zero-width characters in the reason become spaces", () => {
	assert.equal(normalizeRequest({ files: ["/etc/a"], reason: "read\u202Eetc\u202Cnow" }).reason, "read etc now");
	assert.equal(normalizeRequest({ files: ["/etc/a"], reason: "pass\u200Bword" }).reason, "pass word");
});

test("a reason made only of invisible characters is still missing", () => {
	assert.throws(() => normalizeRequest({ files: ["/etc/a"], reason: "\u202E\u200B " }), /a reason is required/);
});

test("sudoPrompt from a hostile reason carries no invisible or control characters", () => {
	const req = normalizeRequest({ files: ["/etc/a"], reason: "read\u202E/etc/shadow\u202C\u0007please" });
	const prompt = sudoPrompt(req);
	assert.doesNotMatch(prompt, INVISIBLE);
	assert.doesNotMatch(prompt.replaceAll("\n", ""), CONTROL);
});

test("legitimate non-ASCII paths and reasons are unchanged", () => {
	const files = ["/etc/café/naïve"];
	const reason = "لماذا هذا الملف؟ קובץ";
	const req = normalizeRequest({ files, reason });
	assert.deepEqual(req.files, files);
	assert.equal(req.reason, reason);
});

test("a duration with an invisible character is quoted in the error", () => {
	assert.throws(
		() => normalizeRequest({ files: ["/etc/a"], duration: "\u202Eabc", reason: "r" }),
		(err: Error) => {
			assert.match(err.message, /invalid duration/);
			assert.match(err.message, /\\u\{202e\}/);
			assert.doesNotMatch(err.message, INVISIBLE);
			return true;
		},
	);
});

test("a control character in a path still reports a control character", () => {
	const message = pathError("/etc/a\x1bb");
	assert.match(message, /control character/);
	assert.doesNotMatch(message, /invisible character/);
	assert.match(message, /\\u001b/);
	assert.doesNotMatch(message, CONTROL);
});
