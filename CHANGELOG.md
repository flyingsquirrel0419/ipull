# Changelog

All notable, user-visible changes are listed here. Dates are ISO 8601.

## [0.3.9] - 2026-09-24

### Added

- Record uncaught exceptions and fatal signals in the on-device log file.
  LiveContainer terminates the app without a crash report, so the log now
  captures the reason when the two-factor prompt (or anything else) kills
  the process. Log lines mark each step of the two-factor handoff.

## [0.3.8] - 2026-09-24

### Fixed

- Send X-Apple-ActionSignature base64-encoded (as Apple's client expects)
  instead of hex. authenticate no longer fails with HTTP 403 and an empty
  body after the SAP session establishes.

## [0.3.7] - 2026-09-24

### Fixed

- Build the SAP emulator (Unicorn) in TCG interpreter mode so guest signing
  code no longer needs executable memory. Sign-in no longer exits at
  "SAP entering guest initialization" when running under LiveContainer
  without JIT enabled.

## [0.3.6] - 2026-09-24

### Changed

- Reduce SAP emulator scratch and heap mappings from 96 MB to 40 MB to lower
  sign-in memory use in LiveContainer.
- Log image loading and guest initialization stages to locate an unexpected
  process exit without requiring an iPull crash report.

## [0.3.5] - 2026-09-24

### Changed

- Summarize deferred SAP imports in one diagnostic line instead of logging
  every unused import as an error. Log a specific symbol if it is called.
- Verify real-package extraction, Apple SAP setup, and request signing in
  an opt-in integration test.

## [0.3.4] - 2026-09-24

### Fixed

- Read Apple's real XAR file entries and extract sign-in binaries from the
  bzip2-compressed Payload member.
- Stream CPIO extraction and keep only the four required binaries in memory,
  avoiding a multi-gigabyte temporary file after download.

## [0.3.3] - 2026-09-24

### Fixed

- Download first sign-in assets in small verified ranges, retrying stalled
  ranges without restarting the entire package.
- Show connection wait time before the first bytes arrive and retry idle
  range requests sooner.

## [0.3.2] - 2026-09-24

### Changed

- Show each Apple Account sign-in stage, including service configuration,
  certificate retrieval, signer setup, authentication, rate-limit retry,
  and secure session saving. Asset download retains its progress and ETA.

## [0.3.1] - 2026-09-24

### Changed

- Show Apple sign-in asset download progress, downloaded size, and estimated
  remaining time during the first sign-in.
- Combine progress from both download parts and show asset preparation after
  the transfer completes.

## [0.3.0] - 2026-09-24

### Changed

- Reworked Apple Account sign-in and verification screens with clearer progress,
  errors, privacy guidance, and account status.
- Preserved credentials across the trusted-device code step so two-factor sign-in
  can complete, then cleared them when the flow ends.
- Added bounded retries for Apple's rate-limit responses and removed expired
  session tokens from the Keychain.
- Reduced authentication logging of response details and signing errors.

## [1.0.0] - 2026-09-23

### Added

- Apple Account sign-in with 2FA; session persisted in the iOS Keychain
  (device-bound, AfterFirstUnlockThisDeviceOnly)
- App resolution by App Store URL, numeric App ID, Bundle ID, and name
  search (public iTunes Search API)
- Share Extension: App Store / Safari → Share → iPull → App Detail via
  App Group handoff and `ipull://resolve` deep link
- Version browser: latest + historical versions via external version IDs,
  with on-demand display-name resolution
- IPA downloads: queue, progress, speed, cancel, retry with resume data,
  background URLSession, restart recovery
- Library (SwiftData): streaming SHA-256, share sheet, Save to Files,
  rename, delete, duplicate detection, storage usage
- Purchased apps listing (best effort; private endpoint)
- CI: GitHub Actions macOS pipeline producing an unsigned IPA artifact
  plus AppStoreCore unit tests (43 tests)

### Security

- Passwords are never persisted; session secrets are Keychain-only; logs
  pass through a redacting logger.
