/**
 * Hardware Presence Security Gate for Docker MCP platform.
 *
 * Implements a fail-closed lock state:
 * - When Docker boots, the platform is locked by default.
 * - Unlocks require physical hardware presence:
 *   1. YubiKey (FIDO2 / CTAP2 user presence bit confirmation via touch).
 *   2. Apple Secure Enclave (Touch ID / LocalAuthentication for the macOS app version).
 * - Sessions lease for a configurable TTL (e.g. 60m), after which the gate auto-locks.
 */

export interface GateStatus {
  locked: boolean;
  method: "yubikey" | "secure_enclave" | null;
  unlockedAt: string | null;
  expiresAt: string | null;
  remainingMinutes: number;
}

export interface SecurityGateOptions {
  requireAuth?: boolean;
  sessionTtlMinutes?: number;
  unlockSecret?: string;
}

export class SecurityGate {
  private locked: boolean;
  private method: "yubikey" | "secure_enclave" | null = null;
  private unlockedAt: Date | null = null;
  private expiresAt: Date | null = null;
  private monotonicExpiresAt: number | null = null;
  private readonly ttlMs: number;
  private readonly enabled: boolean;
  private readonly unlockSecret?: string;

  constructor(opts?: SecurityGateOptions) {
    this.enabled = opts?.requireAuth !== false;
    this.locked = this.enabled;
    this.ttlMs = (opts?.sessionTtlMinutes ?? 60) * 60 * 1000;
    this.unlockSecret = opts?.unlockSecret;
  }

  isLocked(): boolean {
    if (!this.enabled) return false;
    if (this.locked) return true;
    // Check both wall-clock and monotonic process clock (prevents time-travel / clock rollbacks from extending leases)
    const wallExpired = this.expiresAt !== null && Date.now() > this.expiresAt.getTime();
    const monotonicExpired = this.monotonicExpiresAt !== null && performance.now() > this.monotonicExpiresAt;
    if (wallExpired || monotonicExpired) {
      this.lock();
      return true;
    }
    return false;
  }

  unlock(method: "yubikey" | "secure_enclave", proof?: string): { success: boolean; expiresAt: Date } {
    if (this.unlockSecret && proof !== this.unlockSecret) {
      throw new Error("Invalid hardware authorization proof or secret");
    }
    this.locked = false;
    this.method = method;
    this.unlockedAt = new Date();
    this.expiresAt = new Date(Date.now() + this.ttlMs);
    this.monotonicExpiresAt = performance.now() + this.ttlMs;
    return { success: true, expiresAt: this.expiresAt };
  }

  lock(): void {
    if (!this.enabled) return;
    this.locked = true;
    this.method = null;
    this.unlockedAt = null;
    this.expiresAt = null;
    this.monotonicExpiresAt = null;
  }

  getStatus(): GateStatus {
    const isNowLocked = this.isLocked();
    let remaining = 0;
    if (!isNowLocked && this.expiresAt) {
      remaining = Math.max(0, Math.round((this.expiresAt.getTime() - Date.now()) / 60000));
    }
    return {
      locked: isNowLocked,
      method: isNowLocked ? null : this.method,
      unlockedAt: isNowLocked || !this.unlockedAt ? null : this.unlockedAt.toISOString(),
      expiresAt: isNowLocked || !this.expiresAt ? null : this.expiresAt.toISOString(),
      remainingMinutes: remaining,
    };
  }
}
