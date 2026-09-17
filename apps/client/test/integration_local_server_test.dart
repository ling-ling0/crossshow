/// 本地联调测试：需要真实服务端运行在 CROSSSHOW_TEST_BASE_URL（默认
/// http://127.0.0.1:18099）。服务端不可达时自动跳过，不阻塞 CI。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:crossshow_client/core/models/errors.dart';
import 'package:crossshow_client/core/models/models.dart';
import 'package:crossshow_client/core/network/api_client.dart';
import 'package:crossshow_client/core/repositories/event_repository.dart';
import 'package:crossshow_client/core/time/calendar_time.dart';

const base = String.fromEnvironment(
  'CROSSSHOW_TEST_BASE_URL',
  defaultValue: 'http://127.0.0.1:18099',
);

void main() {
  late EventRepository repo;
  var serverUp = false;

  setUpAll(() async {
    repo = EventRepository(ApiClient(client: http.Client())..baseUrl = base);
    try {
      await repo.config().timeout(const Duration(seconds: 2));
      serverUp = true;
    } catch (_) {
      serverUp = false;
    }
  });

  test('客户端 ↔ 服务端全流程：创建 → 查询 → 修改 → 批量 → 删除', () async {
    if (!serverUp) return; // 服务端未运行时静默跳过

    // 1) 创建每周 3 次的系列（从明天开始，保证"未来"可批量）
    final tomorrow = CalendarTime.addDays(CalendarTime.todayKey(), 1);
    final startUtc = CalendarTime.wallToUtc(tomorrow, 9, 0);
    final events = await repo.create(
      CreateEventInput(
        title: '联调课程',
        notes: '集成测试',
        allDay: false,
        startAt: startUtc,
        endAt: startUtc.add(const Duration(minutes: 90)),
        timezone: 'Asia/Shanghai',
        repeatType: 'weekly',
        repeatCount: 3,
      ),
      repo.beginWrite(),
    );
    expect(events, hasLength(3));
    final first = events.first;
    expect(first.isSeriesMember, isTrue);

    // 2) 范围查询能看到
    final listed =
        await repo.listRange(tomorrow, CalendarTime.addDays(tomorrow, 30));
    expect(listed.where((e) => e.title == '联调课程'), hasLength(3));

    // 3) 单次修改（仅本次，携带 expected_version）
    final patched = await repo.patch(
      first.id,
      PatchEventInput(expectedVersion: first.version, title: '联调课程(单改)'),
      repo.beginWrite(),
    );
    expect(patched.title, '联调课程(单改)');
    expect(patched.version, first.version + 1);

    // 4) 版本冲突：旧版本号再改 → 409
    await expectLater(
      repo.patch(
        first.id,
        PatchEventInput(expectedVersion: first.version, title: '应失败'),
        repo.beginWrite(),
      ),
      throwsA(isA<ApiException>()
          .having((e) => e.isVersionConflict, 'conflict', isTrue)),
    );

    // 5) 本次及以后：预览 → 提交
    final preview = await repo.previewSeriesChange(
      first.id,
      SeriesChangePreviewInput(
        action: 'update',
        expectedVersion: patched.version,
        changes: {'title': '联调课程(批量)'},
      ),
      repo.beginWrite(),
    );
    expect(preview.affectedCount, 3);
    final committed =
        await repo.commitSeriesChange(first.id, preview.token, repo.beginWrite());
    expect(committed.every((e) => e.title == '联调课程(批量)'), isTrue);

    // 6) 批量删除
    final delPreview = await repo.previewSeriesChange(
      first.id,
      SeriesChangePreviewInput(
          action: 'delete', expectedVersion: committed.first.version),
      repo.beginWrite(),
    );
    await repo.commitSeriesChange(first.id, delPreview.token, repo.beginWrite());
    final after =
        await repo.listRange(tomorrow, CalendarTime.addDays(tomorrow, 30));
    expect(after.where((e) => e.title.startsWith('联调课程')), isEmpty);

    // 7) 待办（没有固定时间的记录）：创建 → 任意窗口查询 → 改标题 → 删除
    final todoList = await repo.create(
      CreateEventInput(
        title: '联调待办',
        allDay: false,
        isTodo: true,
        timezone: 'Asia/Shanghai',
      ),
      repo.beginWrite(),
    );
    expect(todoList, hasLength(1));
    expect(todoList.single.isTodo, isTrue);
    expect(todoList.single.allDay, isFalse);
    // 待办不关联日期：查询一个无关的远期窗口也能看到
    final listed2 =
        await repo.listRange(CalendarTime.addDays(tomorrow, 60),
            CalendarTime.addDays(tomorrow, 61));
    expect(listed2.singleWhere((e) => e.title == '联调待办').isTodo, isTrue);
    final todoPatched = await repo.patch(
      todoList.single.id,
      PatchEventInput(
        expectedVersion: todoList.single.version,
        title: '联调待办(改)',
      ),
      repo.beginWrite(),
    );
    expect(todoPatched.title, '联调待办(改)');
    expect(todoPatched.isTodo, isTrue);
    // 待办不支持重复 → 400
    await expectLater(
      repo.create(
        CreateEventInput(
          title: '应失败',
          allDay: false,
          isTodo: true,
          timezone: 'Asia/Shanghai',
          repeatType: 'daily',
          repeatCount: 2,
        ),
        repo.beginWrite(),
      ),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await repo.delete(todoList.single.id, todoPatched.version, repo.beginWrite());
  });
}
