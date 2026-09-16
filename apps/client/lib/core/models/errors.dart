/// API 错误：统一 {"error":{"code","message","details"}} 格式（文档 7）。
library;

import 'dart:convert';

/// 服务端错误码。
class ErrorCodes {
  static const validation = 'VALIDATION_ERROR';
  static const notFound = 'NOT_FOUND';
  static const versionConflict = 'VERSION_CONFLICT';
  static const previewExpired = 'PREVIEW_EXPIRED';
  static const idempotencyConflict = 'IDEMPOTENCY_CONFLICT';
  static const internal = 'INTERNAL';
  static const unavailable = 'UNAVAILABLE';
}

class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  bool get isVersionConflict => code == ErrorCodes.versionConflict;
  bool get isPreviewExpired => code == ErrorCodes.previewExpired;
  bool get isNotFound => code == ErrorCodes.notFound;
  bool get isUnavailable =>
      code == ErrorCodes.unavailable || statusCode == 503;

  factory ApiException.fromStatus(int status, String body) {
    String code = 'HTTP_$status';
    String message = '请求失败（$status）';
    try {
      final j = jsonDecodeMap(body);
      if (j != null) {
        final err = j['error'];
        if (err is Map<String, dynamic>) {
          code = (err['code'] as String?) ?? code;
          message = (err['message'] as String?) ?? message;
        }
      }
    } catch (_) {
      // 保留默认消息
    }
    return ApiException(statusCode: status, code: code, message: message);
  }

  static Map<String, dynamic>? jsonDecodeMap(String body) {
    try {
      final v = const JsonDecoder().convert(body);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => message;
}

/// 网络层异常（断网、超时等；文档 8：断网时标注连接失败）。
class NetworkException implements Exception {
  NetworkException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 未设置服务器地址。
class ServerNotConfiguredException implements Exception {
  ServerNotConfiguredException(this.message);

  final String message;

  @override
  String toString() => message;
}
