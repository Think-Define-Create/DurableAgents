import DurableCore
import Foundation

#if canImport(LocalAuthentication)
import LocalAuthentication

/// Face ID or device passcode gate for high-risk approvals. Not compiled on Linux.
enum EscrowBiometricGate {
    static func evaluate(reason: String) async -> AuthenticationLevel? {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            let ok = (try? await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )) ?? false
            if ok { return .biometric }
        }
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            let ok = (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )) ?? false
            if ok { return .devicePasscode }
        }
        return nil
    }
}
#endif
