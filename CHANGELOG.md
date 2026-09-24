# Changelog

All notable, user-visible changes are listed here. Dates are ISO 8601.

## [0.3.27] - 2026-09-25

### Added

- Edge vs backend classification: every authenticate response is tagged
  layer=EDGE / MZFINANCE / STORE_POD from its headers and body, so a
  device log separates "2FA never reached the account backend" from
  "the backend rejected this request" in a single sign-in trace.
- Request logs now carry authLogicalAttempt / transportAttempt /
  identityGeneration separately, plus path, query key names, and safe
  header metadata (pod, itspod, request-UUID presence, Set-Cookie names
  only — never values).
- The 2FA verification now targets the store pod that issued the
  challenge when Apple assigned one (pod response header or a pod
  redirect), instead of always re-hitting the default endpoint.
- 2FA submits run up to 4 logical attempts — each with a freshly built
  body and a fresh SAP signature on the same GUID, machine ID, session,
  cookies, and pod — to test whether a fresh signature escapes the edge
  404 window. No identity rotation ever happens during a 2FA challenge.

## [0.3.26] - 2026-09-25

### Fixed

- A dead two-factor challenge is now discarded on every 2FA failure
  (persistent transient 404/204/5xx, BadLogin on a 2FA submit, or
  failureType 5020): the challenge-bound SAP session is dropped so the
  next sign-in starts a fresh password flow and receives a fresh code
  prompt instead of mixing a new identity with a stale challenge.

### Added

- Structured auth telemetry: every authenticate request/response carries
  a correlation id (AUTH-PW-####/AUTH-2FA-####), stage, host, assigned
  pod, cookie-name presence (never values), and truncated guid/machine
  hashes; redirects log from/to pod hosts; failures end with an
  [auth][failure] diagnostic line (guid/machineID/session/cookie/pod
  preservation flags, retry and rotation counts, cause) so a device log
  separates a 2FA payload-parity problem from a transient Apple edge 404
  without exposing any secret material.

## [0.3.25] - 2026-09-25

### Fixed

- Treat HTTP 204, bodyless 404, 429, and bodyless 5xx from authenticate
  as transient on both the password and 2FA stages, with ipatool's
  10/20/30s backoff on the same GUID and SAP session. These statuses are
  never a wrong-password or wrong-code verdict; a persistent transient on
  a 2FA submit now asks for a fresh code instead of rotating the identity.

### Added

- Secret-free auth telemetry in the debug log: stage (password/2fa),
  attempt, truncated guidHash/machineIDHash, password and combined-field
  lengths, authCodeLength/digitsOnly, and bodySHA256/signedBodySHA256 so
  a device log can prove the signed body is byte-for-byte the sent body
  without exposing any credential material.

## [0.3.24] - 2026-09-25

### Fixed

- Send every authenticate POST on a fresh connection (Connection: close),
  matching ipatool's authentication client which disables keep-alives.
  A reused pooled connection for the 2FA verification was answered with
  an empty 404 by Apple's edge even with the correct request shape,
  cookies, GUID, and SAP session all preserved.
- The sign-in start log now actually interpolates the app version
  (v0.3.23 printed the literal template text).

## [0.3.23] - 2026-09-25

### Fixed

- Submit the two-factor code with the same request shape ipatool uses:
  attempt "1" and no createSession field. Apple answered the previous
  attempt "2" + createSession "true" 2FA submit with an empty 404
  on-device, which either burned the retry budget or (in older builds)
  rotated the GUID mid-challenge and broke verification.
- The sign-in start log now includes the running app version
  (for example "v0.3.23"), so a pasted device log proves which build
  produced it even if LiveContainer keeps loading a cached older bundle
  after a reinstall.

## [0.3.22] - 2026-09-24

### Fixed

- Keep the 2FA verification on the same GUID, SAP session, and cookie jar
  that received the challenge. Rotating the GUID on a 2FA 404 broke the
  challenge binding and made Apple answer failureType 5020 even for a
  correct code; now 2FA 404s retry without rotation and only ask for a
  fresh code after three attempts.
- Use a dedicated URLSession with an explicit cookie storage so the
  mzf_in/itspod cookies set by authenticate survive across sign-in
  attempts (the desktop client's cookie jar equivalent).

## [0.3.21] - 2026-09-24

### Fixed

- Reuse the established SAP session when submitting the two-factor code.
  Creating a new signer started a fresh guest session, so Apple could not
  verify password+code against the original challenge and answered
  failureType 5020 (Did you forget your password?) even for a correct
  code.
- Map failureType 5020 with a code attached to invalidTwoFactorCode so
  the UI asks for a fresh code instead of reporting a password error.

## [0.3.20] - 2026-09-24

### Fixed

- Send the desktop client's authenticate attempt values again: attempt
  "4" for password-only sign-in, "2" with a two-factor code, and
  createSession "true". With the generic 1/2 counter Apple answered a
  correct two-factor code with MZFinance.BadLogin, and every abandoned
  challenge re-flagged the device GUID, which is why each sign-in needed
  a fresh rotation in v0.3.19.

## [0.3.19] - 2026-09-24

### Fixed

- Recover from a persistent empty 404 on authenticate by rotating the
  device GUID once per sign-in: Apple flags the device identity
  server-side after an abandoned two-factor prompt, and a fresh GUID in
  both the SAP signer and the request body is the only app-side recovery.
- Stop the two-factor code field from crashing LiveContainer by dropping
  the oneTimeCode content type (SMS autofill does not apply to
  trusted-device codes); the number pad stays.

### Changed

- Retry backoff for empty-404 and 429 responses now follows the desktop
  client's 10/20/30-second schedule instead of 1/2/4, which hammered
  Apple's edge nodes inside the 404 window.

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
