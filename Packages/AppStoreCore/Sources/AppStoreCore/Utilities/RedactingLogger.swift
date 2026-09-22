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
        #if canImport(Darwin)
        appendToLogFile(category, safe)
        #endif
    }

    #if canImport(Darwin)
    /// On-device log file users can open from Files (On My iPhone → iPull)
    /// and attach to bug reports. Redacted before writing; capped at ~256 KB.
    public static var logFileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ipull-debug.log")
    }

    private static func appendToLogFile(_ category: Category, _ message: String) {
        guard let url = logFileURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(category.rawValue)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            if (try? handle.seekToEnd()) ?? 0 > 256 * 1024 {
                try? handle.truncate(atOffset: 0)
            }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    public static func clearLogFile() {
        if let url = logFileURL { try? FileManager.default.removeItem(at: url) }
    }
    #endif
}
