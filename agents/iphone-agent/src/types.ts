export const SCHEMA_VERSION = "0.1" as const;

export type SchemaVersion = typeof SCHEMA_VERSION;
export type RiskClass =
  | "read"
  | "reversible"
  | "external"
  | "financial"
  | "destructive"
  | "credential";

export type InputType = "string" | "number" | "integer" | "boolean";

export interface SafetyDeclaration {
  risk: RiskClass;
  requiresConfirmation?: boolean;
}

export interface InputDefinition {
  type: InputType;
  description?: string;
  required?: boolean;
  secret?: boolean;
  default?: unknown;
}

export interface NormalizedPoint {
  x: number;
  y: number;
}

export interface PortableTarget {
  role?: string;
  label?: string;
  text?: string;
  hint?: string;
  within?: string;
  fallbackPoint?: NormalizedPoint;
  minimumConfidence?: number;
}

export interface AppTarget {
  name?: string;
  bundleId?: string;
}

export interface ObservationConstraint {
  screenText?: string;
  app?: AppTarget;
  target?: PortableTarget;
  all?: ObservationConstraint[];
  any?: ObservationConstraint[];
  not?: ObservationConstraint;
}

export interface FailureBehavior {
  behavior: "stop" | "retry" | "requestHelp" | "recover";
  maxAttempts?: number;
  recoveryCommandId?: string;
}

export type ActionName =
  | "openApp"
  | "tap"
  | "typeText"
  | "swipe"
  | "press"
  | "capture"
  | "waitFor"
  | "assert"
  | "confirm"
  | "call";

export type DriverAction = "openApp" | "tap" | "typeText" | "swipe" | "press";
export type ObservationCapability = "screenshot" | "screenText" | "app" | "target";

interface StepBase {
  id: string;
  precondition?: ObservationConstraint;
  expect?: ObservationConstraint;
  safety?: SafetyDeclaration;
}

export interface OpenAppStep extends StepBase {
  action: "openApp";
  app: AppTarget;
}

export interface TapStep extends StepBase {
  action: "tap";
  target: PortableTarget;
}

export interface TypeTextStep extends StepBase {
  action: "typeText";
  text: string;
  target?: PortableTarget;
}

export interface SwipeStep extends StepBase {
  action: "swipe";
  direction: "up" | "down" | "left" | "right";
  distance?: number;
  from?: NormalizedPoint;
}

export interface PressStep extends StepBase {
  action: "press";
  button: "home" | "appSwitcher" | "back";
}

export interface CaptureStep extends StepBase {
  action: "capture";
  /** Stable, human-readable name used by artifact stores when materializing the screenshot. */
  label: string;
}

export interface WaitForStep extends StepBase {
  action: "waitFor";
  condition: ObservationConstraint;
  timeoutMs?: number;
}

export interface AssertStep extends StepBase {
  action: "assert";
  condition: ObservationConstraint;
}

export interface ConfirmStep extends StepBase {
  action: "confirm";
  message: string;
}

export interface CallStep extends StepBase {
  action: "call";
  commandId: string;
  commandVersion?: string;
  inputs?: Record<string, unknown>;
}

export type CommandStep =
  | OpenAppStep
  | TapStep
  | TypeTextStep
  | SwipeStep
  | PressStep
  | CaptureStep
  | WaitForStep
  | AssertStep
  | ConfirmStep
  | CallStep;

export interface CommandDocument {
  schemaVersion: SchemaVersion;
  version: string;
  id: string;
  name: string;
  description?: string;
  inputs: Record<string, InputDefinition>;
  preconditions: ObservationConstraint[];
  steps: CommandStep[];
  onFailure: FailureBehavior;
  safety: SafetyDeclaration;
  postconditions: ObservationConstraint[];
}

export interface DriverCapabilities {
  actions: DriverAction[];
  observations: ObservationCapability[];
}

export interface RequiredCapabilities {
  actions: DriverAction[];
  observations: ObservationCapability[];
}

export interface MissingCapability {
  kind: "action" | "observation";
  capability: DriverAction | ObservationCapability;
  stepIds: string[];
}

export interface CapabilityCheck {
  supported: boolean;
  required: RequiredCapabilities;
  missing: MissingCapability[];
}

export interface PreparedCommand {
  command: CommandDocument;
  inputs: Record<string, unknown>;
  redactedInputs: Record<string, unknown>;
}

export interface StepSafetyAssessment {
  stepId: string;
  action: ActionName;
  risk: RiskClass;
  requiresConfirmation: boolean;
}

export interface SafetyAssessment {
  risk: RiskClass;
  requiresConfirmation: boolean;
  steps: StepSafetyAssessment[];
  confirmationStepIds: string[];
}
