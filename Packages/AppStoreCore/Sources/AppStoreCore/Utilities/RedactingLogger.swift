import Foundation
#if canImport(os)
import os.log
#endif

/// Logger that redacts credentials and tokens. Rule: nothing sensitive
/// (password, passwordToken, DSID, full URLs with tokens) ever reaches a log
/// line — including debug builds.
public enum Log {
    public enum Category: String {
        case auth, network, download, library, ui
    }

    private static let sensitivePatterns: [String] = [
        "passwordToken", "password", "X-Token", "dsPersonId", "iCloud-DSID", "X-Dsid",
    ]

    public static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(category, message())
        #endif
    }

    public static func info(_ category: Category, _ message: @autoclosure () -> String) {
        emit(category, message())
    }

    public static func error(_ category: Category, _ message: @autoclosure () -> String) {
        emit(category, message())
    }

    static func sanitize(_ message: String) -> String {
        var result = message
        for pattern in sensitivePatterns {
            // Redact "key=value" and "key: value" occurrences.
            if let range = result.range(of: pattern, options: .caseInsensitive) {
                let tail = result[range.upperBound...]
                if let eqIndex = tail.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                    let valueStart = tail.index(after: eqIndex)
                    let valueEnd = tail[valueStart...].firstIndex(where: { $0 == " " || $0 == "," || $0 == "}" }) ?? tail.endIndex
                    let fullRange = range.lowerBound..<valueEnd
                    result.replaceSubrange(fullRange, with: "\(pattern): <redacted>")
                }
            }
        }
        return result
    }

    private static func emit(_ category: Category, _ message: String) {
        let safe = sanitize(message)
        #if canImport(os)
        let logger = os.Logger(subsystem: "com.ipull.app", category: category.rawValue)
        logger.log(level: .debug, "\(safe, privacy: .public)")
        #else
        print("[\(category.rawValue)] \(safe)")
        #endif
    }
}
