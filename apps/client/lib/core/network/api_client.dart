/// API 客户端：纯 HTTP 封装，不含业务语义。
///
/// 开发文档 3.1 / 9.2：服务器 URL 来自设置页（不写死 IP）；
/// Repository 隔离网络层。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/errors.dart';

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 当前服务器地址，如 http://192.168.1.10:8080 （不带尾斜杠）。
  String? baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl;
    if (base == null || base.isEmpty) {
      throw ServerNotConfiguredException('尚未设置服务器地址，请在设置页填写');
    }
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final resp = await _withNetworkWrap(
        () => _client.get(_uri(path, query), headers: _headers()));
    return _decode(resp);
  }

  Future<Map<String, dynamic>> sendJson(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    String? idempotencyKey,
  }) async {
    final resp = await _withNetworkWrap(() {
      final headers = _headers();
      if (idempotencyKey != null) {
        headers['Idempotency-Key'] = idempotencyKey;
      }
      final uri = _uri(path, query);
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) {
        request.body = jsonEncode(body);
      }
      return _client.send(request).then(http.Response.fromStream);
    });
    return _decode(resp);
  }

  Map<String, String> _headers() =>
      {'Content-Type': 'application/json; charset=utf-8'};

  Future<http.Response> _withNetworkWrap(
    Future<http.Response> Function() fn,
  ) async {
    try {
      return await fn().timeout(const Duration(seconds: 15));
    } on SocketException catch (e) {
      throw NetworkException('无法连接服务器：${e.message}');
    } on HttpException catch (e) {
      throw NetworkException('网络错误：${e.message}');
    } on TimeoutException {
      throw NetworkException('连接超时，请检查网络后重试');
    }
  }

  Map<String, dynamic> _decode(http.Response resp) {
    final body = utf8.decode(resp.bodyBytes);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ApiException.fromStatus(resp.statusCode, body);
    }
    if (body.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw ApiException(
        statusCode: resp.statusCode,
        code: 'INVALID_RESPONSE',
        message: '响应格式异常');
  }

  void close() => _client.close();
}
