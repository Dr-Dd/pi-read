import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";

// Load through pi's own extension loader, as a real pi session would.
const { loadExtensions } = await import(
	new URL("./core/extensions/loader.js", import.meta.resolve("@earendil-works/pi-coding-agent")).href
);

test("pi loads the extension without errors", async () => {
	const entry = fileURLToPath(new URL("../src/index.ts", import.meta.url));
	const result = await loadExtensions([entry], process.cwd());
	assert.deepEqual(result.errors, []);
	assert.equal(result.extensions.length, 1);
});
