/**
 * Compatibility shim mapping legacy Business config to Platform config.
 */
export * from "../platform/config.js";
export { loadPlatformConfig as loadConfig } from "../platform/config.js";
export type { PlatformConfig as BusinessConfig } from "../platform/config.js";
