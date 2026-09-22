# iPull 1.0 — Technical Risk Register (Phase 0 output)

Ranked by impact on the critical path (Apple Account → IPA download).

## R1 — SAP request signing on-device (CRITICAL)
Authentication requires the SAP (Signature Auth Protocol) handshake:
bag → sign-sap-setup-cert → sign-sap-setup-buffer exchange → per-request
`X-Apple-ActionSignature`. ipatool implements this with an embedded
runtime (Unicorn) executing Apple's own signing code. On iOS this must be
reimplemented or adapted in Swift/C. iPull isolates it behind
`SAPSigning` so transport, retries and UI are fully testable without it,
but a wrong signature means login fails with HTTP-level errors.
Mitigation: protocol-typed signer, message formats implemented from the
documented exchange, on-device verification step in Account settings
(Phase 0 spike on real hardware required — cannot be done in this Linux
build environment).

## R2 — GUID / device identity
Apple expects a machine GUID derived from hardware address. iOS exposes no
MAC. We use a Keychain-persisted identifierForVendor-derived 12-hex GUID.
Risk: Apple may reject unfamiliar GUID shapes or flag them.
Mitigation: error surfaced as typed `authenticationFailed`; documented.

## R3 — Version list availability
`softwareVersionExternalIdentifiers` requires a valid license
(failureType 9610 otherwise) and a live passwordToken (2034 otherwise).
Unpurchased free apps must be acquired (buyProduct) first.

## R4 — Endpoint rotation / bag changes
Apple rotates pods and can change bag keys. Mitigation: bag is fetched at
runtime, never hardcoded; endpoints validated (https + expected hosts).

## R5 — Large file handling on device
IPAs up to several GB. Mitigation: URLSessionDownloadTask streaming to
disk, resumable data kept for retry, streaming SHA-256 (no full-file RAM).

## R6 — Background downloads
Background URLSession requires the app to be re-launched by the system and
state restored. Mitigation: session identifier persisted; restore handler
in AppEnvironment; fallback to foreground session with warnings.

## R7 — Account lockout risk
Bad SAP signatures or repeated failed auth can lock an Apple Account.
Mitigation: strict retry budget (matches documented attempt semantics),
rate-limit (429) handling with Retry-After, no credential logging.

## R8 — Purchased-library endpoint drift
Owned-apps listing uses private purchase DAAP endpoints; historically
unstable. Mitigation: feature-flagged; failure degrades to manual
search-only mode; findings documented in Verification Report.

## Environment limitation (this build machine)
This repository was authored on a Linux CI-like machine without Xcode.
SwiftPM core tests run with a Linux Swift toolchain where frameworks
permit; Xcode-only targets (SwiftUI app, Share Extension, SwiftData,
Keychain on-device) are compile-verified on macOS/Xcode and a physical
iPhone as part of release verification — tracked in VERIFICATION.md.
