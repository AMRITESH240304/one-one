import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';

/// Thin wrapper around [FirebasePerformance] for traces and HTTP metrics.
class PerformanceService {
  PerformanceService._();

  static final FirebasePerformance _performance = FirebasePerformance.instance;

  static Future<void> initialize() async {
    await _performance.setPerformanceCollectionEnabled(true);
    final enabled = await _performance.isPerformanceCollectionEnabled();
    debugPrint('[Performance] initialized collectionEnabled=$enabled');
  }

  /// Runs [action] inside a named custom code trace.
  static Future<T> trace<T>(
    String name,
    Future<T> Function() action, {
    Map<String, String>? attributes,
  }) async {
    final customTrace = _performance.newTrace(name);
    await customTrace.start();
    try {
      attributes?.forEach(customTrace.putAttribute);
      return await action();
    } finally {
      await customTrace.stop();
    }
  }

  /// Records an HTTP/S network metric around [action].
  ///
  /// Needed for Dart `http` / `dart:io` requests — the Android Gradle plugin
  /// only auto-instruments native OkHttp stacks.
  static Future<T> httpMetric<T>({
    required String url,
    required HttpMethod method,
    required Future<T> Function() action,
    void Function(HttpMetric metric, T result)? onSuccess,
    void Function(HttpMetric metric, Object error)? onError,
  }) async {
    final metric = _performance.newHttpMetric(url, method);
    await metric.start();
    try {
      final result = await action();
      onSuccess?.call(metric, result);
      return result;
    } catch (error) {
      onError?.call(metric, error);
      rethrow;
    } finally {
      await metric.stop();
    }
  }

  static HttpMethod httpMethodFromString(String method) {
    switch (method.toUpperCase()) {
      case 'GET':
        return HttpMethod.Get;
      case 'POST':
        return HttpMethod.Post;
      case 'PUT':
        return HttpMethod.Put;
      case 'DELETE':
        return HttpMethod.Delete;
      case 'PATCH':
        return HttpMethod.Patch;
      case 'OPTIONS':
        return HttpMethod.Options;
      case 'HEAD':
        return HttpMethod.Head;
      case 'TRACE':
        return HttpMethod.Trace;
      case 'CONNECT':
        return HttpMethod.Connect;
      default:
        return HttpMethod.Get;
    }
  }
}
