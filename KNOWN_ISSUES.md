# Known Limitations

This document describes known limitations of the Shade messaging system.

## Security Limitations

### LOW-01: HSM/Secure Enclave Not Used
- **Description:** Cryptographic keys are stored in software (OS keychain/Keystore), not in hardware security modules (HSM) or Secure Enclave.
- **Impact:** Keys could potentially be extracted from device memory if compromised.
- **Mitigation:** Keys are protected by OS secure storage (iOS Keychain, Android Keystore, Windows DPAPI, macOS Keychain, Linux libsecret).
- **Future:** Consider HSM integration for high-security deployments.
- **Note:** Random.secure() instead of Fortuna — NOT A BUG (confirmed by audit)

### LOW-02: Self-Signed Certificate in Production
- **Status:** FIXED — Server now blocks startup in production if self-signed certificate detected.
- **Mitigation:** Use Let's Encrypt or commercial certificate in production.

### LOW-03: No 2FA for Admin Panel
- **Status:** ROADMAP — TOTP 2FA for admin panel planned for future version.
- **Description:** Admin panel currently has no two-factor authentication.

### LOW-04: Reconnect Throttle
- **Status:** FIXED — Server now throttles reconnect attempts (5s cooldown between disconnect/reconnect from same IP).
- **Description:** Prevents rapid reconnect after disconnect from same IP.

### LOW-05: iOS Screenshot Detection
- **Status:** Platform Limitation (Best Effort)
- **Description:** iOS does not provide native screenshot detection APIs; client uses workarounds that may not be reliable.
- **Mitigation:** Best effort implementation; not guaranteed to work on all iOS versions.
- **Note:** This is an inherent platform limitation.

### MED-09: Firebase Messaging Metadata Exposure
- **Status:** Platform Limitation (Documented in Privacy Policy)
- **Description:** Firebase Cloud Messaging (FCM) may expose metadata to Google.
- **Mitigation:** Documented in privacy policy. Consider self-hosted push or alternative notification services for enhanced privacy.
- **Note:** Messages are encrypted end-to-end; only metadata (sender/recipient IDs) may be visible to Google.

---

## Other Limitations

### LOW-06: Metadata Leakage (Unavoidable for Relay Server)
- **Description:** As a relay server, Shade necessarily knows:
  - Which users are communicating (who contacts whom)
  - When communications occur (timing)
  - Message size (encrypted, but observable)
- **Impact:** Traffic analysis can reveal communication patterns.
- **Mitigation:** Server stores no message content, only relays encrypted blobs. Consider onion routing for advanced privacy.
- **Note:** This is inherent to relay architecture and cannot be fully eliminated.

### LOW-07: No Perfect Forward Secrecy (PFS)
- **Description:** Session keys are derived from long-term identity keys. Compromise of a long-term key can decrypt past messages if key material was captured.
- **Impact:** If identity key is compromised, historical messages may be decryptable.
- **Mitigation:** Use ephemeral session keys via Double Ratchet algorithm.
- **Roadmap:** Double Ratchet protocol planned for future version.

### LOW-08: No Post-Quantum Cryptography
- **Description:** Currently uses RSA-4096 and AES-256-GCM, which are vulnerable to quantum computing attacks (Shor's algorithm).
- **Impact:** Messages may be decryptable once quantum computers become sufficient.
- **Mitigation:** Current algorithms are considered secure against classical computers.
- **Roadmap:** Post-quantum algorithms (Kyber, Dilithium) planned for future version.

## Implementation Notes

- **SQLCipher:** Database encryption enabled on all platforms (MED-03)
- **Rate Limiting:** Applied to prevent abuse
- **HSTS:** Preload enabled for all HTTPS connections
- **CSP:** Strict content security policy enforced

## Reporting Security Issues

For security vulnerabilities, please contact the maintainers through appropriate channels.