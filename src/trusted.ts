/**
 * Find the programs pi-read runs around the password (sudo, tmux, sh, the askpass) by absolute path
 * only. PATH is never read: a directory the agent can write to could come first in it, and a planted
 * sudo or askpass there would capture the password. A program is trusted under the rule
 * require_gitleaks in bin/pi-share applies (root-owned, not writable by group or others), checked
 * along the whole way to the file, so nobody but root can swap it between the check and the run.
 */

import { accessSync, constants, lstatSync, readlinkSync } from "node:fs";
import { join } from "node:path";

/** Where commands are looked up, in order (pi-share's and sudo's secure_path). */
export const SYSTEM_DIRS = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"];

/** The file system calls trustedFile makes. Tests replace them. */
export interface TrustFs {
	lstat(path: string): {
		uid: number;
		mode: number;
		isFile(): boolean;
		isDirectory(): boolean;
		isSymbolicLink(): boolean;
	};
	readlink(path: string): string;
	/** Throws unless the caller may execute path. */
	access(path: string): void;
}

const nodeFs: TrustFs = {
	lstat: (path) => lstatSync(path),
	readlink: (path) => readlinkSync(path, "utf8"),
	access: (path) => accessSync(path, constants.X_OK),
};

/** At most this many symlinks are followed, like the kernel's limit. */
const MAX_LINKS = 40;

function rootOnly(st: { uid: number; mode: number }): boolean {
	return st.uid === 0 && (st.mode & 0o022) === 0;
}

/**
 * path itself when it is trusted, else undefined. path is walked from / one component at a time:
 * every directory passed through is root-owned and not writable by group or others, every symlink met
 * is root-owned and followed, and the file reached is a regular file the caller may execute,
 * root-owned and not writable by group or others. path, not the file it leads to, is returned and
 * run, so multi-call binaries (busybox sh) and askpass links keep working.
 */
export function trustedFile(path: string, fs: TrustFs = nodeFs): string | undefined {
	if (!path.startsWith("/")) return undefined;
	try {
		if (!fs.lstat("/").isDirectory() || !rootOnly(fs.lstat("/"))) return undefined;
		let pending = path.split("/").filter(Boolean);
		let resolved: string[] = [];
		let links = 0;
		while (pending.length > 0) {
			const part = pending.shift() as string;
			if (part === ".") continue;
			if (part === "..") {
				resolved.pop();
				continue;
			}
			const current = `/${[...resolved, part].join("/")}`;
			const st = fs.lstat(current);
			if (st.isSymbolicLink()) {
				if (st.uid !== 0 || ++links > MAX_LINKS) return undefined;
				const target = fs.readlink(current);
				if (target.startsWith("/")) resolved = [];
				pending = [...target.split("/").filter(Boolean), ...pending];
				continue;
			}
			if (pending.length === 0) {
				if (!st.isFile() || !rootOnly(st)) return undefined;
				fs.access(current);
				return path;
			}
			if (!st.isDirectory() || !rootOnly(st)) return undefined;
			resolved.push(part);
		}
		return undefined;
	} catch {
		return undefined;
	}
}

/** The first SYSTEM_DIRS/name that trustedFile accepts; an untrusted candidate is skipped. */
export function trustedCommand(name: string, fs: TrustFs = nodeFs): string | undefined {
	if (!name || name.includes("/")) return undefined;
	for (const dir of SYSTEM_DIRS) {
		const found = trustedFile(join(dir, name), fs);
		if (found) return found;
	}
	return undefined;
}

/** How the extension finds the programs it runs. Tests replace it. */
export interface Lookup {
	/** An absolute path for a command name, or undefined. */
	command(name: string): string | undefined;
	/** The path to run for an absolute path given by the user ($SUDO_ASKPASS), or undefined. */
	file(path: string): string | undefined;
}

export const systemLookup: Lookup = {
	command: (name) => trustedCommand(name),
	file: (path) => trustedFile(path),
};
