import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Derives the machine GUID Apple expects (12 uppercase hex chars).
///
/// Desktop tools use the MAC address; iOS exposes none. We derive a stable
/// per-device value from identifierForVendor and persist it in the
/// Keychain so reinstalls keep the same identity (and Apple doesn't see a
/// "new device" on every launch).
public enum DeviceIdentity {
    public static let keychainKey = "device-guid"

    public static func currentGUID(secretStore: SecretStore) throws -> String {
        if let existing = try secretStore.load(key: keychainKey),
           let guid = String(data: existing, encoding: .utf8),
           isValidGUID(guid) {
            return guid
        }
        let guid = generateGUID()
        try secretStore.save(Data(guid.utf8), for: keychainKey)
        return guid
    }

    static func generateGUID() -> String {
        #if canImport(UIKit) && !os(macOS)
        if let vendorID = UIDevice.current.identifierForVendor {
            return guidFromUUID(vendorID)
        }
        #endif
        return guidFromUUID(UUID())
    }

    /// Take the first 12 hex chars of a UUID's uppercase hex form.
    static func guidFromUUID(_ uuid: UUID) -> String {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        return String(hex.prefix(12))
    }

    public static func isValidGUID(_ guid: String) -> Bool {
        guid.count == 12 && guid.allSatisfy { $0.isHexDigit && !$0.isLowercase }
    }
}
