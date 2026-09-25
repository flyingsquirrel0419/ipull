# Changelog

All notable, user-visible changes are listed here. Dates are ISO 8601.

## [0.3.38] - 2026-09-25

### Fixed

- The password-stage SAP session is now actually closed before the fresh
  2FA signer is built. v0.3.36 added closeSession() but EmulatedSAPSigner
  never declared the SAPSessionClosing conformance, so the as? cast
  silently failed and the old session stayed open through the 2FA submit.
  A v0.3.37 device trace confirmed the close log line never appeared.
  Look for "closing password-stage SAP session before 2FA signer setup"
  to prove the fix is active.

## [0.3.37] - 2026-09-25

### Changed

- First sign-in no longer downloads the full 1,217 MB Apple update
  package. The four SAP frameworks live in a ~40 MB bzip2 region near
  the end of the package (the same block-boundary offset ipatool uses),
  so the app now issues one HTTP Range request for that window and
  stream-decompresses it, stopping as soon as all four files are
  extracted and digest-verified. First-login data use drops ~30x and the
  mid-download network failures seen on-device (URLError -1005 during
  the 1.2 GB pull) can no longer abort sign-in.

## [0.3.36] - 2026-09-25

### Changed

- The 2FA submit now mirrors ipatool's SAP signer lifecycle exactly: the
  password-stage SAP session is closed before the fresh 2FA signer is
  built. v0.3.34's trace proved the edge also rejects password requests
  on a ~35-minute-old identity (anti-replay freshness), so the remaining
  structural difference from the working reference is that this app ran
  three SAP setup exchanges per flow with the old session left open.
  Only one registered SAP session per machine identity is now live when
  the 2FA request lands.

### Added

- The response log now includes Apple transaction-correlation
  (X-Apple-Trans-*) header names with hashed values, plus Retry-After.
  If password and 2FA responses share a Trans- token, a device trace can
  prove how the edge groups the two stages; if a 404 carries a
  Retry-After, a hidden rate limit stops being invisible.

## [0.3.33] - 2026-09-25

### Changed

- The 2FA submit now waits out the challenge-propagation window before
  the first send: v0.3.32's on-device trace showed a 2FA request sent 8
  seconds after the password response still answered with an empty EDGE
  404 on every retry, while the identical fingerprint reached MZFinance
  on the password stage. Apple edge nodes learn the challenge
  asynchronously, so the submit waits until at least 15 seconds have
  passed since the challenge was issued.

### Fixed

- The fingerprint log now records the User-Agent and Accept headers the
  HTTP client actually attaches (previously it only showed what the auth
  layer itself set, so it printed userAgentPresent=false / accept=nil
  even though the wire request carried them).

## [0.3.32] - 2026-09-25

### Changed

- Auth requests now carry explicit Accept "*/*" and Content-Type on both
  the password and 2FA stages, plus the single constant Configurator
  User-Agent for the whole flow — the exact stable header profile the
  reference client sends.
- The verdict log splits fingerprint matching into passwordVs2FAMatched
  (the two stages of this flow share method, content type, header names,
  UA, and endpoint) and configuratorProfileMatched (POST + Accept */* +
  form content type + UA + ActionSignature + Apple buy-host endpoint).
- signerGeneration now reads 0 for the password stage and 1 for a fresh
  2FA signer, and signerFresh reflects that directly.
- Response classification tightened: 204, a 404 without
  Apple-Originating-System or a request UUID, and a 301 without Location
  are EDGE; only plist/XML bodies, AOS, or request-UUID evidence marks
  MZFINANCE. responseBodyLength is logged with every response.

## [0.3.31] - 2026-09-25

### Changed

- The v0.3.30 experiment proved a fresh SAP signer does not fix the 2FA
  404, so this build runs an exact request-parity experiment instead:
  one request builder shared by both stages, with the payload schema
  (AuthPayloadMode: upstreamParity vs legacyCreateSession) and attempt
  field (AuthAttemptMode: 1 vs 4) driven by a single AuthExperiment
  configuration — identical across the password and 2FA stages of a
  flow, switchable between runs via IPULL_AUTH_PAYLOAD_MODE /
  IPULL_AUTH_ATTEMPT (default Test A: upstreamParity + attempt 1).
- Transport retries now match the reference semantics: at most 3 total
  sends per sign-in (initial + 2 retries, 10s/20s backoff). Logical
  retries that re-signed with increasing attempt values were removed —
  a 404 is a pre-auth transport failure, not a reason to bump attempt.

### Added

- Safe HTTP fingerprint per request: method, scheme, hostname, path,
  content type, content length, sorted header names, cookie names,
  User-Agent hash, actionSignature presence/length, payloadAttempt and
  payloadFieldNames read back from the serialized body, and
  finalBodySHA256 with bodySignatureMatched proof that the exact bytes
  handed to URLSession are the bytes the SAP signer signed.
- A per-run [auth][verdict] line: passwordReachedMZFinance,
  twoFAReachedMZFinance, status, payloadMode, payloadAttempt,
  signerFresh, sameGUID/sameMachineID, cookieNames, and
  bodySignatureMatched. If a 2FA variant ends in an EDGE 404 with all
  parity checks true, the trace supports the
  LEGACY_MZFINANCE_2FA_EDGE_REJECTED verdict.

## [0.3.30] - 2026-09-25

### Changed

- 2FA submissions now sign with a FRESH SAP signer built on the same
  persistent machine identity (GUID/machineID unchanged, cookies
  preserved), matching the reference flow where a 2FA submit is a new
  Login invocation. This is the on-device experiment that decides whether
  the empty-404 2FA rejections come from signer reuse or from Apple's
  edge/request fingerprinting.
- The response layer classifier is conservative: only a parseable plist,
  an XML content type, Apple-Originating-System, or a request UUID marks
  MZFINANCE; a 302 with a valid Apple pod Location is STORE_POD_REDIRECT;
  a bodyless 204/404/5xx without backend evidence is EDGE. A lone
  x-responding-instance header no longer marks a response as MZFINANCE.
- Request logs now report payloadAttempt and payloadFieldNames read back
  from the serialized body, plus signerGeneration, so the log proves what
  Apple actually receives.
- A fresh password flow resets flow-local routing metadata (podID,
  redirectURL) so a stale pod from an earlier challenge cannot confuse
  diagnostics.

## [0.3.29] - 2026-09-25

### Added

- Send-time endpoint invariant: every authenticate request is validated
  against the Apple authentication host allowlist right before it hits
  the network, so a malformed endpoint (for example a pod ID leaking
  into the host field) can never produce host=20 style requests again.
- Request logs now report podID (metadata) and redirectHost (an actual
  Apple 302 Location) as separate fields instead of one ambiguous value.

## [0.3.28] - 2026-09-25

### Fixed

- Critical: the Pod/itspod response header (a numeric routing identifier
  like "20") was being used as a request hostname, so the 2FA submit went
  to host=20 and timed out (URLError -1001) with zero cookies. Pod
  metadata and the redirect URL are now separate state: the authenticate
  endpoint is the bag's auth endpoint, and only an actual HTTP 302
  Location from Apple may replace it. Apple-provided Location URLs are
  used verbatim and never reconstructed from the pod number.
- Set-Cookie diagnostic no longer comma-splits raw header values (the
  Expires date contains a comma); cookie names now come from Foundation's
  HTTPCookie parser.

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
