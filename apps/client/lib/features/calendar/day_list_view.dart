/// 紧凑布局的当天列表（开发文档 4.2）。
/// 内容不足一屏也能下拉刷新。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/time/calendar_time.dart';

class DayListView extends StatelessWidget {
  const DayListView({
    super.key,
    required this.dayKey,
    required this.onEventTap,
  });

  final String dayKey;
  final void Function(Event event) onEventTap;

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncController>();
    final events = sync.eventsForDay(dayKey);
    final todos = sync.todos(); // 待办不关联日期：展示全部待办
    final allDay = events.where((e) => e.allDay).toList();
    final timed = events.where((e) => !e.allDay).toList();

    return RefreshIndicator(
      onRefresh: () => sync.refreshAll(),
      child: timed.isEmpty && allDay.isEmpty && todos.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.6,
                  child: Center(
                    child: Text(
                      '当天没有事件\n下拉刷新或点击 + 新建',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final e in allDay)
                  _EventCard(
                    event: e,
                    subtitle: '全天',
                    onTap: () => onEventTap(e),
                  ),
                if (todos.isNotEmpty) ...[
                  if (allDay.isNotEmpty) const Divider(height: 16),
                  const _SectionLabel(icon: Icons.task_alt, text: '待办 · 无固定时间'),
                  for (final e in todos)
                    _EventCard(
                      event: e,
                      subtitle: '无固定时间',
                      todo: true,
                      onTap: () => onEventTap(e),
                    ),
                ],
                if (timed.isNotEmpty && (allDay.isNotEmpty || todos.isNotEmpty))
                  const Divider(height: 16),
                for (final e in timed)
                  _EventCard(
                    event: e,
                    subtitle:
                        '${CalendarTime.formatHm(e.startAt!)} – ${CalendarTime.formatHm(e.endAt!)}',
                    onTap: () => onEventTap(e),
                  ),
              ],
            ),
    );
  }
}

/// 分组标题（待办栏）。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.tertiary),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.tertiary)),
        ],
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.subtitle,
    required this.onTap,
    this.todo = false,
  });

  final Event event;
  final String subtitle;
  final VoidCallback onTap;

  /// 待办卡片：三级色标识，与普通/全天事件区分。
  final bool todo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 4,
          height: 40,
          decoration: BoxDecoration(
            color: todo
                ? theme.colorScheme.tertiary
                : event.allDay
                    ? theme.colorScheme.secondary
                    : theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        title: Text(
          event.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            Text(subtitle),
            if (event.isSeriesMember) ...[
              const SizedBox(width: 8),
              Icon(Icons.repeat, size: 13, color: theme.colorScheme.secondary),
            ],
            if (event.notes.isNotEmpty) ...[
              const SizedBox(width: 6),
              Icon(Icons.notes, size: 13, color: theme.colorScheme.secondary),
            ],
          ],
        ),
        trailing: event.isSeriesMember
            ? null
            : Icon(Icons.chevron_right,
                color: isDark ? Colors.white38 : Colors.black26),
      ),
    );
  }
}
