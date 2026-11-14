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

/**
 * Why the installed pi-share cannot be used, or undefined when it can. pi uses the extension from
 * its folder, but pi-share is a root-owned copy: after an update the copy is stale (an older
 * never-share list, older checks) until install.sh runs again. Checked before sudo asks, so the
 * user does not type a password for a request that cannot work.
 */
export function helperProblem(installed = PI_SHARE_PATH, bundled = BUNDLED_PI_SHARE): string | undefined {
	const installedBytes = readOrUndefined(installed);
	if (!installedBytes) {
		return `pi-share is not installed at ${installed}. Ask the user to run ${INSTALL_SCRIPT}`;
	}
	// Without the shipped copy there is nothing to compare against; pi-share still does its own checks.
	const bundledBytes = readOrUndefined(bundled);
	if (bundledBytes && !bundledBytes.equals(installedBytes)) {
		return `${installed} differs from the pi-share this version of pi-read ships (pi-read was updated since it was installed). Ask the user to run ${INSTALL_SCRIPT} again`;
	}
	return undefined;
}

/**
 * Why the never-share list cannot be used, or undefined when it can. Only its presence is checked:
 * root edits it in place, so it need not match the shipped defaults, and pi-share does the real
 * checks (root-owned, not writable by the user, well-formed). Checked before sudo asks.
 */
export function neverShareProblem(installed = NEVER_SHARE_LIST_PATH): string | undefined {
	if (existsSync(installed)) return undefined;
	return `the never-share list is not installed at ${installed}. Ask the user to run ${INSTALL_SCRIPT}`;
}
