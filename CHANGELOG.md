# Changelog

All notable, user-visible changes are listed here. Dates are ISO 8601.

## [0.3.18] - 2026-09-24

### Fixed

- Encode the authenticate body as an XML plist with Apple's own
  PropertyListSerialization (the same serializer Apple's Configurator
  uses). The form-urlencoded body reached the server but the legacy
  commerce endpoint answered 404; the plist body is what it parses.

## [0.3.17] - 2026-09-24

### Changed

- Log the authenticate response's server identity headers (server,
  x-apple-request-uuid) so the intermittent empty 404 can be tied to the
  Apple edge node that answered.

## [0.3.16] - 2026-09-24

### Changed

- Revert the authenticate body to the form-urlencoded shape with the simple
  attempt counter — the combination that reached two-factor on-device. The
  transient empty-404 retry from 0.3.12 stays in place.

## [0.3.15] - 2026-09-24

### Fixed

- Match the original desktop auth request exactly: attempt "4" (or "2" with
  a two-factor code) and createSession "true" in the plist body. The generic
  attempt counter made Apple answer authenticate with a persistent 404.

## [0.3.14] - 2026-09-24

### Fixed

- Send the authenticate body as an XML plist (the desktop-client format,
  per ipatool) instead of form-urlencoded. Apple answered the misencoded
  body with a persistent empty HTTP 404 at buy.itunes.apple.com.

## [0.3.13] - 2026-09-24

### Changed

- Log the auth endpoint host from the bag so a persistent empty 404 can be
  matched to the pod Apple routed the account to.

## [0.3.12] - 2026-09-24

### Fixed

- Retry the authenticate request when Apple answers with a transient empty
  HTTP 404 (observed immediately after the two-factor prompt). The retry
  reuses the backoff used for rate limiting, so a two-factor code is no
  longer consumed by a failed retry.

## [0.3.11] - 2026-09-24

### Fixed

- Treat an empty-string failureType in Apple's authenticate response as
  absent. The two-factor prompt now appears instead of a sign-in failure
  when Apple sends customerMessage=MZFinance.BadLogin with failureType="".

## [0.3.10] - 2026-09-24

### Changed

- Log the numeric failureType and symbolic customerMessage from Apple's
  authenticate response so account-side rejections (wrong password,
  disabled account, extra verification) are diagnosable from the on-device
  log without a crash report.

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
