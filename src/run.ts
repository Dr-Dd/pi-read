/** Run sudo pi-share with each password-prompt method. */

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export interface RunResult {
	code: number;
	stdout: string;
	stderr: string;
}

/** sudo arguments: always ask (-k), our prompt, -A for askpass, then the command. */
export function sudoArgs(prompt: string, command: string[], askpass = false): string[] {
	return ["-k", ...(askpass ? ["-A"] : []), "-p", prompt, "--", ...command];
}

function collect(
	file: string,
	args: string[],
	options: { env?: NodeJS.ProcessEnv; signal?: AbortSignal },
): Promise<RunResult> {
	return new Promise((resolve) => {
		const child = spawn(file, args, { stdio: ["ignore", "pipe", "pipe"], env: options.env, signal: options.signal });
		let stdout = "";
		let stderr = "";
		child.stdout.setEncoding("utf8").on("data", (d: string) => {
			stdout += d;
		});
		child.stderr.setEncoding("utf8").on("data", (d: string) => {
			stderr += d;
		});
		child.on("error", (err) => resolve({ code: 127, stdout, stderr: stderr + err.message }));
		child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
	});
}

/** Graphical askpass: sudo -A with SUDO_ASKPASS, no terminal. */
export function runAskpass(
	askpass: string,
	prompt: string,
	command: string[],
	options: { sudo?: string; env?: NodeJS.ProcessEnv; signal?: AbortSignal } = {},
): Promise<RunResult> {
	const env = { ...(options.env ?? process.env), SUDO_ASKPASS: askpass };
	return collect(options.sudo ?? "sudo", sudoArgs(prompt, command, true), { env, signal: options.signal });
}

/**
 * pi's own terminal. Call with pi's TUI stopped. stdin is the terminal (sudo asks on /dev/tty);
 * stdout and stderr are captured. SIGINT from Ctrl+C reaches pi too, so it is ignored meanwhile.
 * No abort signal: spawnSync blocks the event loop, so pi cannot react to one while sudo asks.
 * That costs nothing here: the user is at the prompt, and the command ends when they answer.
 */
export function runOnTerminal(
	description: string,
	prompt: string,
	command: string[],
	options: { sudo?: string } = {},
): RunResult {
	const ignore = () => {};
	process.on("SIGINT", ignore);
	try {
		process.stdout.write(`\n${description}\n\n`);
		// spawnSync, not spawn: the ctx.ui.custom callback around this call cannot await.
		const result = spawnSync(options.sudo ?? "sudo", sudoArgs(prompt, command), {
			stdio: ["inherit", "pipe", "pipe"],
			encoding: "utf8",
		});
		return {
			code: result.status ?? 1,
			stdout: result.stdout ?? "",
			stderr: (result.stderr ?? "") + (result.error ? result.error.message : ""),
		};
	} finally {
		process.off("SIGINT", ignore);
	}
}

function shQuote(s: string): string {
	return `'${s.replaceAll("'", `'\\''`)}'`;
}

/**
 * A tmux popup. Returns undefined when the popup did not run (no status file was written).
 * Results pass through a private temporary directory, removed afterwards.
 * The status file is written before sudo starts, so a popup closed with Ctrl+C counts as a refusal,
 * not as a missing popup. No abort signal: killing the tmux client would leave the popup asking
 * for a password whose result nobody reads, so an aborted call waits for the popup to close.
 */
export async function runTmuxPopup(
	description: string,
	prompt: string,
	command: string[],
	options: { sudo?: string; tmux?: string } = {},
): Promise<RunResult | undefined> {
	const dir = mkdtempSync(join(tmpdir(), "pi-read-")); // mode 0700
	try {
		const out = join(dir, "out");
		const err = join(dir, "err");
		const status = join(dir, "status");
		writeFileSync(join(dir, "description"), `${description}\n\n`, { mode: 0o600 });
		const sudoCmd = [options.sudo ?? "sudo", ...sudoArgs(prompt, command)].map(shQuote).join(" ");
		const script = [
			`echo 130 >${shQuote(status)}`,
			`trap 'exit 130' INT TERM HUP`,
			`cat ${shQuote(join(dir, "description"))}`,
			`${sudoCmd} >${shQuote(out)} 2>${shQuote(err)}`,
			`echo $? >${shQuote(status)}`,
			"",
		].join("\n");
		const scriptPath = join(dir, "run.sh");
		writeFileSync(scriptPath, script, { mode: 0o600 });
		await collect(options.tmux ?? "tmux", ["display-popup", "-E", "-T", "pi-read", `sh ${shQuote(scriptPath)}`], {});
		let code: number;
		try {
			code = Number.parseInt(readFileSync(status, "utf8").trim(), 10);
		} catch {
			return undefined;
		}
		const read = (p: string) => {
			try {
				return readFileSync(p, "utf8");
			} catch {
				return "";
			}
		};
		return { code: Number.isNaN(code) ? 1 : code, stdout: read(out), stderr: read(err) };
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}
