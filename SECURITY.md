# Security Policy

## Scope

iPull handles Apple Account credentials and session tokens. This document
states what iPull does with them and how to report problems.

## Credential handling

- The Apple Account **password is never persisted** — it lives only in
  memory for the duration of a sign-in attempt, and the password field is
  cleared after each attempt.
- The resulting **session token** (passwordToken), DSID and storefront are
  stored in the iOS **Keychain** with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-bound,
  excluded from backups and device migrations.
- There is **no iPull backend**. Credentials and tokens are sent only to
  Apple endpoints over TLS. Nothing is proxied, logged remotely, or shared
  with analytics.
- Debug logging routes through a redacting logger that strips tokens,
  passwords and DSID values before emission.
- `AppleAccountSession` redacts the token from `description` /
  `debugDescription` so it cannot leak via string interpolation.

## Out of scope (by design)

iPull does not bypass FairPlay DRM, decrypt IPAs, sign apps, inject code,
or redistribute packages. If you are looking for a vulnerability in those
areas, the feature does not exist.

## Reporting

Open a GitHub issue marked "security" or contact the maintainers privately
via GitHub's private vulnerability reporting for the repository.
Please do not include your own credentials or tokens in any report.
