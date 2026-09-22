# Known Limitations (1.0)

1. **SAP signing on device.** The SAP handshake is implemented per the
   documented message exchange; the proprietary signing primitive is
   approximated with HMAC-SHA-256 over the setup-derived session key. If
   Apple rejects the signature, sign-in fails with a typed error — see
   docs/risks.md R1. This is the one component that cannot be fully
   verified without an on-device account test, and is the first item on
   the release-verification checklist.
2. **Paid apps are never acquired.** Buy them in the App Store first; then
   iPull can list versions and download.
3. **Version display names** for older versions are resolved on demand
   (first five eagerly, rest when selected) because Apple only exposes
   them through per-version download requests.
4. **Purchased list** depends on a private Apple endpoint that has
   historically drifted; failure shows a graceful empty state and does
   not affect any other feature.
5. **Background downloads** require the system to schedule them; force-
   quitting the app cancels them (standard iOS behavior). Resume data is
   kept and used on retry where the CDN supports ranges.
6. **Storefront changes** (moving countries) require sign-out/in for the
   new storefront to take effect for version listing.
7. **iPad layout** works but is not optimized in 1.0.
