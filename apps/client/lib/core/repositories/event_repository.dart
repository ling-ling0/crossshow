/// 事件仓库：隔离网络层（文档 3.1）。
///
/// 所有写请求携带幂等键；读请求可直接重试，写请求重试复用原键。
library;

import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../network/api_client.dart';

class EventRepository {
  EventRepository(this._api);

  final ApiClient _api;
  final Uuid _uuid = const Uuid();

  /// 更新服务器地址（设置页保存时调用）。
  set baseUrl(String? v) => _api.baseUrl = v;

  String? get baseUrl => _api.baseUrl;

  /// 为一次逻辑写操作生成幂等键；网络重试必须复用同一个键（文档 8）。
  String newIdempotencyKey() => _uuid.v4();

  /// 为已存在的写操作生成"重试用"幂等键容器。
  IdempotentOp beginWrite() => IdempotentOp._(_uuid.v4());

  Future<ServerConfig> config() async {
    final j = await _api.getJson('/api/v1/config');
    return ServerConfig.fromJson(j);
  }

  Future<List<Event>> listRange(String from, String to) async {
    final j = await _api.getJson(
      '/api/v1/events',
      query: {'from': from, 'to': to},
    );
    final list = (j['events'] as List? ?? [])
        .map((e) => Event.fromJson(e as Map<String, dynamic>))
        .toList();
    return list;
  }

  Future<EventDetail> get(String id) async {
    final j = await _api.getJson('/api/v1/events/$id');
    return EventDetail.fromJson(j);
  }

  Future<List<Event>> create(
    CreateEventInput input,
    IdempotentOp op,
  ) async {
    final j = await _api.sendJson(
      'POST',
      '/api/v1/events',
      body: input.toJson(),
      idempotencyKey: op.key,
    );
    return (j['events'] as List? ?? [])
        .map((e) => Event.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Event> patch(String id, PatchEventInput input, IdempotentOp op) async {
    final j = await _api.sendJson(
      'PATCH',
      '/api/v1/events/$id',
      body: input.toJson(),
      idempotencyKey: op.key,
    );
    return Event.fromJson(j['event'] as Map<String, dynamic>);
  }

  Future<Event> delete(String id, int expectedVersion, IdempotentOp op) async {
    final j = await _api.sendJson(
      'DELETE',
      '/api/v1/events/$id',
      query: {'expected_version': '$expectedVersion'},
      idempotencyKey: op.key,
    );
    return Event.fromJson(j['event'] as Map<String, dynamic>);
  }

  Future<SeriesChangePreview> previewSeriesChange(
    String id,
    SeriesChangePreviewInput input,
    IdempotentOp op,
  ) async {
    final j = await _api.sendJson(
      'POST',
      '/api/v1/events/$id/series-change-preview',
      body: input.toJson(),
      idempotencyKey: op.key,
    );
    return SeriesChangePreview.fromJson(j);
  }

  Future<List<Event>> commitSeriesChange(
    String id,
    String token,
    IdempotentOp op,
  ) async {
    final j = await _api.sendJson(
      'POST',
      '/api/v1/events/$id/series-change-commit',
      body: {'token': token},
      idempotencyKey: op.key,
    );
    return (j['events'] as List? ?? [])
        .map((e) => Event.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// 一次逻辑写操作的幂等键容器。
/// 网络超时自动重试时复用；用户修改内容后应重新 beginWrite()。
class IdempotentOp {
  IdempotentOp._(this.key);

  final String key;
}
