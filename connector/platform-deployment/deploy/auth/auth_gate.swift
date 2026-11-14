import Foundation
import LocalAuthentication

let context = LAContext()
var error: NSError?

// Reason displayed in the Touch ID dialog / Touch Bar
let reason = "Docker MCP Platform Authorization: Touch sensor to unlock."

let semaphore = DispatchSemaphore(value: 0)
var authSuccess = false

if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evalError in
        authSuccess = success
        if let err = evalError {
            fputs("Touch ID error: \(err.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 15) // 15 second timeout for physical touch
} else {
    if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evalError in
            authSuccess = success
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
    } else {
        fputs("No biometric or hardware authentication available.\n", stderr)
    }
}

if authSuccess {
    print("AUTH_OK")
    exit(0)
} else {
    print("AUTH_FAILED")
    exit(1)
}
