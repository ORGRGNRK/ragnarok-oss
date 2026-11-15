/** The subset of Workers KV this Worker uses. */
export interface KVList {
  keys: { name: string }[];
  list_complete: boolean;
  cursor?: string;
}

export interface KV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
  delete(key: string): Promise<void>;
  list(options?: { prefix?: string; cursor?: string }): Promise<KVList>;
}

export interface Env {
  SITE_KV: KV;
  /** Bearer token for GET /admin/intakes. Unset or blank hides that route (404). */
  ADMIN_TOKEN?: string;
  /** Public repo URL. Unset leaves the [REPO_URL] placeholder on the page. */
  REPO_URL?: string;
  /** Public contact address. Unset leaves [CONTACT_EMAIL] in the header and footer. */
  CONTACT_EMAIL?: string;
  /** Stripe Payment Link for the Intro tier. Unset disables that Pay button. */
  PAY_URL_INTRO?: string;
  /** Stripe Payment Link for the Standard tier. Unset disables that Pay button. */
  PAY_URL_STANDARD?: string;
}
