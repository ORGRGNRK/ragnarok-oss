import type {
  AppTarget,
  CommandDocument,
  CommandStep,
  DriverAction,
  DriverCapabilities,
  ObservationCapability,
  PortableTarget,
  PreparedCommand,
  RiskClass
} from "./types.js";

export interface DriverObservation {
  capturedAt: string;
  screenText?: string[];
  app?: AppTarget;
  screenshotRef?: string;
  /**
   * Captured pixels per unit of requested screen area, when the driver can measure it. This is
   * how much detail the observation actually got, so a reading below what the driver expects
   * explains a verification failure that would otherwise look like a broken command.
   */
  captureScale?: number;
  metadata?: Record<string, unknown>;
}

export interface ResolvedTarget {
  strategy: string;
  confidence: number;
  point: { x: number; y: number };
  clue?: string;
}

export type DriverStep = Extract<
  CommandStep,
  { action: "openApp" | "tap" | "typeText" | "swipe" | "press" }
>;

export interface DriverActionResult {
  resolvedTarget?: ResolvedTarget;
  metadata?: Record<string, unknown>;
}

export interface DriverSession {
  id: string;
  version?: string;
  capabilities: DriverCapabilities;
}

export interface PortableDriver {
  startSession(): Promise<DriverSession>;
  stopSession?(): Promise<void>;
  observe(): Promise<DriverObservation>;
  execute(step: DriverStep): Promise<DriverActionResult>;
}

export interface ReceiptError {
  code: string;
  message: string;
  path?: string;
  details?: unknown;
}

export interface ConfirmationShown {
  message: string;
  risk: RiskClass;
  /** The observation the person was asked about, so the receipt records what they saw. */
  screen?: DriverObservation;
}

export interface ConfirmationReceipt {
  required: boolean;
  outcome: "not-required" | "approved" | "denied" | "unavailable" | "stale";
  confirmedAt?: string;
  actor?: string;
  /** What the person was shown. An approval is only auditable alongside the screen it was given for. */
  shown?: ConfirmationShown;
}

export interface VerificationReceipt {
  passed: boolean;
  message?: string;
}

export interface StepReceipt {
  id: string;
  action: CommandStep["action"];
  status: "pending" | "running" | "succeeded" | "failed" | "stopped" | "unsupported";
  attempt: number;
  startedAt: string;
  endedAt?: string;
  before?: DriverObservation;
  after?: DriverObservation;
  resolvedTarget?: ResolvedTarget;
  confirmation?: ConfirmationReceipt;
  verification?: VerificationReceipt;
  error?: ReceiptError;
}

export interface ExecutionReceipt {
  schemaVersion: "0.1";
  id: string;
  command: { id: string; schemaVersion: "0.1"; version?: string };
  status: "pending" | "running" | "succeeded" | "failed" | "stopped" | "unsupported";
  startedAt: string;
  endedAt?: string;
  inputs: Record<string, unknown>;
  driver: {
    id: string;
    version?: string;
    actions: DriverAction[];
    observations: ObservationCapability[];
  };
  steps: StepReceipt[];
  error?: ReceiptError;
  artifacts?: ExecutionArtifact[];
}

export interface ExecutionArtifact {
  kind: "screenshot" | "log" | "other";
  reference: string;
  mediaType?: string;
}

export interface ScreenshotArtifactRequest {
  receiptId: string;
  stepId: string;
  label: string;
  observation: DriverObservation;
}

/** Materializes a captured observation before a later frame can replace its temporary source. */
export interface ScreenshotArtifactSink {
  writeScreenshot(request: ScreenshotArtifactRequest): Promise<ExecutionArtifact>;
}

export interface ReceiptSink {
  write(receipt: ExecutionReceipt): Promise<void>;
}

export interface ConfirmationRequest {
  command: Pick<CommandDocument, "id" | "name">;
  step: CommandStep;
  risk: RiskClass;
  message: string;
  /** What the screen showed when the runner parked. Providers should put this in front of the person. */
  observed?: DriverObservation;
}

export interface ConfirmationDecision {
  approved: boolean;
  actor?: string;
}

export interface ConfirmationProvider {
  confirm(request: ConfirmationRequest): Promise<ConfirmationDecision>;
}

export interface CommandRegistry {
  get(commandId: string, versionRange?: string): Promise<CommandDocument | undefined>;
}

export interface RunnerOptions {
  receiptSink?: ReceiptSink;
  screenshotArtifactSink?: ScreenshotArtifactSink;
  confirmationProvider?: ConfirmationProvider;
  commandRegistry?: CommandRegistry;
  machineSafetyFloor?: RiskClass;
  clock?: () => Date;
  idFactory?: () => string;
  waitIntervalMs?: number;
}

export interface RunRequest {
  command: CommandDocument;
  inputs?: Record<string, unknown>;
  resumeFrom?: ExecutionReceipt;
}

export interface RunContext {
  prepared: PreparedCommand;
  receipt: ExecutionReceipt;
}

export interface MirrorFrame {
  bytes?: Uint8Array;
  mediaType?: string;
  reference?: string;
  /** Captured pixels per requested point. See `captureScale` in `macos-mirror-port.ts`. */
  scale?: number;
}

export interface MirrorHostState {
  accessibilityText: string;
  frame?: MirrorFrame;
}

export interface MirrorControlPort {
  focus(): Promise<void>;
  getState(): Promise<MirrorHostState>;
  clickElement(elementIndex: number): Promise<void>;
  clickPoint(x: number, y: number): Promise<void>;
  typeText(text: string): Promise<void>;
  pressKey(key: string): Promise<void>;
  swipePoint(startX: number, startY: number, endX: number, endY: number): Promise<void>;
}

export interface MirrorObservationResolver {
  capabilities: ObservationCapability[];
  observe(state: MirrorHostState): Promise<Omit<DriverObservation, "capturedAt">>;
  resolveTarget?(state: MirrorHostState, target: PortableTarget): Promise<ResolvedTarget | undefined>;
}

export interface MirrorActionBounds {
  left: number;
  top: number;
  width: number;
  height: number;
}
