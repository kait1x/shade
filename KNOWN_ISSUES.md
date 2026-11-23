# Known limitations — verified status, 2026-11-23 (v2 Release)

See [historical audit fixes](docs/archive/AUDIT_FIXES_2026-11-14.md) for past checks.

### Features Implemented in v2:
- **Multi-device pairing & recovery:** Multiple devices per account, trusted-device authorization, and offline encrypted recovery are implemented and verified.
- **Voice messages & location sharing:** Encrypted voice notes (with audio recording/playback progress) and offline world map location previews are supported in both Android and Web/PWA clients.
- **Media & stickers:** Batch media uploads, compressed photo sharing, profile avatars, and vinyl sticker collections are functional.

### Architectural Limitations:
- **Group chats & calls:** Group chats, 1-on-1 audio/video calls are currently disabled rather than exposing unfinished protocols.
- **Key exchange:** Uses device-bound RSA-4096 + AES-256-GCM session keys. Double Ratchet / PFS (signal-style ratchet) and independent peer safety-number QR verification are planned for future major releases.
- **Relay metadata:** The server relay routes encrypted envelopes and enforces access control, but learns timing, envelope sizes, and participant identifiers.
- **iOS screenshot protection:** iOS cannot enforce `FLAG_SECURE` like Android; app-switcher and recording privacy on iOS remains best-effort.
- **Durable retention:** Relay queue deduplication and retention are bounded (7 days) with explicit fail-closed storage semantics.
