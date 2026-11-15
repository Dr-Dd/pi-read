import assert from "node:assert/strict";
import { symlinkSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { SYSTEM_DIRS, type TrustFs, trustedCommand, trustedFile } from "../src/trusted.ts";
import { makeFakes, pathWith, withEnv } from "./helpers.ts";

type Node =
	| { kind: "dir"; uid?: number; mode?: number }
	| { kind: "file"; uid?: number; mode?: number; exec?: boolean }
	| { kind: "link"; uid?: number; target: string };

/** A fake file system: every path not listed is missing; uid defaults to root, mode to 0755. */
function fakeFs(nodes: Record<string, Node>): TrustFs {
	const all: Record<string, Node> = { "/": { kind: "dir" }, ...nodes };
	const get = (path: string) => {
		const node = all[path];
		if (!node) throw new Error(`ENOENT ${path}`);
		return node;
	};
	return {
		lstat(path) {
			const node = get(path);
			return {
				uid: node.uid ?? 0,
				mode: node.kind === "link" ? 0o777 : (node.mode ?? 0o755),
				isFile: () => node.kind === "file",
				isDirectory: () => node.kind === "dir",
				isSymbolicLink: () => node.kind === "link",
			};
		},
		readlink(path) {
			const node = get(path);
			if (node.kind !== "link") throw new Error("EINVAL");
			return node.target;
		},
		access(path) {
			const node = get(path);
			if (node.kind !== "file" || node.exec === false) throw new Error("EACCES");
		},
	};
}

const asRoot = process.getuid?.() === 0;

test("trustedFile accepts /bin/sh and returns it unchanged", () => {
	assert.equal(trustedFile("/bin/sh"), "/bin/sh");
});

test("trustedFile refuses a relative path, a missing path, a directory and a non-executable root file (/etc/passwd)", () => {
	assert.equal(trustedFile("bin/sh"), undefined);
	assert.equal(trustedFile("/no/such/file/pi-read"), undefined);
	assert.equal(trustedFile("/usr/bin"), undefined);
	if (!asRoot) assert.equal(trustedFile("/etc/passwd"), undefined);
});

test("trustedFile refuses a user-owned executable, and a link to /bin/sh placed in a user-owned temporary directory", {
	skip: asRoot && "runs as root",
}, () => {
	const fakes = makeFakes();
	try {
		assert.equal(trustedFile(fakes.write("sudo", "#!/bin/sh\n")), undefined);
		const link = join(fakes.dir, "sh");
		symlinkSync("/bin/sh", link);
		assert.equal(trustedFile(link), undefined);
	} finally {
		fakes.cleanup();
	}
});

test("trustedFile (fake fs) refuses a root file writable by group, one writable by others, and one not owned by root", () => {
	const fs = fakeFs({
		"/bin": { kind: "dir" },
		"/bin/g": { kind: "file", mode: 0o775 },
		"/bin/o": { kind: "file", mode: 0o757 },
		"/bin/u": { kind: "file", uid: 1000 },
		"/bin/ok": { kind: "file" },
	});
	assert.equal(trustedFile("/bin/ok", fs), "/bin/ok");
	assert.equal(trustedFile("/bin/g", fs), undefined);
	assert.equal(trustedFile("/bin/o", fs), undefined);
	assert.equal(trustedFile("/bin/u", fs), undefined);
});

test("trustedFile (fake fs) refuses a root file whose directory, or a directory further up, is writable by group/others or not owned by root", () => {
	const fs = fakeFs({
		"/a": { kind: "dir", mode: 0o777 },
		"/a/x": { kind: "file" },
		"/b": { kind: "dir" },
		"/b/c": { kind: "dir", uid: 1000 },
		"/b/c/x": { kind: "file" },
		"/d": { kind: "dir", mode: 0o775 },
		"/d/e": { kind: "dir" },
		"/d/e/x": { kind: "file" },
	});
	assert.equal(trustedFile("/a/x", fs), undefined);
	assert.equal(trustedFile("/b/c/x", fs), undefined);
	assert.equal(trustedFile("/d/e/x", fs), undefined);
});

test("trustedFile (fake fs) follows a root-owned link chain (absolute and relative targets, with ..) to a trusted file and returns the original path", () => {
	const fs = fakeFs({
		"/bin": { kind: "link", target: "usr/bin" },
		"/usr": { kind: "dir" },
		"/usr/bin": { kind: "dir" },
		"/usr/lib": { kind: "dir" },
		"/usr/bin/ssh-askpass": { kind: "link", target: "../lib/askpass" },
		"/usr/lib/askpass": { kind: "link", target: "/usr/lib/real" },
		"/usr/lib/real": { kind: "file" },
	});
	assert.equal(trustedFile("/bin/ssh-askpass", fs), "/bin/ssh-askpass");
});

test("trustedFile (fake fs) refuses a link not owned by root, a link loop, and a chain whose target directory is writable by group", () => {
	const fs = fakeFs({
		"/bin": { kind: "dir" },
		"/bin/user": { kind: "link", uid: 1000, target: "/bin/real" },
		"/bin/real": { kind: "file" },
		"/bin/loop1": { kind: "link", target: "loop2" },
		"/bin/loop2": { kind: "link", target: "loop1" },
		"/bin/away": { kind: "link", target: "/open/real" },
		"/open": { kind: "dir", mode: 0o775 },
		"/open/real": { kind: "file" },
	});
	assert.equal(trustedFile("/bin/real", fs), "/bin/real");
	assert.equal(trustedFile("/bin/user", fs), undefined);
	assert.equal(trustedFile("/bin/loop1", fs), undefined);
	assert.equal(trustedFile("/bin/away", fs), undefined);
});

test("trustedCommand (fake fs) looks only in SYSTEM_DIRS, in order, and skips an untrusted candidate for a trusted one further on", () => {
	const nodes: Record<string, Node> = { "/usr": { kind: "dir" }, "/home": { kind: "dir" } };
	for (const dir of SYSTEM_DIRS) nodes[dir] = { kind: "dir" };
	nodes["/home/u"] = { kind: "dir", uid: 1000 };
	nodes["/home/u/tool"] = { kind: "file", uid: 1000 };
	nodes["/usr/local/bin/tool"] = { kind: "file", uid: 1000 };
	nodes["/usr/bin/tool"] = { kind: "file" };
	nodes["/bin/tool"] = { kind: "file" };
	nodes["/home/u/only-home"] = { kind: "file" };
	const fs = fakeFs(nodes);
	assert.equal(trustedCommand("tool", fs), "/usr/bin/tool");
	assert.equal(trustedCommand("only-home", fs), undefined);
	assert.deepEqual(SYSTEM_DIRS, ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"]);
});

test("trustedCommand refuses a name with a slash", () => {
	assert.equal(trustedCommand("bin/sh"), undefined);
	assert.equal(trustedCommand("/bin/sh"), undefined);
	assert.equal(trustedCommand(""), undefined);
});

test('trustedCommand("sh") with a fake sh first on PATH returns a system path, not the fake', async () => {
	const fakes = makeFakes();
	try {
		fakes.write("sh", "#!/bin/sh\n");
		const found = await withEnv({ PATH: pathWith(fakes.dir) }, () => trustedCommand("sh"));
		assert.ok(found, "no trusted sh found");
		assert.ok(
			SYSTEM_DIRS.some((dir) => found === `${dir}/sh`),
			found,
		);
	} finally {
		fakes.cleanup();
	}
});
