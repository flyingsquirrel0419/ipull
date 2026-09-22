# Contributing to iPull

Thanks for helping. This file covers setup, the change workflow, and the
checks your PR must pass.

## Where to start

- Bugs: use the **Bug Report** issue template.
- Ideas: use the **Feature Request** template — describe the problem, not
  the implementation.
- Security issues: **do not open a public issue.** Follow
  [SECURITY.md](SECURITY.md).

## Setup

```bash
git clone https://github.com/flyingsquirrel0419/ipull.git
cd ipull
brew install xcodegen   # macOS only, for the app targets
xcodegen
open iPull.xcodeproj
```

The protocol layer (`Packages/AppStoreCore`) builds and tests on Linux too:

```bash
swift test --package-path Packages/AppStoreCore
```

## Scope rules

iPull downloads App Store packages for apps on the user's own Apple
Account. PRs that add DRM circumvention, IPA decryption, signing,
injection, or third-party redistribution will not be merged. PRs that
improve protocol robustness, download reliability, UX, tests, or docs are
welcome.

## Checks before opening a PR

1. `swift test --package-path Packages/AppStoreCore` — must pass.
2. If you touched the app targets: `xcodebuild build -project iPull.xcodeproj
   -scheme iPull -destination 'generic/platform=iOS Simulator'
   CODE_SIGNING_ALLOWED=NO` — must succeed (this is what CI runs).
3. Never log credentials, tokens, DSIDs, or full signed URLs. Route log
   lines through `Log` (redacting logger) and keep user-facing messages in
   `AppStoreError.userMessage`.
4. Keep the protocol layer UI-free: no SwiftUI/UIKit imports inside
   `Packages/AppStoreCore` (guard platform-specific imports with
   `#if canImport(...)`).

## PR expectations

Fill in the PR template honestly — state what you ran, not what you meant
to run. Include before/after behavior for user-visible changes. Small,
focused PRs get reviewed faster than sweeping ones.
