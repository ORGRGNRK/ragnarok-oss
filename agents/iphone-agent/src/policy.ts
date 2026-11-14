import type {
  ActionName,
  CommandDocument,
  RiskClass,
  SafetyAssessment,
  StepSafetyAssessment
} from "./types.js";

const riskRank: Record<RiskClass, number> = {
  read: 0,
  reversible: 1,
  external: 2,
  financial: 3,
  destructive: 4,
  credential: 5
};

const actionFloor: Record<ActionName, RiskClass> = {
  openApp: "reversible",
  tap: "reversible",
  typeText: "reversible",
  swipe: "reversible",
  press: "reversible",
  capture: "read",
  waitFor: "read",
  assert: "read",
  confirm: "read",
  call: "reversible"
};

/** True when `risk` sits at or below `ceiling` on the shared risk ladder. */
export function isAtMostRisk(risk: RiskClass, ceiling: RiskClass): boolean {
  return riskRank[risk] <= riskRank[ceiling];
}

export function assessSafety(command: CommandDocument, machineFloor: RiskClass = "read"): SafetyAssessment {
  const steps: StepSafetyAssessment[] = command.steps.map((step) => {
    const declaredRisk = step.safety?.risk ?? command.safety.risk;
    const risk = highestRisk(declaredRisk, actionFloor[step.action], machineFloor);
    const requiresConfirmation =
      step.action !== "confirm" &&
      (riskRank[risk] >= riskRank.external ||
        command.safety.requiresConfirmation === true ||
        step.safety?.requiresConfirmation === true);

    return {
      stepId: step.id,
      action: step.action,
      risk,
      requiresConfirmation
    };
  });

  const risk = highestRisk(command.safety.risk, machineFloor, ...steps.map((step) => step.risk));
  const confirmationStepIds = steps
    .filter((step) => step.requiresConfirmation)
    .map((step) => step.stepId);

  return {
    risk,
    requiresConfirmation: confirmationStepIds.length > 0,
    steps,
    confirmationStepIds
  };
}

function highestRisk(...risks: RiskClass[]): RiskClass {
  return risks.reduce((highest, risk) => (riskRank[risk] > riskRank[highest] ? risk : highest), "read");
}
