/** Helpers for the runtime-path tests: fake commands in a private directory, env swaps, stdout capture. */

import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export interface Fakes {
	/** The temporary directory the fake commands live in. */
	dir: string;
	/** Write an executable fake command and return its absolute path. */
	write(name: string, script: string): string;
	/** Remove the temporary directory. */
	cleanup(): void;
}

/** Create a temporary directory (mode 0700) to write fake commands into. */
export function makeFakes(): Fakes {
	const dir = mkdtempSync(join(tmpdir(), "pi-read-test-"));
	return {
		dir,
		write(name, script) {
			const path = join(dir, name);
			writeFileSync(path, script);
			chmodSync(path, 0o755);
			return path;
		},
		cleanup: () => rmSync(dir, { recursive: true, force: true }),
	};
}

/** PATH with dir first, so the fake commands win over the real ones. */
export function pathWith(dir: string): string {
	return `${dir}:${process.env.PATH ?? ""}`;
}

/** Set env values for one test, restoring the previous values (including unset ones) afterwards. */
export async function withEnv<T>(values: NodeJS.ProcessEnv, fn: () => Promise<T> | T): Promise<T> {
	const saved = new Map<string, string | undefined>();
	for (const [key, value] of Object.entries(values)) {
		saved.set(key, process.env[key]);
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
	try {
		return await fn();
	} finally {
		for (const [key, value] of saved) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	}
}

/** Run fn while capturing everything written to process.stdout (which keeps the TAP output clean). */
export async function captureStdout<T>(fn: () => Promise<T> | T): Promise<{ result: T; written: string }> {
	const chunks: string[] = [];
	const original = process.stdout.write;
	process.stdout.write = ((chunk: string | Uint8Array) => {
		chunks.push(String(chunk));
		return true;
	}) as unknown as typeof process.stdout.write;
	try {
		const result = await fn();
		return { result, written: chunks.join("") };
	} finally {
		process.stdout.write = original;
	}
}
