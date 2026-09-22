import Foundation

/// Typed error model for all iPull operations. UI shows `userMessage`;
/// logs may include `debugDetail` but must never contain credentials.
public enum AppStoreError: Error, Equatable, Sendable {
    case invalidInput
    case invalidAppStoreURL
    case appNotFound
    case authenticationRequired
    case authenticationFailed
    case accountDisabled
    case twoFactorRequired
    case invalidTwoFactorCode
    case sessionExpired
    case appNotOwned
    case purchaseRequired
    case purchaseFailed
    case paidAppNotSupported
    case versionUnavailable
    case downloadURLUnavailable
    case downloadFailed(String)
    case networkUnavailable
    case rateLimited(retryAfterSeconds: Int?)
    case storageFull
    case fileWriteFailed
    case exportFailed
    case unknown(String)
}

extension AppStoreError: LocalizedError {
    public var errorDescription: String? { userMessage }

    /// User-facing message. No tokens, endpoints, or internal identifiers.
    public var userMessage: String {
        switch self {
        case .invalidInput:
            return "This doesn't look like an App Store app."
        case .invalidAppStoreURL:
            return "This doesn't look like an App Store link."
        case .appNotFound:
            return "We couldn't find this app on the App Store."
        case .authenticationRequired:
            return "Sign in with your Apple Account to continue."
        case .authenticationFailed:
            return "Sign-in failed. Check your Apple Account email and password."
        case .accountDisabled:
            return "This Apple Account is disabled. Contact Apple Support."
        case .twoFactorRequired:
            return "Enter the six-digit verification code from your trusted device."
        case .invalidTwoFactorCode:
            return "That verification code didn't work. Try a fresh code."
        case .sessionExpired:
            return "Your session expired. Sign in again."
        case .appNotOwned:
            return "This Apple Account doesn't have access to this app."
        case .purchaseRequired:
            return "You need to get this app on your Apple Account first."
        case .purchaseFailed:
            return "We couldn't add this app to your account. Try again later."
        case .paidAppNotSupported:
            return "Paid apps must be purchased in the App Store app first."
        case .versionUnavailable:
            return "This version is no longer available for download."
        case .downloadURLUnavailable:
            return "Apple didn't provide a download for this version."
        case .downloadFailed:
            return "The download failed. You can retry it."
        case .networkUnavailable:
            return "No network connection. Check your connection and retry."
        case .rateLimited(let seconds):
            if let seconds, seconds > 0 {
                return "Apple is rate limiting requests. Try again in \(seconds) seconds."
            }
            return "Apple is rate limiting requests. Try again later."
        case .storageFull:
            return "Not enough free storage on this iPhone."
        case .fileWriteFailed:
            return "Couldn't save the file."
        case .exportFailed:
            return "Couldn't export the file."
        case .unknown:
            return "Something went wrong. Try again."
        }
    }

    /// Whether re-authentication would resolve this error.
    public var requiresReauthentication: Bool {
        switch self {
        case .sessionExpired, .authenticationRequired, .authenticationFailed:
            return true
        default:
            return false
        }
    }
}
