import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum IntelligenceAvailabilityStatus: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        self == .available
    }

    var message: String {
        switch self {
        case .available:
            return "Apple Intelligence is available."
        case .unavailable(let reason):
            return reason
        }
    }
}

struct IntelligenceAvailabilityService {
    func currentStatus() -> IntelligenceAvailabilityStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(message(for: reason))
            }
        }
        #endif

        return .unavailable("Apple Intelligence editing requires macOS 26 or later.")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Apple Intelligence is not available on this Mac."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off in System Settings."
        case .modelNotReady:
            return "Apple Intelligence is not ready yet."
        @unknown default:
            return "Apple Intelligence is unavailable."
        }
    }
    #endif
}
