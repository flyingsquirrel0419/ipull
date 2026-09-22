import UIKit
import UniformTypeIdentifiers

/// Share Extension: receives an App Store URL from App Store / Safari,
/// stores it in the App Group, then opens the main app which routes to the
/// App Detail screen. No network work happens in the extension.
final class ShareViewController: UIViewController {

    private static let groupIdentifier = "group.com.ipull.app"
    private static let sharedURLKey = "pending-appstore-url"

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleIncoming()
    }

    private func handleIncoming() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments
        else {
            complete()
            return
        }

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
                    if let url = value as? URL {
                        self?.storeAndOpen(url.absoluteString)
                    } else {
                        self?.complete()
                    }
                }
                return
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] value, _ in
                    if let text = value as? String {
                        self?.storeAndOpen(text)
                    } else {
                        self?.complete()
                    }
                }
                return
            }
        }
        complete()
    }

    private func storeAndOpen(_ urlString: String) {
        // Only App Store links are meaningful; let the main app validate.
        UserDefaults(suiteName: Self.groupIdentifier)?.set(urlString, forKey: Self.sharedURLKey)

        // Open the host app via its custom scheme. Extensions can't call
        // UIApplication.open directly; the responder-chain approach is the
        // established pattern.
        guard let deepLink = URL(string: "ipull://resolve") else {
            complete()
            return
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(deepLink)
                complete()
                return
            }
            responder = current.next
        }
        // Fallback: selector-based open for older runtimes.
        let selector = NSSelectorFromString("openURL:")
        responder = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: deepLink)
                break
            }
            responder = current.next
        }
        complete()
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
