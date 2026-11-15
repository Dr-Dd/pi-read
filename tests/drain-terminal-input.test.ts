import assert from "node:assert/strict";
import test from "node:test";
import { drainTerminalInput, type TerminalInput } from "../src/run.ts";

/** A fake terminal input that logs every call and lets the test emit data. */
function fakeInput(tty = true) {
	const log: string[] = [];
	const listeners = new Set<(chunk: unknown) => void>();
	const input: TerminalInput & { emit(chunk: string): void } = {
		isTTY: tty,
		isRaw: false,
		setRawMode(mode: boolean) {
			log.push(`raw:${mode}`);
			this.isRaw = mode;
		},
		on(_event, listener) {
			log.push("on");
			listeners.add(listener);
		},
		off(_event, listener) {
			log.push("off");
			listeners.delete(listener);
		},
		resume: () => log.push("resume"),
		pause: () => log.push("pause"),
		emit(chunk) {
			for (const l of listeners) l(chunk);
		},
	};
	return { input, log, listeners };
}

test("the drain switches to raw mode, discards input until idleMs pass, then cleans up", async () => {
	const { input, log, listeners } = fakeInput();
	const start = Date.now();
	const timers = [10, 40, 70].map((ms) => setTimeout(() => input.emit("\x1b[<65;40;12M"), ms));
	await drainTerminalInput(input, { idleMs: 60, maxMs: 2000 });
	const elapsed = Date.now() - start;
	for (const t of timers) clearTimeout(t);
	// The last byte came at about 70 ms, so the drain waited at least 70 + 60 ms.
	assert.ok(elapsed >= 125, `returned after ${elapsed} ms`);
	assert.ok(elapsed < 1000, `returned after ${elapsed} ms`);
	assert.deepEqual(log, ["raw:true", "on", "resume", "off", "pause", "raw:false"]);
	assert.equal(listeners.size, 0);
	assert.equal(input.isRaw, false);
});

test("the drain returns after maxMs even while input keeps arriving", async () => {
	const { input, log, listeners } = fakeInput();
	input.isRaw = true;
	const timer = setInterval(() => input.emit("x"), 5);
	const start = Date.now();
	try {
		await drainTerminalInput(input, { idleMs: 50, maxMs: 150 });
	} finally {
		clearInterval(timer);
	}
	const elapsed = Date.now() - start;
	assert.ok(elapsed >= 145 && elapsed < 600, `returned after ${elapsed} ms`);
	assert.deepEqual(log, ["raw:true", "on", "resume", "off", "pause", "raw:true"]);
	assert.equal(listeners.size, 0);
});

test("the drain with no input still waits idleMs", async () => {
	const { input, log } = fakeInput();
	const start = Date.now();
	await drainTerminalInput(input, { idleMs: 50, maxMs: 1000 });
	const elapsed = Date.now() - start;
	assert.ok(elapsed >= 45 && elapsed < 500, `returned after ${elapsed} ms`);
	assert.deepEqual(log, ["raw:true", "on", "resume", "off", "pause", "raw:false"]);
});

test("a non-TTY input, or one without setRawMode, is left alone", async () => {
	const { input, log } = fakeInput(false);
	const start = Date.now();
	await drainTerminalInput(input, { idleMs: 200, maxMs: 1000 });
	assert.deepEqual(log, []);

	const noRaw = fakeInput(true);
	noRaw.input.setRawMode = undefined;
	await drainTerminalInput(noRaw.input, { idleMs: 200, maxMs: 1000 });
	assert.deepEqual(noRaw.log, []);
	assert.ok(Date.now() - start < 150);
});
