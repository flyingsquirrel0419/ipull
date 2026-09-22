# Device Verification Checklist (run on macOS + physical iPhone)

Prereqs: Xcode 15.4+, iOS 17+ device, an Apple Account with 2FA enabled.

1. `brew install xcodegen && xcodegen` → open iPull.xcodeproj
2. Set your development team on both targets; keep bundle IDs
   (com.ipull.app / com.ipull.app.share) or change both plus the App Group.
3. Build & run on device.
4. Settings → Apple Account → sign in → expect 2FA prompt → enter code.
   - If sign-in fails with "Authentication failed" twice, capture (without
     credentials) whether the SAP setup exchange returned buffers — that
     isolates R1.
5. Home → paste https://apps.apple.com/kr/app/discord/id985746746 →
   App Detail loads.
6. Versions load; pick an older version → Download.
7. Background the app mid-download; return; confirm progress/completion.
8. Kill the app mid-download; relaunch; confirm state recovery + retry.
9. Library → SHA-256 present; Share → Save to Files.
10. App Store app → Discord page → Share → iPull → App Detail opens.
11. Sign out; relaunch; confirm no session and no Keychain residue.

Record results in VERIFICATION.md.
