# iPull

**App Store link → choose a version → download the IPA with your own Apple Account.**

iPull is an on-device utility for iOS 17+. Share an App Store page to
iPull, pick a version, and iPull downloads the IPA package straight from
Apple's servers into a managed library on your iPhone. From there you can
share it, save it to Files, or verify its SHA-256.

![Build](https://github.com/flyingsquirrel0419/ipull/actions/workflows/build.yml/badge.svg)

> iPull is **not an installer**. It does not sign, inject, patch, decrypt,
> or bypass FairPlay DRM. It only downloads packages for apps your own
> Apple Account can access — free apps can be acquired in-app; paid apps
> must be purchased in the App Store first.

## Contents

- [How it works](#how-it-works)
- [Features](#features-10)
- [Install](#install)
  - [From CI artifact](#from-ci-artifact-no-mac-required)
  - [Build from source](#build-from-source-macos--xcode)
- [Usage](#usage)
- [Privacy & security](#privacy--security)
- [Protocol research](#protocol-research)
- [Known limitations](#known-limitations)
- [Contributing](#contributing)
- [License](#license)

## How it works

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

| Area | What you get |
| --- | --- |
| Account | Apple Account sign-in with 2FA, session persisted across launches, storefront detection, sign out |
| Resolve apps | App Store URL, numeric App ID, Bundle ID, or name search |
| Search | Icon, name, developer, App ID, Bundle ID, detail screen |
| Share Extension | App Store / Safari → Share → iPull → App Detail |
| Versions | Latest + historical versions via external version IDs, release dates where available |
| Downloads | Queue, progress, speed, cancel, retry with resume data, background session, restart recovery |
| Library | SwiftData-tracked downloads, streaming SHA-256, share sheet, Save to Files, rename, delete, duplicate detection, storage usage |
| Purchased | Apps previously acquired on the account (best effort — Apple endpoint stability varies) |

## Install

### From CI artifact (no Mac required)

The repo ships a ready CI workflow at [ci/build.yml](ci/build.yml). To
enable it, add it once via the GitHub web UI (workflow files under
`.github/workflows/` require extra token scope, so some git clients can't
push them):

1. Open the repo on GitHub → **Add file** → **Create new file**.
2. Name it `.github/workflows/build.yml` and paste the contents of
   [ci/build.yml](ci/build.yml).
3. Commit directly to `main`.

From then on, every push to `main` builds an **unsigned**
`iPull-unsigned.ipa` on a macOS runner. Download it from the
[Actions](https://github.com/flyingsquirrel0419/ipull/actions) tab and
install it with your preferred sideloading tool (AltStore, SideStore,
Sideloadly, …). Sideloading re-signs the app with your own certificate —
that step happens in the sideloading tool, not in iPull.

### Build from source (macOS + Xcode)

Requires Xcode 15.4+ with the iOS 17 SDK.

```bash
git clone https://github.com/flyingsquirrel0419/ipull.git
cd ipull
brew install xcodegen
xcodegen
open iPull.xcodeproj
```

Select the **iPull** scheme, set your development team on both targets,
and run on a device. The App Group (`group.com.ipull.app`) is required by
the Share Extension; Xcode registers it automatically for most teams.

Run the core package tests on any platform with a Swift 6 toolchain:

```bash
swift test --package-path Packages/AppStoreCore
```

## Usage

1. Open iPull → Settings → Apple Account → sign in (2FA supported).
2. In the App Store app, open an app's page → **Share** → **iPull**.
3. iPull shows the app detail screen with the version list.
4. Pick a version → **Download**. Track progress on the Downloads tab.
5. When it finishes, find the IPA in **Library** → Share, Save to Files,
   or verify its SHA-256.

You can also paste an App Store link, App ID, or Bundle ID directly on the
Home tab, or search by name on the Search tab.

## Privacy & security

- No backend. All traffic goes to Apple hosts over TLS.
- The password exists only in memory during sign-in and is cleared
  afterwards. Only the session token is persisted, in the Keychain,
  device-bound.
- Logs route through a redacting logger that strips tokens, passwords and
  DSIDs; session objects redact the token from their descriptions.
- Details and disclosure policy: [SECURITY.md](SECURITY.md).

## Protocol research

The implementation follows documented App Store protocol behavior studied
from [majd/ipatool](https://github.com/majd/ipatool) (MIT) and the DLiPA
project (README only). All Swift code here is an original implementation —
see [docs/research/appstore-protocol.md](docs/research/appstore-protocol.md)
for endpoints, flows and live-verification notes,
[docs/risks.md](docs/risks.md) for the risk register, and
[NOTICES](NOTICES) for attribution.

## Known limitations

See [docs/known-limitations.md](docs/known-limitations.md). The headline
items: SAP request signing and device-bound GUIDs need on-device
verification (first login is the gate); paid apps are never acquired; the
purchased-apps endpoint is private and may drift; iPad layout works but is
not optimized.

Device verification progress is tracked in [VERIFICATION.md](VERIFICATION.md)
with a step-by-step checklist in
[docs/device-verification-checklist.md](docs/device-verification-checklist.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and feature requests go
through the issue templates; security reports follow
[SECURITY.md](SECURITY.md) — please don't file credential- or
protocol-level vulnerabilities as public issues.

## License

[MIT](LICENSE). Third-party acknowledgements: [NOTICES](NOTICES).
