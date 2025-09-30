import Dispatch
import Foundation

/// Quality of service levels for dispatch queues.
public enum QoSClass: Sendable {
    case userInteractive
    case userInitiated
    case `default`
    case utility
    case background
    case unspecified

    /// Convert to DispatchQoS for actual usage.
    var dispatchQoS: DispatchQoS {
        switch self {
        case .userInteractive:
            return .userInteractive
        case .userInitiated:
            return .userInitiated
        case .default:
            return .default
        case .utility:
            return .utility
        case .background:
            return .background
        case .unspecified:
            return .unspecified
        }
    }
}
