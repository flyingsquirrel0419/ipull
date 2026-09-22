# Security Policy

## Scope

iPull handles Apple Account credentials and session tokens on-device. This
document states what iPull does with them and how to report problems.

## Credential handling

- The Apple Account **password is never persisted** — it exists only in
  memory for the duration of a sign-in attempt, and the field is cleared
  after each attempt.
- The **session token** (passwordToken), DSID and storefront are stored in
  the iOS **Keychain** with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-bound and
  excluded from backups and device migration.
- There is **no iPull backend**. Credentials and tokens go only to Apple
  endpoints over TLS. Nothing is proxied, logged remotely, or sent to
  analytics.
- Debug logging routes through a redacting logger that strips tokens,
  passwords and DSID values before emission.
- `AppleAccountSession` redacts the token from `description` /
  `debugDescription` so it cannot leak via string interpolation.

## Out of scope (by design)

iPull does not bypass FairPlay DRM, decrypt IPAs, sign apps, inject code,
or redistribute packages. Vulnerabilities in those areas cannot exist
because the features do not.

## Reporting a vulnerability

**Do not open a public issue for credential- or protocol-level
vulnerabilities.**

Use GitHub's **private vulnerability reporting** on this repository
(Security tab → "Report a vulnerability"). Include:

- Affected version or commit
- Impact and reproduction steps
- Sanitized evidence — **never include your credentials, 2FA codes,
  session tokens, or full signed URLs**

If private reporting is unavailable, open a minimal public issue that
states only that a security issue exists and requests a private contact —
no details, no exploit description.

General hardening suggestions are welcome as normal feature requests.
