/// 日视图待办栏（没有固定时间的记录）测试：
/// 待办不关联日期，日视图中单独成栏、始终展示全部待办。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crossshow_client/core/network/api_client.dart';
import 'package:crossshow_client/core/repositories/event_repository.dart';
import 'package:crossshow_client/core/settings/settings_store.dart';
import 'package:crossshow_client/core/sync/sync_controller.dart';
import 'package:crossshow_client/features/calendar/day_list_view.dart';
import 'package:crossshow_client/features/calendar/day_timeline_view.dart';

Map<String, dynamic> _eventJson(Map<String, dynamic> extra) => {
      'id': 'e-${extra['title']}',
      'series_id': null,
      'occurrence_index': null,
      'title': extra['title'],
      'notes': '',
      'all_day': extra['all_day'],
      'is_todo': extra['is_todo'] ?? false,
      'start_at': extra['start_at'],
      'end_at': extra['end_at'],
      'start_date': extra['start_date'],
      'end_date_exclusive': extra['end_date_exclusive'],
      'timezone': 'Asia/Shanghai',
      'version': 1,
      'created_at': '2026-09-14T00:00:00Z',
      'updated_at': '2026-09-14T00:00:00Z',
      'series_version': null,
    };

const _todoJson = {
  'title': '买牛奶',
  'all_day': false,
  'is_todo': true,
  'start_at': null,
  'end_at': null,
  'start_date': null,
  'end_date_exclusive': null,
};

const _timedJson = {
  'title': '晨会',
  'all_day': false,
  'is_todo': false,
  // 上海 09:00–10:00 == UTC 01:00–02:00
  'start_at': '2026-09-15T01:00:00.000Z',
  'end_at': '2026-09-15T02:00:00.000Z',
  'start_date': null,
  'end_date_exclusive': null,
};

Future<SyncController> _syncWithFixture() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsStore(await SharedPreferences.getInstance());
  final client = MockClient((req) async {
    expect(req.url.path, '/api/v1/events');
    return http.Response(
      jsonEncode({
        'events': [_eventJson(_todoJson), _eventJson(_timedJson)],
        'server_time': '2026-09-15T00:00:00Z',
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final sync = SyncController(
    repository: EventRepository(ApiClient(client: client)..baseUrl = 'http://test'),
    settings: settings,
  );
  await sync.ensureWindow('2026-09-14', '2026-09-21');
  return sync;
}

Widget _wrap(SyncController sync, Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider<SyncController>.value(value: sync),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('DayListView：待办单独成栏，不混入全天/定时分组', (tester) async {
    final sync = await _syncWithFixture();
    await tester.pumpWidget(_wrap(
      sync,
      DayListView(dayKey: '2026-09-15', onEventTap: (_) {}),
    ));
    await tester.pump();

    expect(find.text('待办 · 无固定时间'), findsOneWidget); // 分组标题
    expect(find.text('买牛奶'), findsOneWidget); // 待办条目
    expect(find.text('无固定时间'), findsOneWidget); // 待办条目副标题
    expect(find.text('晨会'), findsOneWidget); // 定时事件仍在
    expect(find.text('全天'), findsNothing); // 无全天事件，待办未混入
  });

  testWidgets('DayListView：待办不关联日期，任意一天都显示全部待办', (tester) async {
    final sync = await _syncWithFixture();
    await tester.pumpWidget(_wrap(
      sync,
      DayListView(dayKey: '2026-09-17', onEventTap: (_) {}), // 没有定时事件的一天
    ));
    await tester.pump();

    expect(find.text('买牛奶'), findsOneWidget); // 待办在任何一天都显示
    expect(find.text('晨会'), findsNothing);
  });

  testWidgets('DayTimelineView：顶部待办栏展示待办', (tester) async {
    final sync = await _syncWithFixture();
    await tester.pumpWidget(_wrap(
      sync,
      DayTimelineView(dayKey: '2026-09-15', onEventTap: (_) {}),
    ));
    await tester.pump();

    expect(find.text('待办 · 无固定时间'), findsOneWidget);
    expect(find.text('买牛奶'), findsOneWidget);
    expect(find.text('晨会'), findsOneWidget);
    expect(find.text('全天'), findsNothing);
  });

  testWidgets('DayTimelineView：隐私模式下待办栏只显示栏位不显示内容', (tester) async {
    final sync = await _syncWithFixture();
    await tester.pumpWidget(_wrap(
      sync,
      DayTimelineView(
        dayKey: '2026-09-15',
        onEventTap: (_) {},
        hideContent: true,
      ),
    ));
    await tester.pump();

    expect(find.text('待办 · 无固定时间'), findsOneWidget); // 栏位仍在
    expect(find.text('买牛奶'), findsNothing); // 内容隐藏
    expect(find.text('晨会'), findsNothing);
  });
}
