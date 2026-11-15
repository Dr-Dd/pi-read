/** Choose how sudo asks for the password: pi's terminal, a tmux popup, or a graphical askpass. */

import { trustedCommand, trustedFile } from "./trusted.ts";

export type PromptMethod = "tui" | "tmux" | "askpass";

/** Find a command by name; undefined when missing. The extension only finds trusted ones. */
export type Which = (name: string) => string | undefined;

/** Check an absolute path given by the user; the path to run, or undefined when it is not trusted. */
export type FileCheck = (path: string) => string | undefined;

export const ASKPASS_CANDIDATES = [
	"ksshaskpass",
	"ssh-askpass",
	"lxqt-openssh-askpass",
	"x11-ssh-askpass",
	"gnome-ssh-askpass",
];

/**
 * $SUDO_ASKPASS if file accepts it (by default: root-owned and not writable by group or others),
 * else the first known askpass which finds.
 */
export function findAskpass(
	env: NodeJS.ProcessEnv,
	which: Which = trustedCommand,
	file: FileCheck = trustedFile,
): string | undefined {
	const configured = env.SUDO_ASKPASS;
	if (configured?.startsWith("/")) {
		const found = file(configured);
		if (found) return found;
	}
	for (const name of ASKPASS_CANDIDATES) {
		const found = which(name);
		if (found) return found;
	}
	return undefined;
}

/** Prompt methods to try, in order. */
export function choosePromptMethods(
	env: NodeJS.ProcessEnv,
	mode: string,
	which: Which = trustedCommand,
	file: FileCheck = trustedFile,
): PromptMethod[] {
	const methods: PromptMethod[] = [];
	if (mode === "tui") methods.push("tui");
	if (env.TMUX && which("tmux")) methods.push("tmux");
	if ((env.DISPLAY || env.WAYLAND_DISPLAY) && findAskpass(env, which, file)) methods.push("askpass");
	return methods;
}
