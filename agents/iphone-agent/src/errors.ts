export type ProtocolErrorCode =
  | "PARSE_ERROR"
  | "SCHEMA_INVALID"
  | "INPUT_MISSING"
  | "INPUT_UNKNOWN"
  | "INPUT_TYPE"
  | "VARIABLE_INVALID"
  | "UNSUPPORTED_CAPABILITY"
  | "UNSUPPORTED_STEP"
  | "DRIVER_ERROR"
  | "TARGET_NOT_FOUND"
  | "TARGET_CONFIDENCE"
  | "PRECONDITION_FAILED"
  | "POSTCONDITION_FAILED"
  | "CONFIRMATION_DENIED"
  | "CONFIRMATION_UNAVAILABLE"
  | "CONFIRMATION_STALE"
  | "WAIT_TIMEOUT"
  | "COMMAND_NOT_FOUND"
  | "COMMAND_CYCLE"
  | "INCOMPATIBLE_VERSION"
  | "RESUME_INVALID"
  | "COMMIT_OUTCOME_UNCERTAIN"
  | "RECOVERY_FAILED";

export class CommandProtocolError extends Error {
  readonly code: ProtocolErrorCode;
  readonly path?: string;
  readonly details?: unknown;

  constructor(code: ProtocolErrorCode, message: string, options: { path?: string; details?: unknown } = {}) {
    super(message);
    this.name = "CommandProtocolError";
    this.code = code;
    this.path = options.path;
    this.details = options.details;
  }

  toJSON(): { code: ProtocolErrorCode; message: string; path?: string; details?: unknown } {
    return {
      code: this.code,
      message: this.message,
      ...(this.path === undefined ? {} : { path: this.path }),
      ...(this.details === undefined ? {} : { details: this.details })
    };
  }
}
