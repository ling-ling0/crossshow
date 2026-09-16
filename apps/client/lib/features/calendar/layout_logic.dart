/// 时间网格布局算法（纯 Dart，可单元测试）。
///
/// 开发文档 4.4：
/// * 半开区间 [start, end)：一个事件恰好结束时另一个开始不算重叠；
/// * 按天切分跨天普通事件的显示片段；
/// * 同一天内将相互关联的重叠事件分组（连通分量），再为每组分配列；
/// * 稳定排序：开始时间、结束时间、事件 ID；
/// * 首版每组等宽分列。
library;

import '../../core/models/models.dart';
import '../../core/time/calendar_time.dart';

/// 某事件在某个日历日的显示片段（分钟数，0..1440，半开区间）。
class DayFragment {
  DayFragment({
    required this.event,
    required this.dayKey,
    required this.startMinute,
    required this.endMinute,
    required this.continuesFromPreviousDay,
    required this.continuesToNextDay,
  });

  final Event event;
  final String dayKey;
  final int startMinute;
  final int endMinute; // > startMinute
  final bool continuesFromPreviousDay;
  final bool continuesToNextDay;

  /// 事件是否恰好在这一天开始（普通事件）。
  bool get startsThisDay {
    if (event.allDay) return event.startDate == dayKey;
    return CalendarTime.dateKeyOfUtc(event.startAt!) == dayKey;
  }
}

/// 一组相互重叠的片段及其列分配结果。
class OverlapGroup {
  OverlapGroup({required this.fragments, required this.columnCount});

  final List<PlacedFragment> fragments;
  final int columnCount;
}

/// 已分配列的片段。
class PlacedFragment {
  PlacedFragment({required this.fragment, required this.column});

  final DayFragment fragment;
  final int column; // 0..columnCount-1
}

/// 计算某日历日的时间片段（不含全天事件）。
/// 输入事件无须预过滤；与该日不相交的普通事件会被忽略。
List<DayFragment> fragmentsForDay(
  List<Event> events,
  String dayKey,
  int offsetMinutes,
) {
  final dayStartUtc = CalendarTime.dayStartUtc(dayKey);
  final dayEndUtc = dayStartUtc.add(const Duration(days: 1));
  final result = <DayFragment>[];

  for (final e in events) {
    if (e.allDay) continue;
    if (e.startAt == null || e.endAt == null) continue;
    final s = e.startAt!;
    final t = e.endAt!;
    if (!s.isBefore(dayEndUtc) || !t.isAfter(dayStartUtc)) continue; // 不相交

    final from = s.isAfter(dayStartUtc) ? s : dayStartUtc;
    final to = t.isBefore(dayEndUtc) ? t : dayEndUtc;
    final startMin = from.difference(dayStartUtc).inMinutes;
    final endMin = to.difference(dayStartUtc).inMinutes;
    if (endMin <= startMin) continue; // 负 / 零长度片段不绘制

    result.add(DayFragment(
      event: e,
      dayKey: dayKey,
      startMinute: startMin,
      endMinute: endMin,
      continuesFromPreviousDay: s.isBefore(dayStartUtc),
      continuesToNextDay: t.isAfter(dayEndUtc),
    ));
  }
  return result;
}

/// 重叠分组 + 等宽分列（文档 4.4）。
/// 输入应为同一日的片段；内部先按（开始、结束、ID）稳定排序再分组。
List<OverlapGroup> groupIntoColumns(List<DayFragment> fragments) {
  final sorted = [...fragments]..sort((a, b) {
      final byStart = a.startMinute.compareTo(b.startMinute);
      if (byStart != 0) return byStart;
      final byEnd = a.endMinute.compareTo(b.endMinute);
      if (byEnd != 0) return byEnd;
      return a.event.id.compareTo(b.event.id);
    });

  // 连通分量分组：当前组内最大结束时间 ≤ 新片段开始 → 不重叠，另起一组。
  final groups = <List<DayFragment>>[];
  List<DayFragment>? current;
  int currentMaxEnd = -1;

  bool overlaps(DayFragment f) {
    if (current == null) return false;
    // 半开区间：endMinute == startMinute 不算重叠。
    return currentMaxEnd > f.startMinute;
  }

  for (final f in sorted) {
    if (!overlaps(f)) {
      current = [f];
      currentMaxEnd = f.endMinute;
      groups.add(current);
    } else {
      current!.add(f);
      if (f.endMinute > currentMaxEnd) currentMaxEnd = f.endMinute;
    }
  }

  // 组内贪心分配列：放入第一个"上一片段结束 ≤ 当前开始"的列。
  final result = <OverlapGroup>[];
  for (final group in groups) {
    final columnEnds = <int>[];
    final placed = <PlacedFragment>[];
    for (final f in group) {
      var col = -1;
      for (var i = 0; i < columnEnds.length; i++) {
        if (columnEnds[i] <= f.startMinute) {
          col = i;
          break;
        }
      }
      if (col == -1) {
        columnEnds.add(f.endMinute);
        col = columnEnds.length - 1;
      } else {
        columnEnds[col] = f.endMinute;
      }
      placed.add(PlacedFragment(fragment: f, column: col));
    }
    result.add(OverlapGroup(
      fragments: placed,
      columnCount: columnEnds.length,
    ));
  }
  return result;
}
