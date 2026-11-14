import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Platform CA validation stays enabled. The only exception is an explicitly
/// configured DER certificate digest for the configured relay host and port.
class ShadeHttpOverrides extends HttpOverrides {
  final Uri relay;
  final String certificateDigest;
  ShadeHttpOverrides(this.relay, this.certificateDigest);

  bool acceptsUntrustedCertificate(
          X509Certificate certificate, String host, int port) =>
      certificateDigest.isNotEmpty &&
      host == relay.host &&
      port == relay.port &&
      base64Encode(sha256.convert(certificate.der).bytes) == certificateDigest;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = acceptsUntrustedCertificate;
    return client;
  }
}
