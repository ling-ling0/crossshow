/// 应用主页：宽屏（日期导航 + 周网格）/ 紧凑（当天列表，可切周视图）。
/// 开发文档 4.1 / 4.2。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/repositories/event_repository.dart';
import '../../core/settings/settings_store.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/time/calendar_time.dart';
import '../../core/time/holidays.dart';
import '../event_editor/event_actions.dart';
import '../event_editor/event_editor_page.dart';
import '../settings/settings_page.dart';
import 'day_list_view.dart';
import 'day_timeline_view.dart';
import 'week_grid_view.dart';

class CalendarHomePage extends StatefulWidget {
  const CalendarHomePage({super.key});

  @override
  State<CalendarHomePage> createState() => _CalendarHomePageState();
}

class _CalendarHomePageState extends State<CalendarHomePage>
    with WidgetsBindingObserver {
  String _selectedDay = CalendarTime.todayKey();
  bool _forceWeek = false; // 紧凑布局下用户手动切换周视图
  bool _dayTimeline = false; // 紧凑列表页：false=逐条列表，true=单日时间轴
  bool _hideContent = false; // 隐私模式：时间视图只显示色块不显示文字

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 记住上次的单日视图形态（设置存储 preferredView 字段）
    _dayTimeline = context.read<SettingsStore>().preferredView == 'day_timeline';
    _initialLoad();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initialLoad() async {
    await _ensureSelectedLoaded();
    if (!mounted) return;
    // 首次打开自动同步（文档 8）
    await context.read<SyncController>().refreshAll();
  }

  Future<void> _ensureSelectedLoaded() async {
    final sync = context.read<SyncController>();
    await sync.ensureWindow(
        CalendarTime.mondayOf(_selectedDay),
        CalendarTime.addDays(CalendarTime.mondayOf(_selectedDay), 7));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 回到前台自动同步（合并去抖）；编辑表单打开时由编辑页自行处理
      context.read<SyncController>().scheduleRefreshOnResume();
    }
  }

  void _shiftDays(int n) {
    // 周视图下 ‹ › 翻整周；列表视图翻天（视图模式与 build 中的判定一致）。
    final wide = MediaQuery.of(context).size.width > 900;
    final step = (wide || _forceWeek) ? n * 7 : n;
    setState(() => _selectedDay = CalendarTime.addDays(_selectedDay, step));
    _ensureSelectedLoaded();
  }

  void _goToday() {
    setState(() => _selectedDay = CalendarTime.todayKey());
    _ensureSelectedLoaded()
        .then((_) => mounted ? context.read<SyncController>().refreshAll() : Future.value());
  }

  Future<void> _manualRefresh() async {
    await context.read<SyncController>().refreshAll();
  }

  Future<void> _openEditor({Event? event}) async {
    final sync = context.read<SyncController>();
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => EventEditorPage(
        original: event,
        selectedDay: _selectedDay,
      ),
    ));
    if (saved == true) {
      await sync.refreshAll(); // 修改成功后重新获取受影响窗口（文档 8）
    }
  }

  /// 详情卡片：列表/时间轴中点击事件的统一入口。
  Future<void> _showEventDetail(Event event) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final timeText = event.allDay
            ? (event.startDate == CalendarTime.addDays(event.endDateExclusive!, -1)
                ? '全天（${event.startDate}）'
                : '全天 ${event.startDate} ~ ${CalendarTime.addDays(event.endDateExclusive!, -1)}')
            : '${CalendarTime.formatHm(event.startAt!)} – ${CalendarTime.formatHm(event.endAt!)}'
                '（${event.startDate ?? CalendarTime.dateKeyOfUtc(event.startAt!)}）';
        return AlertDialog(
          title: Row(
            children: [
              Expanded(
                child: Text(event.title,
                    style: const TextStyle(fontSize: 18)),
              ),
              if (event.isSeriesMember)
                Icon(Icons.repeat, size: 18, color: theme.colorScheme.secondary),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(timeText, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (event.notes.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(child: Text(event.notes)),
                )
              else
                const Text('（无备注）',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'close'),
                child: const Text('关闭')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('删除')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, 'edit'),
                child: const Text('编辑')),
          ],
        );
      },
    );
    if (!mounted) return;
    switch (action) {
      case 'edit':
        await _openEditor(event: event);
      case 'delete':
        final repo = context.read<EventRepository>();
        final ok = await quickDeleteEvent(context, repo, event);
        if (!mounted) return;
        if (ok) await context.read<SyncController>().refreshAll();
    }
  }

  /// 单日视图形态切换（仅紧凑列表页提供），并记住选择。
  Future<void> _toggleDayView() async {
    setState(() => _dayTimeline = !_dayTimeline);
    await context
        .read<SettingsStore>()
        .setPreferredView(_dayTimeline ? 'day_timeline' : 'day_list');
  }

  String _rangeLabel(bool weekMode) {
    if (!weekMode) {
      return '${_selectedDay.replaceAll('-', '/')} ${CalendarTime.weekdayLabel(_selectedDay)}';
    }
    final monday = CalendarTime.mondayOf(_selectedDay);
    final sunday = CalendarTime.addDays(monday, 6);
    return '$monday ~ $sunday';
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncController>();
    final settings = context.watch<SettingsStore>();
    final wide = MediaQuery.of(context).size.width > 900;
    final weekMode = wide || _forceWeek;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtle = isDark ? Colors.white70 : Colors.black54;

    if (settings.baseUrl == null || settings.baseUrl!.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('CrossShow')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('尚未设置服务器地址'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  final sync = context.read<SyncController>();
                  Navigator.of(context)
                      .push(
                        MaterialPageRoute(
                            builder: (_) => const SettingsPage()),
                      )
                      .then((_) {
                    if (!mounted) return;
                    // 配置服务器后返回：立即加载当前周并刷新
                    _ensureSelectedLoaded();
                    sync.refreshAll();
                  });
                },
                child: const Text('前往设置'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_rangeLabel(weekMode)),
        actions: [
          IconButton(
            tooltip: weekMode ? '上一周' : '前一天',
            onPressed: () => _shiftDays(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          TextButton(
            onPressed: _goToday,
            child: const Text('今天'),
          ),
          IconButton(
            tooltip: weekMode ? '下一周' : '后一天',
            onPressed: () => _shiftDays(1),
            icon: const Icon(Icons.chevron_right),
          ),
          if (!wide)
            IconButton(
              tooltip: weekMode ? '切换为列表' : '切换为周视图',
              onPressed: () => setState(() => _forceWeek = !_forceWeek),
              icon: Icon(weekMode ? Icons.view_list : Icons.calendar_view_week),
            ),
          if (!wide && !weekMode)
            IconButton(
              tooltip: _dayTimeline ? '切换为逐条列表' : '切换为时间轴视图',
              onPressed: _toggleDayView,
              icon: Icon(_dayTimeline
                  ? Icons.format_list_bulleted
                  : Icons.calendar_view_day),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: sync.state.loading ? null : _manualRefresh,
            icon: sync.state.loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () {
              final sync = context.read<SyncController>();
              Navigator.of(context)
                  .push(
                      MaterialPageRoute(builder: (_) => const SettingsPage()))
                  .then((_) {
                if (!mounted) return;
                _ensureSelectedLoaded();
                sync.refreshAll();
              });
            },
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (sync.state.lastError != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.cloud_off),
                title: Text(sync.state.lastError!),
                subtitle: Text('显示的是最近成功同步的内容'
                    '${sync.state.lastSyncAt == null ? '' : '（${_fmtLast(sync.state.lastSyncAt!)}）'}'),
                trailing: TextButton(
                  onPressed: _manualRefresh,
                  child: const Text('重试'),
                ),
              ),
            ),
          Expanded(
            child: weekMode
                ? WeekGridView(
                    monday: CalendarTime.mondayOf(_selectedDay),
                    selectedDay: _selectedDay,
                    onSelectDay: (d) => setState(() => _selectedDay = d),
                    onEventTap: (e) => _openEditor(event: e),
                    hideContent: _hideContent,
                  )
                : Column(
                    children: [
                      // 天视图日期头部：醒目展示当前查看的日期
                      _DayDateHeader(dayKey: _selectedDay),
                      Expanded(
                        child: _dayTimeline
                            ? DayTimelineView(
                                dayKey: _selectedDay,
                                onEventTap: (e) => _showEventDetail(e),
                                hideContent: _hideContent,
                              )
                            : DayListView(
                                dayKey: _selectedDay,
                                onEventTap: (e) => _showEventDetail(e),
                              ),
                      ),
                    ],
                  ),
          ),
          if (sync.state.lastSyncAt != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    sync.state.connected ? Icons.cloud_done : Icons.cloud_off,
                    size: 14,
                    color: subtle,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '最近同步 ${_fmtLast(sync.state.lastSyncAt!)}',
                    style: TextStyle(fontSize: 11, color: subtle),
                  ),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 隐私模式开关：仅时间类视图（周视图/单日时间轴）提供
          if (weekMode || _dayTimeline)
            FloatingActionButton.small(
              heroTag: 'toggle-hide-content',
              tooltip: _hideContent ? '显示任务内容' : '隐藏任务内容',
              onPressed: () => setState(() => _hideContent = !_hideContent),
              child: Icon(_hideContent
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
            ),
          if (weekMode || _dayTimeline) const SizedBox(width: 12),
          FloatingActionButton(
            heroTag: 'create-event',
            tooltip: '新建事件',
            onPressed: () => _openEditor(),
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  String _fmtLast(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

/// 天视图顶部的日期头部：如「9月15日 · 周二 · 今天」。
class _DayDateHeader extends StatelessWidget {
  const _DayDateHeader({required this.dayKey});

  final String dayKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isToday = dayKey == CalendarTime.todayKey();
    final holiday = Holidays.holidayName(dayKey);
    final workday = Holidays.workdayName(dayKey);
    final date = DateTime.parse('${dayKey}T00:00:00');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '${date.month}月${date.day}日',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Text(
            CalendarTime.weekdayLabel(dayKey),
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.hintColor),
          ),
          if (isToday) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '今天',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (holiday != null) ...[
            const SizedBox(width: 8),
            Text(holiday,
                style: const TextStyle(
                    color: Color(0xFFD32F2F),
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ] else if (workday != null) ...[
            const SizedBox(width: 8),
            Text('$workday（班）',
                style: const TextStyle(
                    color: Color(0xFFEF6C00),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}
