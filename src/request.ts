/** Pure helpers for request_root_read: input validation, sudo arguments, pi-share output. */

export const DEFAULT_DURATION = "15m";
const DURATION_RE = /^([0-9]{1,6})([smh]?)$/;
// The same bounds pi-share enforces (MAX_DURATION=3600); checking here avoids a password prompt
// for a request pi-share would refuse.
const MIN_DURATION_SECONDS = 1;
const MAX_DURATION_SECONDS = 3600;
/** Longest reason, in characters. A longer one could scroll the file list off the approval screen. */
export const MAX_REASON_LENGTH = 200;
// Epoch seconds: 1-12 digits, so the Date below stays in range.
const EXPIRY_RE = /^[1-9][0-9]{0,11}$/;

// biome-ignore lint/suspicious/noControlCharactersInRegex: rejecting control characters is the point
const CONTROL_CHAR = /[\x00-\x1f\x7f-\x9f]/u;
/** Unicode format characters (Cf): bidi overrides and isolates, directional marks, zero-width marks and
 * joiners, BOM, soft hyphen. They are invisible but change how the text around them is displayed. */
const INVISIBLE_CHAR = /\p{Cf}/u;
// biome-ignore lint/suspicious/noControlCharactersInRegex: stripping control and invisible characters is the point
const UNSAFE_RUN = /[\x00-\x1f\x7f-\x9f\p{Cf}]+/gu;

/** JSON-quoted text with unsafe characters spelled out, so a message cannot itself hide anything.
 * JSON escaping already covers C0; the rest (Cf, DEL, C1) becomes a \u{...} escape. */
function quote(s: string): string {
	return JSON.stringify(s).replace(UNSAFE_RUN, (run) =>
		[...run].map((c) => `\\u{${(c.codePointAt(0) ?? 0).toString(16)}}`).join(""),
	);
}

export interface ShareRequest {
	files: string[];
	duration: string;
	reason: string;
}

export interface SharedFile {
	requested: string;
	copy: string;
}

export interface ShareOutput {
	files: SharedFile[];
	/** When the copies are deleted. Missing when the installed pi-share is older than this extension. */
	expires?: Date;
}

/** Validate and normalize the tool input. Throws an Error with a message for the model. */
export function normalizeRequest(input: { files: string[]; duration?: string; reason: string }): ShareRequest {
	const files: string[] = [];
	for (const raw of input.files) {
		const file = raw.startsWith("@") ? raw.slice(1) : raw;
		if (CONTROL_CHAR.test(file)) throw new Error(`invalid path (control character): ${quote(file)}`);
		// Invisible characters would let the approval screen show a different path than pi-share copies.
		if (INVISIBLE_CHAR.test(file)) throw new Error(`invalid path (invisible character): ${quote(file)}`);
		if (!file.startsWith("/")) throw new Error(`not an absolute path: ${file}`);
		if (!files.includes(file)) files.push(file);
	}
	if (files.length === 0) throw new Error("no files requested");
	const duration = input.duration?.trim() || DEFAULT_DURATION;
	if (!DURATION_RE.test(duration)) {
		throw new Error(`invalid duration: ${quote(duration)} (use e.g. 90, 90s, 15m or 1h)`);
	}
	const seconds = durationSeconds(duration);
	if (seconds < MIN_DURATION_SECONDS || seconds > MAX_DURATION_SECONDS) {
		throw new Error(`invalid duration: ${duration} (must be between 1s and 1h)`);
	}
	// The reason is shown on the terminal: control characters (escape sequences) and invisible ones
	// (bidi overrides, zero-width marks) become spaces, so words do not glue together. Runs of
	// whitespace collapse to one space, so a reason cannot pad the screen or start a new line.
	const reason = input.reason.replace(UNSAFE_RUN, " ").replace(/\s+/gu, " ").trim();
	if (!reason) throw new Error("a reason is required");
	const reasonLength = [...reason].length;
	if (reasonLength > MAX_REASON_LENGTH) {
		throw new Error(`reason too long: ${reasonLength} characters (the maximum is ${MAX_REASON_LENGTH})`);
	}
	return { files, duration, reason };
}

/** Seconds in a duration already accepted by normalizeRequest. */
export function durationSeconds(duration: string): number {
	const match = DURATION_RE.exec(duration);
	if (!match) throw new Error(`invalid duration: ${duration}`);
	const n = Number(match[1]);
	return match[2] === "h" ? n * 3600 : match[2] === "m" ? n * 60 : n;
}

/** Human-readable description of the request, shown before sudo asks. */
export function describeRequest(req: ShareRequest): string {
	return [
		"pi-read: the agent asks to read these root-only files",
		...req.files.map((f) => `  ${f}`),
		`for ${req.duration}. Reason: ${req.reason}`,
	].join("\n");
}

/** The sudo -p prompt: the request plus the password question, with % escaped for sudo. */
export function sudoPrompt(req: ShareRequest): string {
	return `${describeRequest(req)}\nPassword to approve (cancel to refuse): `.replaceAll("%", "%%");
}

/** pi-share arguments (after the program path). */
export function shareArgs(req: ShareRequest, pid: number): string[] {
	return ["--duration", req.duration, "--pid", String(pid), "--", ...req.files];
}

/**
 * Parse pi-share's output: "requested<TAB>copy" lines and, from a current pi-share, an
 * "expires<TAB>epoch seconds" line. The expiry is optional so a new extension still works with an
 * older installed pi-share. Throws on a malformed line and when no copy is reported.
 */
export function parseShareOutput(stdout: string): ShareOutput {
	const files: SharedFile[] = [];
	let expires: Date | undefined;
	for (const line of stdout.split("\n")) {
		if (line.trim() === "") continue;
		const parts = line.split("\t");
		if (parts.length !== 2 || !parts[0] || !parts[1]) {
			throw new Error(`unexpected pi-share output: ${JSON.stringify(line)}`);
		}
		const [key, value] = parts;
		if (key === "expires") {
			// A requested path is always absolute, so only the deadline line starts with "expires".
			if (expires || !EXPIRY_RE.test(value)) throw new Error(`unexpected pi-share output: ${JSON.stringify(line)}`);
			expires = new Date(Number(value) * 1000);
			continue;
		}
		files.push({ requested: key, copy: value });
	}
	if (files.length === 0) throw new Error("pi-share reported no copies");
	return { files, expires };
}

/** Text for the model after a successful share. */
export function formatResult(shared: SharedFile[], expires: Date): string {
	return [
		`Approved. Read-only copies (snapshots, not live files), deleted at ${expires.toISOString()}:`,
		...shared.map((s) => `  ${s.requested} -> ${s.copy}`),
		"Read the copies with your normal tools. For a fresh copy or more files, call request_root_read again.",
	].join("\n");
}
