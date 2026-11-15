import assert from "node:assert/strict";
import test from "node:test";
import { visibleWidth } from "@earendil-works/pi-tui";
import { CONFIRM_HINT, CONFIRM_QUESTION, type ConfirmTheme, confirmComponent } from "../src/confirm.ts";

const theme: ConfirmTheme = { fg: (_color, text) => text, bold: (text) => text };
const description = "pi-read: the agent asks to read these root-only files\n  /etc/x\nfor 15m. Reason: because";
const ESC = "\x1b";
const ENTER = "\r";
const LEFT = "\x1b[D";
const RIGHT = "\x1b[C";

function make() {
	const answers: boolean[] = [];
	const component = confirmComponent(description, theme, (approved) => answers.push(approved));
	return { component, answers };
}

const optionsLine = (lines: string[]) => lines.find((l) => l.includes("Yes") && l.includes("No")) ?? "";

test("the confirmation starts with nothing selected and enter alone does nothing", () => {
	const { component, answers } = make();
	const line = optionsLine(component.render(80));
	assert.ok(!line.includes("["), `nothing is selected: ${line}`);
	component.handleInput(ENTER);
	component.handleInput("y");
	assert.deepEqual(answers, []);
});

test("left selects Yes and right selects No, and enter answers the selection", () => {
	const yes = make();
	yes.component.handleInput(LEFT);
	yes.component.handleInput(LEFT);
	assert.match(optionsLine(yes.component.render(80)), /\[ Yes \]/);
	yes.component.handleInput(ENTER);
	assert.deepEqual(yes.answers, [true]);

	const no = make();
	no.component.handleInput(LEFT);
	no.component.handleInput(RIGHT);
	const line = optionsLine(no.component.render(80));
	assert.match(line, /\[ No \]/);
	assert.doesNotMatch(line, /\[ Yes \]/);
	no.component.handleInput(ENTER);
	assert.deepEqual(no.answers, [false]);
});

test("esc answers No whatever is selected", () => {
	const none = make();
	none.component.handleInput(ESC);
	assert.deepEqual(none.answers, [false]);

	const yes = make();
	yes.component.handleInput(LEFT);
	yes.component.handleInput(ESC);
	yes.component.handleInput(ENTER);
	assert.deepEqual(yes.answers, [false]);
});

test("the confirmation shows the request, the question and the hint within the width", () => {
	const { component } = make();
	const wide = component.render(200);
	for (const line of description.split("\n")) assert.ok(wide.includes(line), `missing: ${line}`);
	assert.ok(wide.includes(CONFIRM_QUESTION));
	assert.ok(wide.includes(CONFIRM_HINT));
	for (const line of component.render(20)) assert.ok(visibleWidth(line) <= 20, `too wide: ${line}`);
});
