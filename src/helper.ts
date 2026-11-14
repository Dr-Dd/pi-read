/** Check that the installed pi-share is the one this version of the extension ships. */

import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { NEVER_SHARE_LIST_PATH, PI_SHARE_PATH } from "./config.ts";

/** The pi-share shipped next to this extension; install.sh copies it to PI_SHARE_PATH. */
export const BUNDLED_PI_SHARE = fileURLToPath(new URL("../bin/pi-share", import.meta.url));
const INSTALL_SCRIPT = fileURLToPath(new URL("../install.sh", import.meta.url));

function readOrUndefined(path: string): Buffer | undefined {
	try {
		return readFileSync(path);
	} catch {
		return undefined;
	}
}

/** What is wrong with pi-read's system files, without the instruction; forAgent and forUser add it. */
export interface InstallProblem {
	/** What is wrong, e.g. "pi-share is not installed at /usr/local/bin/pi-share". */
	problem: string;
	/** install.sh ran before and has to run again (the installed pi-share is from another version). */
	again: boolean;
}

/**
 * Why the installed pi-share cannot be used, or undefined when it can. pi uses the extension from
 * its folder, but pi-share is a root-owned copy: after an update the copy is stale (an older
 * never-share list, older checks) until install.sh runs again. Checked before sudo asks, so the
 * user does not type a password for a request that cannot work, and at startup to warn the user.
 */
export function piShareInstallProblem(
	installed = PI_SHARE_PATH,
	bundled = BUNDLED_PI_SHARE,
): InstallProblem | undefined {
	const installedBytes = readOrUndefined(installed);
	if (!installedBytes) {
		return { problem: `pi-share is not installed at ${installed}`, again: false };
	}
	// Without the shipped copy there is nothing to compare against; pi-share still does its own checks.
	const bundledBytes = readOrUndefined(bundled);
	if (bundledBytes && !bundledBytes.equals(installedBytes)) {
		return {
			problem: `${installed} differs from the pi-share this version of pi-read ships (pi-read was updated since it was installed)`,
			again: true,
		};
	}
	return undefined;
}

/**
 * Why the never-share list cannot be used, or undefined when it can. Only its presence is checked:
 * root edits it in place, so it need not match the shipped defaults, and pi-share does the real
 * checks (root-owned, not writable by the user, well-formed).
 */
export function neverShareInstallProblem(installed = NEVER_SHARE_LIST_PATH): InstallProblem | undefined {
	if (existsSync(installed)) return undefined;
	return { problem: `the never-share list is not installed at ${installed}`, again: false };
}

/** The pi-share problem, else the never-share list problem, else undefined. */
export function installProblem(
	piShare = PI_SHARE_PATH,
	bundled = BUNDLED_PI_SHARE,
	list = NEVER_SHARE_LIST_PATH,
): InstallProblem | undefined {
	return piShareInstallProblem(piShare, bundled) ?? neverShareInstallProblem(list);
}

/** The problem worded for the agent, which has to ask the user. */
export function forAgent(p: InstallProblem): string {
	return `${p.problem}. Ask the user to run ${INSTALL_SCRIPT}${p.again ? " again" : ""}`;
}

/** The problem worded for the user, who runs install.sh. */
export function forUser(p: InstallProblem): string {
	return `pi-read: ${p.problem}. Run ${INSTALL_SCRIPT}${p.again ? " again" : ""}`;
}

/** piShareInstallProblem worded for the agent. */
export function helperProblem(installed = PI_SHARE_PATH, bundled = BUNDLED_PI_SHARE): string | undefined {
	const p = piShareInstallProblem(installed, bundled);
	return p && forAgent(p);
}

/** neverShareInstallProblem worded for the agent. */
export function neverShareProblem(installed = NEVER_SHARE_LIST_PATH): string | undefined {
	const p = neverShareInstallProblem(installed);
	return p && forAgent(p);
}
