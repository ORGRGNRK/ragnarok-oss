/**
 * Compatibility shim mapping legacy Business imports to generic Platform runtime.
 */
export * from "../platform/app.js";
export { createPlatformRuntime as createBusinessRuntime } from "../platform/app.js";
export { loadPlatformConfig as loadConfig } from "../platform/config.js";
