# Known limitations — verified status, 2026-11-14

See [audit fixes](docs/AUDIT_FIXES_2026-11-14.md) for fixes and actual checks. The old audit is historical; claims that every security issue was fixed are not a certification.

- Google OAuth and real Firebase push delivery still need cloud/device verification. Current debug build does not contain a Web client ID.
- Debug APK targets the Android emulator host bridge. Configure a reachable HTTPS relay for physical phones.
- Android minimum is API 24 on Flutter 3.38.10; API 23 is not supported by this build.
- Release requires a private signing key and explicit server-key pin. Debug signing is never used for release.
- Android is the verified build target. iOS source changes need Xcode; desktop production SQLCipher is unsupported.
- Server must run on Node >=22. Docker configuration was reviewed, not executed here.
- Encryption keys and history remain on the original installation. Multi-device history transfer/recovery is not implemented.
- Groups are disabled rather than exposing unfinished endpoints. Calls and voice messages are not implemented.
- TLS platform CA validation remains enabled. The optional `TLS_CERT_SHA256` only adds an exception for a configured DER/host/port; it does not replace CA validation or force all CA-signed certificates to match that digest. Server identity uses a separate `SERVER_PUBLIC_KEY_FINGERPRINT`.
- The relay knows participant/timing/size metadata. Key distribution still trusts the verified relay; there is no independent peer safety-number verification, Double Ratchet/PFS or independent security audit.
- iOS cannot generally prevent screenshots like Android FLAG_SECURE; recording/app-switcher privacy is best-effort.
- Durable replay/deduplication retention is 7 days with bounded queues; writes fail explicitly when storage is unavailable/full. Power-loss durability and production load were not verified.
- Deleting local history cannot unsend an already in-flight request. Confirmed server deletion is a separate operation requiring a connection.
- Previously tracked .env files remain in Git history. Rotate any real exposed credentials before deployment; do not blindly change SESSION_SECRET without protecting/migrating encrypted server data.
