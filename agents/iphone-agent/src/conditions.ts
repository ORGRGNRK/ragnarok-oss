import type { DriverObservation, VerificationReceipt } from "./runtime-types.js";
import type { AppTarget, ObservationConstraint, PortableTarget } from "./types.js";

export function evaluateCondition(
  condition: ObservationConstraint,
  observation: DriverObservation
): VerificationReceipt {
  const failures: string[] = [];

  if (condition.screenText !== undefined && !hasScreenText(observation, condition.screenText)) {
    failures.push(`screen text does not contain ${JSON.stringify(condition.screenText)}`);
  }
  if (condition.app !== undefined && !matchesApp(observation.app, condition.app)) {
    failures.push("observed app does not match");
  }
  if (condition.target !== undefined && !hasTarget(observation, condition.target)) {
    failures.push("target was not observed");
  }
  if (condition.all) {
    for (const child of condition.all) {
      const result = evaluateCondition(child, observation);
      if (!result.passed) failures.push(result.message ?? "all-condition failed");
    }
  }
  if (condition.any) {
    const results = condition.any.map((child) => evaluateCondition(child, observation));
    if (!results.some((result) => result.passed)) {
      failures.push("no any-condition matched");
    }
  }
  if (condition.not) {
    const result = evaluateCondition(condition.not, observation);
    if (result.passed) failures.push("not-condition matched");
  }

  return failures.length === 0
    ? { passed: true }
    : { passed: false, message: failures.join("; ") };
}

function hasScreenText(observation: DriverObservation, expected: string): boolean {
  const needle = normalize(expected);
  return observation.screenText?.some((text) => normalize(text).includes(needle)) === true;
}

function matchesApp(observed: AppTarget | undefined, expected: AppTarget): boolean {
  if (!observed) return false;
  if (expected.name !== undefined && normalize(observed.name ?? "") !== normalize(expected.name)) return false;
  if (expected.bundleId !== undefined && observed.bundleId !== expected.bundleId) return false;
  return true;
}

function hasTarget(observation: DriverObservation, expected: PortableTarget): boolean {
  const candidates = observation.metadata?.targets;
  if (!Array.isArray(candidates)) return false;
  return candidates.some((candidate) => {
    if (typeof candidate !== "object" || candidate === null) return false;
    const target = candidate as Record<string, unknown>;
    return ["role", "label", "text", "within"].every((key) => {
      const expectedValue = expected[key as keyof PortableTarget];
      return typeof expectedValue !== "string" || normalize(String(target[key] ?? "")) === normalize(expectedValue);
    });
  });
}

function normalize(value: string): string {
  return value.normalize("NFKC").trim().toLocaleLowerCase();
}
