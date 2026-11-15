/** The subset of Workers KV this Worker uses. */
export interface KV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
  delete(key: string): Promise<void>;
}

export interface Env {
  PLAN_KV: KV;
  /** One-time secret that allows registering the first (and only) passkey. */
  SETUP_TOKEN?: string;
  /**
   * Bearer secret for the machine API (GET /api/state, POST /api/check, POST /api/numbers).
   * Unset or empty: those bearer calls answer 404. Never put this value in the repo.
   */
  DAEMON_TOKEN?: string;
  /** WebAuthn relying-party id, e.g. plan.rgnrk.co */
  RP_ID: string;
  /** Exact origin, e.g. https://plan.rgnrk.co */
  ORIGIN: string;
  RP_NAME?: string;
}
