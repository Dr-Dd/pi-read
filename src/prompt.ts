/** Choose how sudo asks for the password: pi's terminal, a tmux popup, or a graphical askpass. */

import { accessSync, constants } from "node:fs";
import { delimiter, join } from "node:path";

export type PromptMethod = "tui" | "tmux" | "askpass";

/** Find an executable by name on PATH; undefined when missing. */
export type Which = (name: string) => string | undefined;

export const ASKPASS_CANDIDATES = [
	"ksshaskpass",
	"ssh-askpass",
	"lxqt-openssh-askpass",
	"x11-ssh-askpass",
	"gnome-ssh-askpass",
];

function isExecutable(path: string): boolean {
	try {
		accessSync(path, constants.X_OK);
		return true;
	} catch {
		return false;
	}
}

/** Look up an executable on env.PATH. */
export function pathWhich(env: NodeJS.ProcessEnv): Which {
	return (name) => {
		for (const dir of (env.PATH ?? "").split(delimiter)) {
			if (!dir) continue;
			const candidate = join(dir, name);
			if (isExecutable(candidate)) return candidate;
		}
		return undefined;
	};
}

/** $SUDO_ASKPASS if set and executable, else the first known askpass on PATH. */
export function findAskpass(env: NodeJS.ProcessEnv, which: Which): string | undefined {
	const configured = env.SUDO_ASKPASS;
	if (configured?.startsWith("/") && isExecutable(configured)) return configured;
	for (const name of ASKPASS_CANDIDATES) {
		const found = which(name);
		if (found) return found;
	}
	return undefined;
}

/** Prompt methods to try, in order. */
export function choosePromptMethods(env: NodeJS.ProcessEnv, mode: string, which: Which): PromptMethod[] {
	const methods: PromptMethod[] = [];
	if (mode === "tui") methods.push("tui");
	if (env.TMUX && which("tmux")) methods.push("tmux");
	if ((env.DISPLAY || env.WAYLAND_DISPLAY) && findAskpass(env, which)) methods.push("askpass");
	return methods;
}
