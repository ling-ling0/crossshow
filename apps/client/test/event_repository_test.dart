import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:crossshow_client/core/models/errors.dart';
import 'package:crossshow_client/core/models/models.dart';
import 'package:crossshow_client/core/network/api_client.dart';
import 'package:crossshow_client/core/repositories/event_repository.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  group('EventRepository（MockClient）', () {
    test('写请求携带幂等键；同操作复用同键', () async {
      final keys = <String>[];
      final client = MockClient((req) async {
        if (req.method == 'POST') {
          final k = req.headers['Idempotency-Key'];
          expect(k, isNotNull);
          keys.add(k!);
          return _json({
            'event_ids': ['e1'],
            'series_id': null,
            'events': [
              {
                'id': 'e1',
                'title': 'x',
                'notes': '',
                'all_day': false,
                'start_at': '2026-09-14T01:00:00.000Z',
                'end_at': '2026-09-14T02:00:00.000Z',
                'timezone': 'Asia/Shanghai',
                'version': 1,
                'created_at': '2026-09-14T00:00:00Z',
                'updated_at': '2026-09-14T00:00:00Z',
                'series_version': null,
              }
            ],
            'server_time': '2026-09-14T00:00:00Z',
          }, 201);
        }
        return _json({'error': {'code': 'X', 'message': 'm'}}, 400);
      });
      final repo = EventRepository(ApiClient(client: client)..baseUrl = 'http://test');
      final op = repo.beginWrite();
      // 模拟网络重试：同一逻辑操作复用同键
      await repo.create(
        CreateEventInput(
          title: 'x',
          allDay: false,
          startAt: DateTime.utc(2026, 9, 14, 1),
          endAt: DateTime.utc(2026, 9, 14, 2),
          timezone: 'Asia/Shanghai',
        ),
        op,
      );
      await repo.create(
        CreateEventInput(
          title: 'x',
          allDay: false,
          startAt: DateTime.utc(2026, 9, 14, 1),
          endAt: DateTime.utc(2026, 9, 14, 2),
          timezone: 'Asia/Shanghai',
        ),
        op,
      );
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
    });

    test('非 2xx 抛出 ApiException 并解析错误码', () async {
      final client = MockClient((req) async => _json(
            {
              'error': {
                'code': 'VERSION_CONFLICT',
                'message': '事件已被其他设备修改',
                'details': {},
              }
            },
            409,
          ));
      final repo = EventRepository(ApiClient(client: client)..baseUrl = 'http://test');
      await expectLater(
        repo.patch(
          'e1',
          PatchEventInput(expectedVersion: 1, title: 'y'),
          repo.beginWrite(),
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.isVersionConflict, 'isVersionConflict', isTrue)
            .having((e) => e.statusCode, 'statusCode', 409)),
      );
    });

    test('未配置服务器地址抛 ServerNotConfiguredException', () async {
      final repo = EventRepository(ApiClient(client: MockClient((req) async => _json({}))));
      await expectLater(
        repo.listRange('2026-09-14', '2026-09-15'),
        throwsA(isA<ServerNotConfiguredException>()),
      );
    });

    test('listRange 解析事件列表', () async {
      final client = MockClient((req) async {
        expect(req.url.path, '/api/v1/events');
        expect(req.url.queryParameters['from'], '2026-09-14');
        expect(req.url.queryParameters['to'], '2026-09-21');
        return _json({
          'events': [
            {
              'id': 'e1',
              'title': '课程',
              'notes': 'n',
              'all_day': false,
              'start_at': '2026-09-14T01:00:00.000Z',
              'end_at': '2026-09-14T02:30:00.000Z',
              'timezone': 'Asia/Shanghai',
              'version': 2,
              'created_at': '2026-09-14T00:00:00Z',
              'updated_at': '2026-09-14T00:00:00Z',
              'series_id': 's1',
              'occurrence_index': 3,
              'series_version': 5,
            }
          ],
          'server_time': '2026-09-14T00:00:00Z',
        });
      });
      final repo = EventRepository(ApiClient(client: client)..baseUrl = 'http://test');
      final list = await repo.listRange('2026-09-14', '2026-09-21');
      expect(list, hasLength(1));
      expect(list.first.title, '课程');
      expect(list.first.occurrenceIndex, 3);
      expect(list.first.seriesVersion, 5);
      expect(list.first.startAt, DateTime.utc(2026, 9, 14, 1, 0));
    });
  });
}
