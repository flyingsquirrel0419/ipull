import Foundation
import AppStoreCore

/// Where finished IPAs are written. The folder comes from the Files picker
/// and is stored as a security-scoped bookmark, so it survives relaunches.
/// No folder set means "ask on every download".
enum SaveLocation {
    private static let bookmarkKey = "save-folder-bookmark"
    private static let keepKey = "save-keep-library-copy"

    /// Bookmark for the folder chosen in Settings, if any.
    static var defaultBookmark: Data? {
        UserDefaults.standard.data(forKey: bookmarkKey)
    }

    static var defaultFolderName: String? {
        defaultBookmark.flatMap(resolve)?.lastPathComponent
    }

    static func setDefaultFolder(_ url: URL?) throws {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return
        }
        UserDefaults.standard.set(try bookmark(for: url), forKey: bookmarkKey)
    }

    /// Also keep the IPA in iPull's Library (share, verify, rename). Off
    /// means the file is moved to the folder and nothing is duplicated.
    static var keepLibraryCopy: Bool {
        get { UserDefaults.standard.object(forKey: keepKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepKey) }
    }

    /// Bookmark a folder URL handed out by the Files picker.
    static func bookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Copy (or move) a finished IPA into the bookmarked folder, replacing a
    /// file of the same name. Returns the written URL.
    @discardableResult
    static func export(_ file: URL, to bookmark: Data, move: Bool) throws -> URL {
        guard let folder = resolve(bookmark) else { throw AppStoreError.fileWriteFailed }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let target = folder.appendingPathComponent(file.lastPathComponent)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) {
            try manager.removeItem(at: target)
        }
        if move {
            try manager.moveItem(at: file, to: target)
        } else {
            try manager.copyItem(at: file, to: target)
        }
        return target
    }
}
