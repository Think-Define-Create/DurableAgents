import Foundation

public enum DurableError: Error, Sendable, Equatable, CustomStringConvertible {
    case leaseHeld(owner: UUID, epoch: UInt64)
    case fenced(expectedEpoch: UInt64, actualEpoch: UInt64)
    case requestIDConflict(requestID: String, existingHash: String, attemptedHash: String)
    case unknownTool(String)
    case missingReconcile(tool: String)
    case effectKindMismatch(tool: String, stored: EffectKind, registered: EffectKind)
    case invalidResumeToken
    case notSuspended
    case approvalNeedsOutput
    case approvalAuthTooWeak(required: String, actual: String)
    case incompatibleSchema(found: Int)
    case unsupportedEventVersion(type: String, version: Int, supported: Int)
    case poisoned
    case closed
    case invariant(String)

    public var description: String {
        switch self {
        case .leaseHeld(let owner, let epoch):
            return "store lease is held by \(owner.uuidString) at epoch \(epoch)"
        case .fenced(let expected, let actual):
            return "commit rejected by fence: caller epoch \(expected), store epoch \(actual)"
        case .requestIDConflict(let requestID, let existingHash, let attemptedHash):
            return "requestId \(requestID) was already used for payload \(existingHash), not \(attemptedHash)"
        case .unknownTool(let name):
            return "no tool named \(name) is registered"
        case .missingReconcile(let tool):
            return "external tool \(tool) must implement reconcile()"
        case .effectKindMismatch(let tool, let stored, let registered):
            return "tool \(tool) was declared \(stored.rawValue) and is now registered as \(registered.rawValue)"
        case .invalidResumeToken:
            return "resume token does not match a pending approval"
        case .notSuspended:
            return "conversation is not waiting for approval"
        case .approvalNeedsOutput:
            return "resolving an unknown external effect requires approvedWithOutput"
        case .approvalAuthTooWeak(let required, let actual):
            return "approval requires \(required) authentication, got \(actual)"
        case .incompatibleSchema(let found):
            return "unsupported store schema version \(found)"
        case .unsupportedEventVersion(let type, let version, let supported):
            return "event \(type) schema \(version) is newer than supported version \(supported)"
        case .poisoned:
            return "engine is poisoned after a fencing failure or a simulated crash"
        case .closed:
            return "engine lease has been released"
        case .invariant(let detail):
            return "invariant violated: \(detail)"
        }
    }
}

/// Thrown by a tool, or by a test, to leave a durable intent without a result.
/// The engine does not convert this into a failed run.
public struct SimulatedProcessCrash: Error, Sendable, Equatable {
    public init() {}
}
