import Foundation
import AppStoreCore

/// Where finished IPAs go: a default folder chosen in Settings (written to
/// automatically), else the system "Save to Files" sheet after each
/// download, else iPull's own folder (Files › On My iPhone › iPull).
enum SaveLocation {
    private static let askKey = "save-ask-after-download"
    private static let keepKey = "save-keep-library-copy"
    private static let bookmarkKey = "save-folder-bookmark"

    /// Security-scoped bookmark of the default folder, if one is set.
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
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Copy (or move) a finished IPA into the default folder, replacing a
    /// file of the same name. Returns the written URL.
    @discardableResult
    static func writeToDefaultFolder(_ file: URL, move: Bool) throws -> URL {
        guard let bookmark = defaultBookmark, let folder = resolve(bookmark) else {
            throw AppStoreError.fileWriteFailed
        }
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

    /// Whether a finished download should leave iPull's folder at all.
    static var routesOutsideLibrary: Bool {
        defaultBookmark != nil || askWhereToSave
    }

    /// Show "Save to Files" when a download finishes.
    static var askWhereToSave: Bool {
        get { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: askKey) }
    }

    /// Also keep the IPA in iPull's Library after saving it elsewhere.
    static var keepLibraryCopy: Bool {
        get { UserDefaults.standard.object(forKey: keepKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepKey) }
    }
}

#if canImport(UIKit)
import UIKit

/// Folder chooser for the Settings default. It uses the document-types
/// initializer in open mode: the content-types folder picker browsed on
/// device but its Open button never enabled.
@MainActor
enum FolderChooser {
    private static var active: FilesExporter.Delegate?

    static func present(completion: @escaping @MainActor (URL?) -> Void) {
        guard active == nil, let top = FilesExporter.topViewController() else {
            completion(nil)
            return
        }
        let picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        picker.allowsMultipleSelection = false
        let delegate = FilesExporter.Delegate { url in
            active = nil
            completion(url)
        }
        active = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }
}

/// The system "Save to Files" sheet for one file, presented modally from the
/// top view controller.
@MainActor
enum FilesExporter {
    /// Keeps the delegate alive while the sheet is on screen.
    private static var active: Delegate?

    /// Calls `completion` once with the saved file's URL, or nil when the
    /// user cancelled or nothing could present the sheet.
    static func present(_ file: URL, completion: @escaping @MainActor (URL?) -> Void) {
        guard active == nil, let top = topViewController() else {
            completion(nil)
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.shouldShowFileExtensions = true
        let delegate = Delegate { url in
            active = nil
            completion(url)
        }
        active = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    static func topViewController() -> UIViewController? {
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
        private let completion: @MainActor (URL?) -> Void

        init(completion: @escaping @MainActor (URL?) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(nil)
        }
    }
}
#endif
