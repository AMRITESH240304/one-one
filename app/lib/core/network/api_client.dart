import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:http/http.dart' as http;

import '../../app/app_config.dart';
import '../firebase/firebase_performance_service.dart';

class ApiClient {
  ApiClient({FirebaseAuth? auth, http.Client? httpClient, String? baseUrl})
    : _auth = auth ?? FirebaseAuth.instance,
      _httpClient = httpClient,
      _baseUrl = (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(
        RegExp(r'/$'),
        '',
      );

  static const _requestTimeout = Duration(seconds: 15);

  final FirebaseAuth _auth;
  final http.Client? _httpClient;
  final String _baseUrl;

  Future<Map<String, dynamic>> getJson(String path) async {
    final token = await _auth.currentUser?.getIdToken();
    if (token == null) {
      throw StateError('Cannot call backend before Firebase sign-in.');
    }

    final uri = Uri.parse('$_baseUrl$path');
    final headers = {'authorization': 'Bearer $token'};
    final response = await _tracedRequest(
      url: uri.toString(),
      method: HttpMethod.Get,
      requestPayloadSize: 0,
      send: () => (_httpClient?.get(uri, headers: headers) ??
              http.get(uri, headers: headers))
          .timeout(_requestTimeout),
    );
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final token = await _auth.currentUser?.getIdToken();

    if (token == null) {
      throw StateError('Cannot call backend before Firebase sign-in.');
    }

    final uri = Uri.parse('$_baseUrl$path');
    final headers = {
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
    };
    final encodedBody = jsonEncode(body);
    final response = await _tracedRequest(
      url: uri.toString(),
      method: HttpMethod.Post,
      requestPayloadSize: encodedBody.length,
      send: () => (_httpClient?.post(
                uri,
                headers: headers,
                body: encodedBody,
              ) ??
              http.post(uri, headers: headers, body: encodedBody))
          .timeout(_requestTimeout),
    );

    final responseBody = decodeJsonObject(response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        statusCode: response.statusCode,
        code: responseBody['error']?.toString() ?? 'request_failed',
        message: responseBody['message']?.toString() ?? response.body,
      );
    }

    return responseBody;
  }

  Future<Map<String, dynamic>> deleteJson(String path) async {
    final token = await _auth.currentUser?.getIdToken();
    if (token == null) {
      throw StateError('Cannot call backend before Firebase sign-in.');
    }

    final uri = Uri.parse('$_baseUrl$path');
    final headers = {'authorization': 'Bearer $token'};
    final response = await _tracedRequest(
      url: uri.toString(),
      method: HttpMethod.Delete,
      requestPayloadSize: 0,
      send: () => (_httpClient?.delete(uri, headers: headers) ??
              http.delete(uri, headers: headers))
          .timeout(_requestTimeout),
    );
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> postBytes(
    String path,
    List<int> bytes, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async {
    final token = await _auth.currentUser?.getIdToken();
    if (token == null) {
      throw StateError('Cannot call backend before Firebase sign-in.');
    }

    final uri = Uri.parse('$_baseUrl$path');
    // Copy caller headers — default is `const {}` and http may write in place.
    final requestHeaders = {
      'authorization': 'Bearer $token',
      'content-type': contentType,
      ...Map<String, String>.of(headers),
    };
    final response = await _tracedRequest(
      url: uri.toString(),
      method: HttpMethod.Post,
      requestPayloadSize: bytes.length,
      send: () => (_httpClient?.post(
                uri,
                headers: requestHeaders,
                body: bytes,
              ) ??
              http.post(uri, headers: requestHeaders, body: bytes))
          .timeout(_requestTimeout),
    );
    final responseBody = decodeJsonObject(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        statusCode: response.statusCode,
        code: responseBody['error']?.toString() ?? 'request_failed',
        message: responseBody['message']?.toString() ?? response.body,
      );
    }
    return responseBody;
  }

  /// PUT bytes to an absolute URL (e.g. Cloud Storage signed write URL).
  /// Does not attach Firebase Auth — the signed URL is the credential.
  Future<void> putBytesToUrl(
    String absoluteUrl,
    List<int> bytes, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    final uri = Uri.parse(absoluteUrl);
    final requestTimeout = timeout ?? _requestTimeout;
    final response = await _tracedRequest(
      url: uri.toString(),
      method: HttpMethod.Put,
      requestPayloadSize: bytes.length,
      send: () => (_httpClient?.put(
                uri,
                headers: headers,
                body: bytes,
              ) ??
              http.put(uri, headers: headers, body: bytes))
          .timeout(requestTimeout),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        statusCode: response.statusCode,
        code: 'storage_upload_failed',
        message: response.body.isEmpty
            ? 'Cloud Storage upload failed with HTTP ${response.statusCode}'
            : response.body,
      );
    }
  }

  Future<http.Response> _tracedRequest({
    required String url,
    required HttpMethod method,
    required int requestPayloadSize,
    required Future<http.Response> Function() send,
  }) {
    return PerformanceService.httpMetric(
      url: url,
      method: method,
      action: send,
      onSuccess: (metric, response) {
        metric.requestPayloadSize = requestPayloadSize;
        metric.responsePayloadSize = response.contentLength ??
            response.bodyBytes.length;
        metric.httpResponseCode = response.statusCode;
        final contentType = response.headers['content-type'];
        if (contentType != null && contentType.isNotEmpty) {
          metric.responseContentType = contentType;
        }
      },
    );
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final responseBody = decodeJsonObject(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        statusCode: response.statusCode,
        code: responseBody['error']?.toString() ?? 'request_failed',
        message: responseBody['message']?.toString() ?? response.body,
      );
    }
    return responseBody;
  }
}

Map<String, dynamic> decodeJsonObject(String body) {
  if (body.isEmpty) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{};
  } on FormatException {
    return <String, dynamic>{};
  }
}

class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}
