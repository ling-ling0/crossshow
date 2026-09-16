import 'package:flutter_test/flutter_test.dart';

import 'package:crossshow_client/core/models/models.dart';
import 'package:crossshow_client/core/time/calendar_time.dart';
import 'package:crossshow_client/features/calendar/layout_logic.dart';

Event timed(String id, String startLocalIso, int minutes) {
  final start = DateTime.parse('${startLocalIso}Z')
      .subtract(const Duration(minutes: calendarOffsetMinutes));
  return Event(
    id: id,
    title: id,
    notes: '',
    allDay: false,
    startAt: start.toUtc(),
    endAt: start.add(Duration(minutes: minutes)).toUtc(),
    timezone: 'Asia/Shanghai',
    version: 1,
  );
}

void main() {
  group('CalendarTime', () {
    test('UTC 与日历时区互转（UTC+8）', () {
      final utc = DateTime.utc(2026, 9, 14, 1, 0);
      final local = CalendarTime.toCalendar(utc);
      expect(local.hour, 9);
      expect(CalendarTime.fromCalendar(local), utc);
    });

    test('日期键跨日正确（UTC 16:00+ 为次日）', () {
      expect(CalendarTime.dateKeyOfUtc(DateTime.utc(2026, 9, 13, 16, 0)),
          '2026-09-14');
      expect(CalendarTime.dateKeyOfUtc(DateTime.utc(2026, 9, 13, 15, 59)),
          '2026-09-13');
    });

    test('周一为一周起点', () {
      // 2026-09-14 是周一；09-16 是周三
      expect(CalendarTime.mondayOf('2026-09-16'), '2026-09-14');
      expect(CalendarTime.mondayOf('2026-09-14'), '2026-09-14');
      expect(CalendarTime.mondayOf('2026-09-13'), '2026-09-07'); // 周日归上周
    });

    test('月末与年末加天数', () {
      expect(CalendarTime.addDays('2026-01-31', 7), '2026-02-07');
      expect(CalendarTime.addDays('2026-12-28', 7), '2027-01-04');
      expect(CalendarTime.addDays('2028-02-22', 7), '2028-02-29');
    });
  });

  group('fragmentsForDay（按天切分）', () {
    test('跨午夜事件在两天各产生片段并标记延续', () {
      // 23:00–次日 01:00（上海）
      final e = timed('a', '2026-09-14 23:00', 120);
      final d14 = fragmentsForDay([e], '2026-09-14', calendarOffsetMinutes);
      final d15 = fragmentsForDay([e], '2026-09-15', calendarOffsetMinutes);
      expect(d14, hasLength(1));
      expect(d14.first.startMinute, 23 * 60);
      expect(d14.first.endMinute, 24 * 60);
      expect(d14.first.continuesToNextDay, isTrue);
      expect(d15, hasLength(1));
      expect(d15.first.startMinute, 0);
      expect(d15.first.endMinute, 60);
      expect(d15.first.continuesFromPreviousDay, isTrue);
    });

    test('与该日不相交的事件被忽略；半开区间边界不相交', () {
      final e = timed('a', '2026-09-14 09:00', 60);
      expect(fragmentsForDay([e], '2026-09-15', calendarOffsetMinutes), isEmpty);
      // 结束恰好 10:00，查询 10:00 开始之后的事件片段互不影响（此处验证自身不产生零长度）
      expect(fragmentsForDay([e], '2026-09-14', calendarOffsetMinutes),
          hasLength(1));
    });
  });

  group('groupIntoColumns（重叠分组与分列，文档 4.4）', () {
    test('相邻（首尾相接）不算重叠，无需分列', () {
      final a = timed('a', '2026-09-14 09:00', 60);
      final b = timed('b', '2026-09-14 10:00', 60);
      final groups = groupIntoColumns(
          fragmentsForDay([a, b], '2026-09-14', calendarOffsetMinutes));
      // 半开区间：b 从 a 结束时刻开始，两者不重叠 → 各自成组、各占单列，
      // 渲染上处于不同时间段，不会视觉重叠。
      expect(groups, hasLength(2));
      expect(groups.every((g) => g.columnCount == 1), isTrue);
    });

    test('两个重叠事件分两列，链式重叠归同一组', () {
      final a = timed('a', '2026-09-14 09:00', 60);
      final b = timed('b', '2026-09-14 09:30', 60);
      final c = timed('c', '2026-09-14 10:00', 60); // 与 b 重叠，与 a 首尾相接
      final groups = groupIntoColumns(fragmentsForDay(
          [a, b, c], '2026-09-14', calendarOffsetMinutes));
      expect(groups, hasLength(1)); // 链式 → 连通为一组
      expect(groups.first.columnCount, 2); // b 与 a/c 重叠 → 2 列
      // b 应在第 1 列
      final bFrag = groups.first.fragments
          .map((p) => p)
          .firstWhere((p) => p.fragment.event.id == 'b');
      expect(bFrag.column, 1);
    });

    test('不重叠的两组分开', () {
      final a = timed('a', '2026-09-14 09:00', 60);
      final b = timed('b', '2026-09-14 11:00', 60);
      final groups = groupIntoColumns(
          fragmentsForDay([a, b], '2026-09-14', calendarOffsetMinutes));
      expect(groups, hasLength(2));
    });

    test('稳定排序：开始时间、结束时间、ID', () {
      final b = timed('b', '2026-09-14 09:00', 30);
      final a = timed('a', '2026-09-14 09:00', 30);
      final groups = groupIntoColumns(
          fragmentsForDay([b, a], '2026-09-14', calendarOffsetMinutes));
      expect(groups.first.fragments.first.fragment.event.id, 'a');
    });
  });

  group('Event 模型', () {
    test('fromJson 解析 UTC 时间与全天字段', () {
      final e = Event.fromJson({
        'id': 'e1',
        'series_id': null,
        'occurrence_index': null,
        'title': '课程',
        'notes': '',
        'all_day': true,
        'start_at': null,
        'end_at': null,
        'start_date': '2026-09-14',
        'end_date_exclusive': '2026-09-17',
        'timezone': 'Asia/Shanghai',
        'version': 1,
        'created_at': '2026-09-14T00:00:00Z',
        'updated_at': '2026-09-14T00:00:00Z',
        'series_version': null,
      });
      expect(e.allDay, isTrue);
      expect(e.startDate, '2026-09-14');
      expect(e.endDateExclusive, '2026-09-17');
      expect(e.isSeriesMember, isFalse);
    });
  });
}
