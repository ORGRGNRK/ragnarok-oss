import type { CommandStep, ObservationConstraint } from "./types.js";

/**
 * Plain language for the steps of a command. The authoring preview, the confirmation dialog,
 * and the receipt all describe a step through these functions, so the sentence a person
 * approves is the same sentence they were shown when the routine was saved.
 */
export function describeStep(step: CommandStep): string {
  const base = ((): string => {
    switch (step.action) {
      case "openApp":
        return `Open ${step.app.name ?? step.app.bundleId ?? "an app"} on your iPhone`;
      case "tap":
        return `Tap ${quoted(step.target.text ?? step.target.label ?? "the chosen spot")}`;
      case "typeText":
        return `Type ${quoted(step.text)}`;
      case "swipe":
        return `Swipe ${step.direction}`;
      case "press":
        return `Press ${step.button === "appSwitcher" ? "App Switcher" : step.button}`;
      case "capture":
        return `Capture a screenshot named ${quoted(step.label)}`;
      case "waitFor":
        return `Wait until ${describeCondition(step.condition)}`;
      case "assert":
        return `Check that ${describeCondition(step.condition)}`;
      case "confirm":
        return `Ask you to confirm: ${step.message}`;
      case "call":
        return `Run the saved command ${step.commandId}`;
    }
  })();
  return step.expect ? `${base}, then check that ${describeCondition(step.expect)}` : base;
}

export function describeCondition(condition: ObservationConstraint): string {
  const parts: string[] = [];
  if (condition.screenText !== undefined) parts.push(`the screen shows ${quoted(condition.screenText)}`);
  if (condition.app !== undefined) parts.push(`${condition.app.name ?? condition.app.bundleId ?? "the app"} is open`);
  if (condition.target !== undefined) {
    parts.push(`${quoted(condition.target.text ?? condition.target.label ?? "the target")} is on screen`);
  }
  for (const child of condition.all ?? []) parts.push(describeCondition(child));
  if (condition.any && condition.any.length > 0) parts.push(condition.any.map(describeCondition).join(" or "));
  if (condition.not) parts.push(`it is not true that ${describeCondition(condition.not)}`);
  return parts.length > 0 ? parts.join(" and ") : "the expected screen appears";
}

export function quoted(value: string): string {
  return `“${value}”`;
}
