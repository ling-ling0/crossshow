/// 同步控制器（开发文档 8）：
/// * 首次打开、从后台返回、手动刷新、切换至未加载日期范围时读取服务器；
/// * 前台恢复事件合并去抖，避免连续发起相同请求；
/// * 查询响应仅替换其对应窗口；过期请求响应不得覆盖新的查询或写入结果；
/// * 修改成功后重新获取受影响窗口；移出当前窗口的事件也从旧窗口移除；
/// * 读请求失败保留已加载内容并标注连接失败。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../repositories/event_repository.dart';
import '../settings/settings_store.dart';
import '../time/calendar_time.dart';

/// 窗口键：from_to（from 含、to 含，按日历时区解释）。
String windowKey(String from, String to) => '${from}_$to';

class SyncState {
  SyncState({
    this.loading = false,
    this.lastError,
    this.connected = true,
    this.lastSyncAt,
  });

  final bool loading;
  final String? lastError; // 面向用户的中文提示
  final bool connected;
  final DateTime? lastSyncAt;

  SyncState copyWith({
    bool? loading,
    String? lastError,
    bool? connected,
    DateTime? lastSyncAt,
  }) =>
      SyncState(
        loading: loading ?? this.loading,
        lastError: lastError,
        connected: connected ?? this.connected,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );
}

class SyncController extends ChangeNotifier {
  SyncController({required EventRepository repository, required SettingsStore settings})
      : _repo = repository,
        // ignore: prefer_initializing_formals
        _settings = settings;

  final EventRepository _repo;
  final SettingsStore _settings;

  final Map<String, Set<String>> _windows = {}; // windowKey -> eventIds
  final Map<String, Event> _events = {}; // eventId -> 最新版本

  SyncState state = SyncState();

  /// 单调递增的请求序号：只接受最新一次请求的结果（文档 8）。
  int _seq = 0;
  Timer? _debounce;
  bool _refreshQueued = false;

  /// 事件变动通知（供列表 diff 用）。
  int get revision => _revision;
  int _revision = 0;

  List<String> get loadedWindowKeys => _windows.keys.toList();

  // ---- 查询 ----

  /// 确保窗口已加载；已加载则跳过（切换日期范围时调用）。
  Future<void> ensureWindow(String from, String to) async {
    if (_windows.containsKey(windowKey(from, to))) return;
    await _fetchWindow(from, to);
  }

  /// 手动刷新 / 前台恢复 / 写入成功后：重新获取全部已加载窗口。
  /// 若尚无任何已加载窗口（如首次配置服务器前加载全部失败过），兜底加载当前周。
  Future<void> refreshAll({bool force = true}) async {
    final keys = _windows.keys.toList();
    if (keys.isEmpty) {
      final monday = CalendarTime.mondayOf(CalendarTime.todayKey());
      await _fetchWindow(monday, CalendarTime.addDays(monday, 7));
      return;
    }
    await _runCoalesced(() async {
      for (final key in keys) {
        final parts = key.split('_');
        await _fetchWindow(parts[0], parts[1]);
      }
    });
  }

  /// 前台恢复合并去抖（文档 8）：短时间内的多次触发合并为一次刷新。
  void scheduleRefreshOnResume() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      refreshAll();
    });
  }

  Future<void> _runCoalesced(Future<void> Function() task) async {
    if (state.loading) {
      _refreshQueued = true; // 进行中又有新请求 → 完成后再跑一轮
      return;
    }
    state = state.copyWith(loading: true);
    notifyListeners();
    await task();
    state = state.copyWith(loading: false);
    notifyListeners();
    if (_refreshQueued) {
      _refreshQueued = false;
      await refreshAll();
    }
  }

  Future<void> _fetchWindow(String from, String to) async {
    final seq = ++_seq;
    try {
      final events = await _repo.listRange(from, to);
      if (seq != _seq) return; // 过期响应：丢弃（文档 8）
      final key = windowKey(from, to);
      final oldIds = _windows[key] ?? const <String>{};
      final newIds = events.map((e) => e.id).toSet();

      // 仅替换对应窗口；移出窗口的事件从全局数据中移除。
      for (final id in oldIds.difference(newIds)) {
        _events.remove(id);
      }
      for (final e in events) {
        _events[e.id] = e;
      }
      _windows[key] = newIds;

      final now = DateTime.now();
      await _settings.setLastSyncAt(now);
      state = state.copyWith(
        connected: true,
        lastError: null,
        lastSyncAt: now,
      );
      _revision++;
      notifyListeners();
    } catch (err) {
      if (seq != _seq) return;
      // 失败保留已加载内容并标注连接失败（文档 8）。
      state = state.copyWith(
        connected: false,
        lastError: '同步失败：$err',
      );
      notifyListeners();
    }
  }

  // ---- 写入后的本地合并（权威数据仍以下一次查询为准） ----

  void upsertWritten(Iterable<Event> written) {
    for (final e in written) {
      _events[e.id] = e;
      bool placed = false;
      for (final entry in _windows.entries) {
        final parts = entry.key.split('_');
        if (_intersectsWindow(e, parts[0], parts[1])) {
          entry.value.add(e.id);
          placed = true;
        } else if (entry.value.contains(e.id)) {
          entry.value.remove(e.id); // 移出当前窗口的事件从旧窗口移除（文档 8）
        }
      }
      if (!placed && _windows.isNotEmpty) {
        // 不属于任何已加载窗口：保留数据但无窗口引用，刷新时自然清理。
      }
    }
    _revision++;
    notifyListeners();
  }

  void removeFromLocal(String eventId) {
    _events.remove(eventId);
    for (final ids in _windows.values) {
      ids.remove(eventId);
    }
    _revision++;
    notifyListeners();
  }

  bool _intersectsWindow(Event e, String from, String to) {
    // 待办不关联日期：出现在所有已加载窗口（范围查询始终返回待办）。
    if (e.isTodo) return true;
    // 与 API 一致：from 含、to 不含，按日历时区的日期解释（文档 7）。
    final startUtc = CalendarTime.dayStartUtc(from);
    final endUtc = CalendarTime.dayStartUtc(to);
    if (e.allDay) {
      final s = CalendarTime.dayStartUtc(e.startDate!);
      final t = CalendarTime.dayStartUtc(e.endDateExclusive!);
      return s.isBefore(endUtc) && t.isAfter(startUtc);
    }
    return e.startAt!.isBefore(endUtc) && e.endAt!.isAfter(startUtc);
  }

  // ---- 读视图 ----

  /// 全部待办（没有固定时间的记录）：不属于任何一天，
  /// 日视图的待办栏始终展示完整待办列表。
  List<Event> todos() {
    final out = <Event>[];
    for (final id in _windows.values.expand((s) => s).toSet()) {
      final e = _events[id];
      if (e != null && e.isTodo) out.add(e);
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// 某日历日的全部事件（不含待办）：全天在前（按开始日期），其后普通
  /// 事件按日历时区开始时间、结束、ID 排序。
  List<Event> eventsForDay(String dayKey) {
    final dayStartUtc = CalendarTime.dayStartUtc(dayKey);
    final dayEndUtc = dayStartUtc.add(const Duration(days: 1));
    final day = <Event>[];
    for (final id in _windows.values.expand((s) => s).toSet()) {
      final e = _events[id];
      if (e == null || e.isTodo) continue; // 待办不属于任何一天（见 todos()）
      final hit = e.allDay
          ? CalendarTime.dayStartUtc(e.startDate!)
                  .isBefore(dayEndUtc) &&
              CalendarTime.dayStartUtc(e.endDateExclusive!).isAfter(dayStartUtc)
          : e.startAt!.isBefore(dayEndUtc) && e.endAt!.isAfter(dayStartUtc);
      if (hit) day.add(e);
    }
    day.sort((a, b) {
      if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
      if (a.allDay) {
        return a.startDate!.compareTo(b.startDate!);
      }
      final sa = a.startAt!.add(const Duration(minutes: calendarOffsetMinutes));
      final sb = b.startAt!.add(const Duration(minutes: calendarOffsetMinutes));
      final byStart = sa.compareTo(sb);
      if (byStart != 0) return byStart;
      final byEnd = a.endAt!.compareTo(b.endAt!);
      if (byEnd != 0) return byEnd;
      return a.id.compareTo(b.id);
    });
    return day;
  }

  /// 某周的周一..周日日期键。
  List<String> weekDays(String mondayKey) => List.generate(
      7, (i) => CalendarTime.addDays(mondayKey, i));

  Event? eventById(String id) => _events[id];

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
