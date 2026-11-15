import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { runTmuxPopup } from "../src/run.ts";
import { SYSTEM_DIRS } from "../src/trusted.ts";
import { makeFakes, pathWith, withEnv } from "./helpers.ts";

const command = ["/usr/local/bin/pi-share", "--duration", "15m", "--pid", "1", "--", "/etc/x"];

test("runTmuxPopup without options.sh runs the popup with the absolute system sh even with a fake sh first on PATH, and the popup script calls no cat", async () => {
	const fakes = makeFakes();
	try {
		const log = join(fakes.dir, "tmux.log");
		const script = join(fakes.dir, "script");
		const fakeShRan = join(fakes.dir, "fake-sh-ran");
		const fakeCatRan = join(fakes.dir, "fake-cat-ran");
		fakes.write("sh", `#!/bin/bash\necho ran > '${fakeShRan}'\n`);
		fakes.write("cat", `#!/bin/bash\necho ran > '${fakeCatRan}'\n`);
		const sudo = fakes.write("sudo", '#!/bin/bash\nprintf "req\\tcopy\\n"\n');
		// The fake tmux records the popup command, saves the script, and runs the command with eval.
		const tmux = fakes.write(
			"tmux",
			`#!/bin/bash\nfor last; do :; done\nprintf '%s' "$last" > '${log}'\neval "set -- $last"\n/bin/cp "$2" '${script}'\neval "$last"\n`,
		);
		const result = await withEnv({ PATH: pathWith(fakes.dir) }, () =>
			runTmuxPopup("the description", "Password: ", command, { sudo, tmux }),
		);
		assert.deepEqual(result, { code: 0, stdout: "req\tcopy\n", stderr: "" });
		const popup = readFileSync(log, "utf8");
		const sh = /^'([^']+)' /.exec(popup)?.[1] ?? "";
		assert.ok(
			SYSTEM_DIRS.some((dir) => sh === `${dir}/sh`),
			popup,
		);
		assert.doesNotMatch(readFileSync(script, "utf8"), /\bcat\b/);
		assert.throws(() => readFileSync(fakeShRan));
		assert.throws(() => readFileSync(fakeCatRan));
	} finally {
		fakes.cleanup();
	}
});
