/**
 * The yes/no question pi asks on its terminal when sudo still remembers the password for pi-share,
 * so a request is never approved without an answer from the user.
 */

import type { Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth } from "@earendil-works/pi-tui";

export const CONFIRM_QUESTION = "sudo still remembers your password. Approve this request?";
export const CONFIRM_HINT = "←/→ choose · enter confirms · esc refuses";

/** The colours the component uses; pi's Theme provides them. */
export type ConfirmTheme = Pick<Theme, "fg" | "bold">;

export interface ConfirmComponent {
	render(width: number): string[];
	handleInput(data: string): void;
	invalidate(): void;
}

/**
 * The confirmation: the request, the question, Yes and No side by side, and a hint. Nothing is
 * selected at first; left selects Yes, right selects No; enter answers the selection (nothing
 * while none is selected); esc answers No at once. requestRender redraws after a change.
 */
export function confirmComponent(
	description: string,
	theme: ConfirmTheme,
	done: (approved: boolean) => void,
	requestRender: () => void = () => {},
): ConfirmComponent {
	let selected: "yes" | "no" | undefined;
	let finished = false;
	const option = (label: string, on: boolean) => (on ? theme.bold(theme.fg("accent", `[ ${label} ]`)) : `  ${label}  `);
	const finish = (approved: boolean) => {
		if (finished) return;
		finished = true;
		done(approved);
	};
	return {
		render(width: number): string[] {
			return [
				...description.split("\n"),
				"",
				theme.fg("warning", CONFIRM_QUESTION),
				`${option("Yes", selected === "yes")}  ${option("No", selected === "no")}`,
				theme.fg("dim", CONFIRM_HINT),
			].map((line) => truncateToWidth(line, width));
		},
		handleInput(data: string): void {
			if (matchesKey(data, "escape")) {
				finish(false);
			} else if (matchesKey(data, "enter")) {
				if (selected) finish(selected === "yes");
			} else if (matchesKey(data, "left")) {
				selected = "yes";
				requestRender();
			} else if (matchesKey(data, "right")) {
				selected = "no";
				requestRender();
			}
		},
		invalidate(): void {},
	};
}
