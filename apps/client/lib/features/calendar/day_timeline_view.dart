/// 单日时间轴视图：周视图里"一天"的形态（小时刻度 + 按时间定位的事件块）。
/// 与逐条列表互切；布局算法复用 layout_logic（文档 4.4）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/time/calendar_time.dart';
import 'layout_logic.dart';


class DayTimelineView extends StatefulWidget {
  const DayTimelineView({
    super.key,
    required this.dayKey,
    required this.onEventTap,
    this.hideContent = false,
  });

  final String dayKey;
  final void Function(Event event) onEventTap;

  /// 隐私模式：时间块只显示色块，不显示任何文字内容。
  final bool hideContent;

  /// 与周视图一致的初始滚动位置（顶部 8 时，可上翻到 0 时）。
  static const double hourHeight = 64;

  @override
  State<DayTimelineView> createState() => _DayTimelineViewState();
}

class _DayTimelineViewState extends State<DayTimelineView> {
  late final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 切换视图进入时：让当前时间红线位于可视区上方约 1/3 处
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToNow());
  }

  void _scrollToNow() {
    if (!_scroll.hasClients) return;
    final local = CalendarTime.toCalendar(DateTime.now().toUtc());
    final minuteOfDay = local.hour * 60 + local.minute;
    final target = minuteOfDay / 60 * DayTimelineView.hourHeight -
        _scroll.position.viewportDimension / 3;
    _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.read<SyncController>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final gridColor = isDark ? Colors.white12 : const Color(0x1A000000);

    final events = sync.eventsForDay(widget.dayKey);
    final allDay = events.where((e) => e.allDay).toList();
    final groups =
        groupIntoColumns(fragmentsForDay(events, widget.dayKey, calendarOffsetMinutes));

    final labelWidth = 52.0;
    final isToday = widget.dayKey == CalendarTime.todayKey();

    return Column(
      children: [
        if (allDay.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('全天',
                    style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSecondaryContainer)),
                for (final e in allDay)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: InkWell(
                      onTap: () => widget.onEventTap(e),
                      child: widget.hideContent
                          ? const SizedBox(height: 12)
                          : Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    e.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: theme
                                            .colorScheme.onSecondaryContainer),
                                  ),
                                ),
                                if (e.isSeriesMember)
                                  Icon(Icons.repeat,
                                      size: 13,
                                      color: theme
                                          .colorScheme.onSecondaryContainer),
                              ],
                            ),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: SizedBox(
              height: 24 * DayTimelineView.hourHeight,
              child: LayoutBuilder(builder: (context, constraints) {
                // 右侧留 10px 边距，事件块不紧贴屏幕边缘
                final gridWidth = constraints.maxWidth - labelWidth - 10;
                return Stack(
                  children: [
                    for (var h = 1; h < 24; h++)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: h * DayTimelineView.hourHeight,
                        child: Container(height: 0.5, color: gridColor),
                      ),
                    // 小时标签
                    for (var h = 0; h < 24; h++)
                      Positioned(
                        left: 0,
                        width: labelWidth - 6,
                        top: h * DayTimelineView.hourHeight,
                        child: Transform.translate(
                          offset: const Offset(0, -7),
                          child: Text(
                            '$h:00',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 10, color: theme.hintColor),
                          ),
                        ),
                      ),
                    // 事件块
                    for (final group in groups)
                      ...group.fragments.map((placed) {
                        final f = placed.fragment;
                        final colWidth = gridWidth / group.columnCount;
                        return Positioned(
                          left: labelWidth + colWidth * placed.column + 1,
                          width: colWidth - 2,
                          top:
                              f.startMinute / 60 * DayTimelineView.hourHeight + 1,
                          height: (f.endMinute - f.startMinute) /
                                  60 *
                                  DayTimelineView.hourHeight -
                              2,
                          child: _Block(
                            fragment: f,
                            hideContent: widget.hideContent,
                            onTap: () => widget.onEventTap(f.event),
                          ),
                        );
                      }),
                    // 当前时间线（仅当天）
                    if (isToday)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: _nowMinuteOfDay() / 60 * DayTimelineView.hourHeight,
                        child:
                            Container(height: 1.5, color: Colors.redAccent),
                      ),
                  ],
                );
              }),
            ),
          ),
        ),
      ],
    );
  }

  double _nowMinuteOfDay() {
    final local = CalendarTime.toCalendar(DateTime.now().toUtc());
    return (local.hour * 60 + local.minute).toDouble();
  }
}

/// 与周视图共享初始滚动位置常量（WeekGridView.initialTopHour）。

class _Block extends StatelessWidget {
  const _Block({
    required this.fragment,
    required this.hideContent,
    required this.onTap,
  });

  final DayFragment fragment;
  final bool hideContent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = fragment;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: hideContent ? null : const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.9),
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(f.continuesFromPreviousDay ? 0 : 6),
            right: Radius.circular(f.continuesToNextDay ? 0 : 6),
          ),
        ),
        alignment: hideContent ? Alignment.center : null,
        child: hideContent
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (f.continuesFromPreviousDay)
                        const Icon(Icons.arrow_left, size: 14),
                      Expanded(
                        child: Text(
                          f.event.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (f.event.isSeriesMember)
                        Icon(Icons.repeat,
                            size: 12,
                            color: theme.colorScheme.onPrimaryContainer),
                      if (f.continuesToNextDay)
                        const Icon(Icons.arrow_right, size: 14),
                    ],
                  ),
                  if (f.endMinute - f.startMinute >= 50)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${CalendarTime.formatHm(f.event.startAt!)} – '
                        '${f.continuesToNextDay ? "次日…" : CalendarTime.formatHm(f.event.endAt!)}',
                        style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onPrimaryContainer),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
