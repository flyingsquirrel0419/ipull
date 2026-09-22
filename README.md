# iPull

**App Store link → choose a version → download the IPA using your own Apple Account.**

iPull is an on-device utility for iOS 17+. You share an App Store page to
iPull, pick a version, and iPull downloads the IPA package directly from
Apple's servers into a managed library on your iPhone. From there you can
share it, save it to Files, or verify its SHA-256.

iPull is **not an installer**. It does not sign, inject, patch, decrypt, or
bypass FairPlay DRM. It only downloads packages for apps your own Apple
Account has access to (free apps can be acquired inside the app; paid apps
must be purchased in the App Store first).

## Architecture

```
iPhone
 │
 ├─ iPull (SwiftUI + SwiftData)
 │    └─ Packages/AppStoreCore (Swift package, protocol layer)
 ├─ Apple authentication services
 ├─ App Store services
 └─ Apple CDN → IPA
```

**There is no iPull server.** Credentials go only to Apple. The password is
never persisted; the session token lives in the iOS Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

## Features (1.0)

- Apple Account sign-in with 2FA, session persisted across launches
- App resolution: App Store URL / numeric App ID / Bundle ID / name search
- App Store search with icons, developer, bundle ID
- Share Extension: App Store / Safari → Share → iPull → App Detail
- Version browser: latest + historical versions via external version IDs
- IPA download: queue, progress, speed, cancel, retry with resume data,
  background URLSession, restart recovery
- Library: SwiftData-tracked downloads with streaming SHA-256, share sheet,
  Files export, rename, delete, duplicate detection, storage usage
- Purchased: lists apps previously acquired on the account (best effort —
  Apple endpoint stability varies; degrades gracefully)

## Build

Requires Xcode 15.4+ and an iOS 17 SDK.

```bash
# Generate the Xcode project (XcodeGen):
brew install xcodegen
xcodegen

# Or open the package tests directly:
cd Packages/AppStoreCore && swift test
```

Open `iPull.xcodeproj`, select the iPull scheme, sign with your team, run
on a device.

## Protocol notes & research

See [docs/research/appstore-protocol.md](docs/research/appstore-protocol.md)
for the documented endpoints, auth flow, version-listing and download
fallback chain this implementation follows, and
[docs/risks.md](docs/risks.md) for the technical risk register. Protocol
behavior was studied from [majd/ipatool](https://github.com/majd/ipatool)
(MIT) and the DLiPA project (README only); all Swift code here is an
original implementation. See [NOTICES](NOTICES).

## Legal

iPull downloads apps **you own or can acquire for free** under your own
Apple Account. You are responsible for complying with Apple's terms and
applicable law. Downloading paid apps you haven't purchased is not
supported and not implemented.

## License

[MIT](LICENSE)
