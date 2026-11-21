import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shade/core/services/tls_policy.dart';

/// Bounded avatar uploads over the existing authenticated JSON API.
class ProfileUploadTransport {
  final Uri relay;
  final String certificateDigest;
  final Set<HttpClient> _active = {};
  ProfileUploadTransport(this.relay, this.certificateDigest);

  Future<http.Response> send(http.Request request,
      {Duration timeout = const Duration(seconds: 45)}) async {
    if (request.url.scheme != 'https' || request.url.origin != relay.origin) {
      throw ArgumentError('Profile uploads require the configured HTTPS relay');
    }
    final client = ShadeHttpOverrides(relay, certificateDigest)
        .createHttpClient(null)
      ..connectionTimeout = const Duration(seconds: 15);
    _active.add(client);
    try {
      return await _send(client, request).timeout(timeout);
    } finally {
      // Future.timeout alone leaves the HTTP upload running. Close its socket
      // on success, failure, timeout and account/service cancellation.
      _active.remove(client);
      client.close(force: true);
    }
  }

  Future<http.Response> _send(HttpClient client, http.Request request) async {
    final outgoing = await client.openUrl(request.method, request.url);
    outgoing.followRedirects = false;
    outgoing.bufferOutput = true;
    request.headers.forEach((name, value) {
      if (name.toLowerCase() != 'content-length' &&
          name.toLowerCase() != 'host') {
        outgoing.headers.set(name, value);
      }
    });
    outgoing.headers.set(HttpHeaders.connectionHeader, 'close');
    await outgoing.addStream(request.finalize());
    final response = await outgoing.close();
    final headers = <String, String>{};
    response.headers
        .forEach((name, values) => headers[name] = values.join(','));
    return http.Response.fromStream(http.StreamedResponse(
        response, response.statusCode,
        headers: headers, request: request));
  }

  void cancelAll() {
    for (final client in _active.toList()) {
      client.close(force: true);
    }
    _active.clear();
  }
}
