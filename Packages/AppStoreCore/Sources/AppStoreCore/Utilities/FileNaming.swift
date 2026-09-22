import Foundation

public enum FileNaming {
    /// Sanitize a string for use as a file or directory name.
    /// Removes path separators, control characters and characters iOS/macOS
    /// filesystems reject; collapses whitespace; caps length.
    public static func sanitize(_ name: String, maxLength: Int = 80) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.controlCharacters)
            .union(.newlines)
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where !forbidden.contains(scalar) {
            scalars.append(scalar)
        }
        var result = String(scalars)
        // Collapse whitespace runs.
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        result = result.trimmingCharacters(in: .whitespaces)
        // Avoid leading dots (hidden files) and trailing dots/spaces.
        while result.hasPrefix(".") { result.removeFirst() }
        while result.hasSuffix(".") { result.removeLast() }
        if result.isEmpty { result = "app" }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix(".") || result.hasSuffix(" ") { result.removeLast() }
        }
        return result
    }

    /// e.g. "Instagram_446.0.0.ipa"
    public static func ipaFileName(appName: String, version: String) -> String {
        "\(sanitize(appName))_\(sanitize(version, maxLength: 40)).ipa"
    }
}
