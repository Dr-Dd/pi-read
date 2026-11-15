import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { runTmuxPopup } from "../src/run.ts";
import { makeFakes } from "./helpers.ts";

const command = ["/usr/local/bin/pi-share", "--duration", "15m", "--pid", "1", "--", "/etc/x"];

// A fake tmux that records its arguments and then runs the popup shell command (its last argument).
function tmuxRunning(log: string): string {
	return `#!/bin/sh\nprintf '%s\\n' "$@" > '${log}'\nfor last; do :; done\nexec sh -c "$last"\n`;
}

test("runTmuxPopup returns the status file's exit code, stdout and stderr", async () => {
	const fakes = makeFakes();
	try {
		const log = join(fakes.dir, "tmux.log");
		const sudo = fakes.write("sudo", '#!/bin/sh\nprintf "req\\tcopy\\n"\nprintf "warning\\n" >&2\nexit 3\n');
		const tmux = fakes.write("tmux", tmuxRunning(log));
		const result = await runTmuxPopup("the description", "Password: ", command, { sudo, tmux });
		// Exit code 3: the final `echo $? > status` replaced the 130 written before sudo started.
		assert.deepEqual(result, { code: 3, stdout: "req\tcopy\n", stderr: "warning\n" });
		const args = readFileSync(log, "utf8").trimEnd().split("\n");
		// No -T (popup title): it needs tmux 3.3, while popups exist since 3.2.
		assert.equal(args.length, 3);
		assert.deepEqual(args.slice(0, 2), ["display-popup", "-E"]);
		assert.match(args[2] ?? "", /^'\/[^']+' '.*\/run\.sh'$/);
	} finally {
		fakes.cleanup();
	}
});

test("runTmuxPopup turns Ctrl+C during the popup into refusal code 130", async () => {
	const fakes = makeFakes();
	try {
		// SIGINT to the script shell while it waits for sudo: the popup closes before the script reaches
		// its final `echo $? > status`, so only the 130 written before sudo started is left.
		const sudo = fakes.write("sudo", '#!/bin/sh\nkill -INT "$PPID"\nsleep 0.2\nexit 130\n');
		const tmux = fakes.write("tmux", '#!/bin/sh\nfor last; do :; done\nexec sh -c "$last"\n');
		const result = await runTmuxPopup("the description", "Password: ", command, { sudo, tmux });
		assert.deepEqual(result, { code: 130, stdout: "", stderr: "" });
	} finally {
		fakes.cleanup();
	}
});

test("runTmuxPopup returns undefined when the popup never ran", async () => {
	const fakes = makeFakes();
	try {
		const sudo = fakes.write("sudo", "#!/bin/sh\nexit 0\n");
		const tmux = fakes.write("tmux", "#!/bin/sh\nexit 0\n");
		assert.equal(await runTmuxPopup("the description", "Password: ", command, { sudo, tmux }), undefined);
	} finally {
		fakes.cleanup();
	}
});
