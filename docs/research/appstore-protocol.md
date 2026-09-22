# App Store Protocol Research Notes (iPull 1.0)

Date: 2026-09-23

## Sources reviewed

- majd/ipatool (Go CLI, MIT License) — cloned and read at v2 HEAD, September 2026.
  License: MIT. We reuse protocol *behavior/knowledge* only; all Swift code in
  this repository is an original clean implementation. MIT attribution kept in
  NOTICES because endpoint/field knowledge derives from that codebase.
- AhmedBafkir/DLiPA (iOS app) — repository contains README + screenshots only, no
  source code published. Used as a product reference (features: storefront
  selection, search by name/bundle/link, older-version download via version ID).
  No code copied.
- Public iTunes Search API documentation (affiliate resources), used for
  unauthenticated lookup/search endpoints.

## Protocol summary (as implemented in AppStoreCore)

### Bag
`GET https://init.itunes.apple.com/bag.xml?guid=<GUID>` returns a plist with
`urlBag` keys:

- `authenticateAccount` — auth endpoint (must be buy.itunes.apple.com or
  *-buy.itunes.apple.com)
- `sign-sap-setup`, `sign-sap-setup-cert`, `sign-sap-version` — SAP
  (Signature Auth Protocol) setup endpoints; version 200 supported by ipatool
- `redownloadProduct`, `updateProduct` — fallback download endpoints

GUID derivation (desktop tooling): MAC address → uppercase hex, no separators.
iPull on iOS cannot read a MAC address; we derive a stable per-device GUID from
`identifierForVendor` (stored in Keychain), formatted as 12 uppercase hex
chars, matching the shape Apple expects.

### Authentication (SAP-protected)
`POST <bag authenticateAccount>` with form-urlencoded body containing a plist
structure:

    appleId, password (+6-digit 2FA code appended), guid, attempt, rmp=0, why=signIn

Requests are signed with `X-Apple-ActionSignature` produced by the SAP
handshake (setup cert + buffer exchange, then per-request signature).
Response plist contains `dsPersonId` (DSID), `passwordToken`,
`accountInfo.appleId`, `accountInfo.address`. Response headers carry
`X-Set-Apple-Store-Front` (e.g. "143466-1,29") and `pod`.

2FA: first attempt without a code returns
`customerMessage = MZFinance.BadLogin.Configurator_message` → prompt user,
retry with code appended to the password.

Failure types observed: -5000 invalid credentials (retry once with attempt=2),
2034 password token expired, 2042 sign-in required, 1008 device verification
failed, 5002 license already exists, 9610 license not found, 2059 temporarily
unavailable. customerMessage "Your account is disabled." / "Your password has
changed." / "Subscription Required" map to dedicated errors.

### Lookup / Search (unauthenticated)
`GET https://itunes.apple.com/lookup?bundleId=<bundle>&country=<CC>&entity=software&limit=1&media=software`
`GET https://itunes.apple.com/search?term=<q>&country=<CC>&entity=software&media=software&limit=<n>`

Country code is derived from the storefront prefix (e.g. 143466 → KR,
143441 → US). Full table embedded in Storefront.swift (from ipatool's
storefront.go, MIT).

### Version history
`POST <pod-prefix?>buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=<guid>`
headers: `iCloud-DSID`, `X-Dsid`, Content-Type application/x-apple-plist.
Body plist: `creditDisplay`, `guid`, `salableAdamId`, `serialNumber=0`,
optionally `externalVersionId` (volumeStore) / `appExtVrsId` (redownload).

The item metadata returns `softwareVersionExternalIdentifiers` (full list of
downloadable version IDs) and `softwareVersionExternalIdentifier` (latest).
Fallback chain used by ipatool and mirrored here:
volumeStoreDownloadProduct → bag `redownloadProduct` (/r/redownload)
→ bag `updateProduct` (/up/updateProduct).

Display version + release date for a given externalVersionId are resolved by
requesting a download for that version and reading the item metadata
(bundleShortVersionString / release date fields).

### Purchase (free apps only)
`POST <pod>buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct`
headers include `X-Token: <passwordToken>`, `X-Apple-Store-Front`, DSID
headers. Body: appExtVrsId=0, salableAdamId, price=0, pricingParameters=STDQ
(fallback GAME for Arcade), productType=C, guid, etc. Paid apps (price > 0) are
refused — iPull never attempts to acquire paid licenses.

### Download
The downloadProduct response item contains the CDN URL(s); the IPA is streamed
from Apple's CDN to disk. No iPull server is involved at any point.

## On-device feasibility

## Live verification performed 2026-09-23 (from this build environment)

- `GET itunes.apple.com/lookup?bundleId=com.burbn.instagram&country=kr` →
  200, returns trackId 389801252 / bundleId / current version. PASS.
- `GET itunes.apple.com/search?term=discord&country=kr` → 200, ranked
  results with trackId/bundleId. PASS.
- `GET init.itunes.apple.com/bag.xml?guid=...` — **current bag no longer
  exposes `urlBag.authenticateAccount` / `sign-sap-*` keys** without
  specific client identity headers (tested with Configurator UA and
  X-Apple-Store-Front). AppStoreCore therefore falls back to the
  documented default hosts (buy.itunes.apple.com authenticate, and the
  historically used play.itunes.apple.com signSapSetup endpoints) when the
  bag omits them, and still validates hosts before use. This fallback path
  requires on-device verification — tracked as R1/R4 in docs/risks.md.

DLiPA proves this flow can run on a non-jailbroken iPhone. The SAP signing
handshake is the hardest part on-device; ipatool performs it with an embedded
runtime. iPull's SAPSigner is structured so the handshake
(cert fetch → setup exchange → per-request signature) is isolated behind a
protocol; the transport and message formats are implemented in Swift. See
docs/risks.md for the residual risk around the signature primitive.
