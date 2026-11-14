import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { BUNDLED_PI_SHARE, helperProblem } from "../src/helper.ts";
import piRead from "../src/index.ts";
import { makeFakes, pathWith, withEnv } from "./helpers.ts";

const repoPiShare = fileURLToPath(new URL("../bin/pi-share", import.meta.url));

test("the shipped pi-share is the repo's bin/pi-share", () => {
	assert.equal(BUNDLED_PI_SHARE, repoPiShare);
});

test("an installed pi-share identical to the shipped one is fine", () => {
	const fakes = makeFakes();
	try {
		const installed = fakes.write("pi-share", readFileSync(repoPiShare, "utf8"));
		assert.equal(helperProblem(installed), undefined);
	} finally {
		fakes.cleanup();
	}
});

test("an installed pi-share that differs asks for install.sh again", () => {
	const fakes = makeFakes();
	try {
		const installed = fakes.write("pi-share", `${readFileSync(repoPiShare, "utf8")}# older\n`);
		const problem = helperProblem(installed) ?? "";
		assert.match(problem, /differs from the pi-share this version of pi-read ships/);
		assert.match(problem, /install\.sh again$/);
		assert.ok(problem.startsWith(installed));
	} finally {
		fakes.cleanup();
	}
});

test("a missing pi-share asks for install.sh", () => {
	const fakes = makeFakes();
	try {
		const missing = join(fakes.dir, "pi-share");
		assert.match(
			helperProblem(missing) ?? "",
			/^pi-share is not installed at .*\/pi-share\. Ask the user to run .*install\.sh$/,
		);
	} finally {
		fakes.cleanup();
	}
});

test("without the shipped copy to compare against, an installed pi-share is accepted", () => {
	const fakes = makeFakes();
	try {
		const installed = fakes.write("pi-share", "#!/bin/bash\n");
		assert.equal(helperProblem(installed, join(fakes.dir, "no-such-file")), undefined);
	} finally {
		fakes.cleanup();
	}
});

test("execute reports a pi-share problem before sudo is run", async () => {
	const fakes = makeFakes();
	try {
		const marker = join(fakes.dir, "sudo-ran");
		fakes.write("sudo", `#!/bin/sh\necho ran > '${marker}'\nprintf "req\\tcopy\\n"\n`);
		const askpass = fakes.write("askpass", "#!/bin/sh\nexit 0\n");
		let registered: ToolDefinition | undefined;
		piRead(
			{
				registerTool: (tool: ToolDefinition) => {
					registered = tool;
				},
			} as unknown as ExtensionAPI,
			{ helperProblem: () => "pi-share is stale" },
		);
		const tool = registered as unknown as {
			execute(...args: unknown[]): Promise<{ isError?: boolean; content: { text: string }[]; details: object }>;
		};
		const ctx = { mode: "print" } as unknown as ExtensionToolContext;
		const result = await withEnv({ PATH: pathWith(fakes.dir), DISPLAY: ":0", SUDO_ASKPASS: askpass }, () =>
			tool.execute("id", { files: ["/etc/x"], reason: "because" }, undefined, undefined, ctx),
		);
		assert.equal(result.isError, true);
		assert.equal(result.content[0]?.text, "request_root_read: pi-share is stale");
		assert.deepEqual(result.details, {});
		assert.throws(() => readFileSync(marker), /ENOENT/);
	} finally {
		fakes.cleanup();
	}
});
