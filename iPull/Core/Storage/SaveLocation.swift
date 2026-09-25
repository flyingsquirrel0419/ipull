import Foundation
import AppStoreCore

/// Where finished IPAs go. By default iPull asks after each download with
/// the system "Save to Files" sheet; otherwise IPAs stay in iPull's own
/// folder (Files › On My iPhone › iPull).
///
/// The folder-open picker was dropped: on device it browsed but never let a
/// folder be selected. The export sheet needs no folder access at all.
enum SaveLocation {
    private static let askKey = "save-ask-after-download"
    private static let keepKey = "save-keep-library-copy"

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
