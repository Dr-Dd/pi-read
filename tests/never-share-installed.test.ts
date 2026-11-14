import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";
import { neverShareProblem } from "../src/helper.ts";
import { makeFakes } from "./helpers.ts";

test("an installed list is fine, whatever its content", () => {
	const fakes = makeFakes();
	try {
		assert.equal(neverShareProblem(fakes.write("never-share.list", "/root\n/srv/edited-by-root\n")), undefined);
		assert.equal(neverShareProblem(fakes.write("other.list", "")), undefined);
	} finally {
		fakes.cleanup();
	}
});

test("a missing installed list asks for install.sh", () => {
	const fakes = makeFakes();
	try {
		const missing = join(fakes.dir, "never-share.list");
		assert.match(
			neverShareProblem(missing) ?? "",
			/^the never-share list is not installed at .*\/never-share\.list\. Ask the user to run .*install\.sh$/,
		);
		assert.ok((neverShareProblem(missing) ?? "").includes(missing));
	} finally {
		fakes.cleanup();
	}
});
