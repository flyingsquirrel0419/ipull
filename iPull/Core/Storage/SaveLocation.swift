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

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

/// Files folder picker, presented modally from the top view controller.
/// Embedding the picker in a SwiftUI sheet (as a representable) showed it
/// but left its Open button dead; the picker has to own its presentation.
@MainActor
enum FolderPicker {
    /// Keeps the delegate alive while the picker is on screen.
    private static var active: Delegate?

    /// Calls `onPick` once with the chosen folder, or nil when cancelled or
    /// when nothing can present the picker.
    static func present(onPick: @escaping @MainActor (URL?) -> Void) {
        guard active == nil, let top = topViewController() else {
            onPick(nil)
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        let delegate = Delegate { url in
            active = nil
            onPick(url)
        }
        active = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    @MainActor
    final class Delegate: NSObject, UIDocumentPickerDelegate {
        private let onPick: @MainActor (URL?) -> Void

        init(onPick: @escaping @MainActor (URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
#endif
