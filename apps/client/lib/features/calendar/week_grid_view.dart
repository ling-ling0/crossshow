/// 周时间网格（开发文档 4.1 / 4.4）。
/// 顶部全天区域；下方 0–24 小时网格；重叠分组等宽分列；
/// 跨天片段按天绘制并标记延续关系。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/time/calendar_time.dart';
import '../../core/time/holidays.dart';
import 'layout_logic.dart';

class WeekGridView extends StatefulWidget {
  WeekGridView({
    super.key,
    required this.monday,
    required this.selectedDay,
    required this.onSelectDay,
    required this.onEventTap,
    this.hideContent = false,
  }) : days = List.generate(7, (i) => CalendarTime.addDays(monday, i));

  final String monday;
  final String selectedDay;
  final List<String> days;
  final void Function(String dayKey) onSelectDay;
  final void Function(Event event) onEventTap;

  /// 隐私模式：时间块只显示色块，不显示任何文字内容。
  final bool hideContent;

  static const double hourHeight = 56;
  static const double dayHeaderHeight = 28;

  @override
  State<WeekGridView> createState() => _WeekGridViewState();
}

class _WeekGridViewState extends State<WeekGridView> {
  final ScrollController _scroll = ScrollController();

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
    final target = minuteOfDay / 60 * WeekGridView.hourHeight -
        _scroll.position.viewportDimension / 3;
    _scroll.jumpTo(
        target.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  // 别名：保持 State 化之前的引用写法不变。
  static const double hourHeight = WeekGridView.hourHeight;
  static const double dayHeaderHeight = WeekGridView.dayHeaderHeight;
  List<String> get days => widget.days;
  String get selectedDay => widget.selectedDay;
  void Function(String dayKey) get onSelectDay => widget.onSelectDay;
  void Function(Event event) get onEventTap => widget.onEventTap;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.read<SyncController>();
    final todayKey = CalendarTime.todayKey();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final gridColor =
        isDark ? Colors.white12 : const Color(0x1A000000);

    // 预计算每天的全天事件与时间片段分组。
    final allDayByDay = <String, List<Event>>{};
    final groupsByDay = <String, List<OverlapGroup>>{};
    final restByDay = <String, bool>{}; // 休息日：法定假日或周末（调休上班日除外）
    for (final d in days) {
      final events = sync.eventsForDay(d);
      allDayByDay[d] = events.where((e) => e.allDay).toList();
      groupsByDay[d] =
          groupIntoColumns(fragmentsForDay(events, d, calendarOffsetMinutes));
      final wd = DateTime.parse('${d}T00:00:00').weekday;
      restByDay[d] = Holidays.isRestDay(d, isWeekend: wd == 6 || wd == 7);
    }
    final maxAllDayRows =
        allDayByDay.values.map((l) => l.length).reduce((a, b) => a > b ? a : b);

    // 休息日底色（淡红）与表头文字色（假日红 / 周末橙）
    final restTint = isDark
        ? Colors.red.withValues(alpha: 0.06)
        : Colors.red.withValues(alpha: 0.045);
    Color? headerTextColor(String d) {
      if (Holidays.holidayName(d) != null) {
        return const Color(0xFFD32F2F);
      }
      final wd = DateTime.parse('${d}T00:00:00').weekday;
      if ((wd == 6 || wd == 7) && Holidays.workdayName(d) == null) {
        return const Color(0xFFEF6C00);
      }
      return null;
    }

    return LayoutBuilder(builder: (context, constraints) {
      final labelWidth = 44.0;
      final gridWidth = constraints.maxWidth - labelWidth;
      final dayWidth = gridWidth / 7;

      // 全天事件行高/字号自适应：窄列（手机）加大，保证文字可读。
      final allDayRowHeight = dayWidth < 72 ? 30.0 : 24.0;
      final allDayFontSize = dayWidth < 72 ? 11.0 : 12.0;

      final header = SizedBox(
        height: dayHeaderHeight +
            (maxAllDayRows == 0
                ? 0
                : allDayRowHeight * maxAllDayRows + 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: labelWidth),
            for (final d in days)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelectDay(d),
                child: Container(
                  width: dayWidth,
                  height: dayHeaderHeight,
                  alignment: Alignment.center,
                  decoration: d == selectedDay
                      ? BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        )
                      : null,
                  child: Text.rich(
                    TextSpan(
                      text: '${int.parse(d.substring(8, 10))} ',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: d == todayKey
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: headerTextColor(d),
                      ),
                      children: [
                        TextSpan(
                          text: CalendarTime.weekdayLabel(d).substring(1),
                          style: TextStyle(
                              fontSize: 11, color: headerTextColor(d)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

      return Column(
        children: [
          header,
          if (maxAllDayRows > 0)
            SizedBox(
              height: allDayRowHeight * maxAllDayRows + 6,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('全天',
                          style: TextStyle(
                              fontSize: 10, color: theme.hintColor),
                          textAlign: TextAlign.center),
                    ),
                  ),
                  for (final d in days)
                    SizedBox(
                      width: dayWidth,
                      height: allDayRowHeight * maxAllDayRows + 6,
                      child: ListView(
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(2),
                        children: [
                          for (final e in allDayByDay[d]!)
                            _AllDayChip(
                              event: e,
                              startsHere: e.startDate == d,
                              endsHere: e.endDateExclusive ==
                                  CalendarTime.addDays(d, 1),
                              height: allDayRowHeight - 4,
                              fontSize: allDayFontSize,
                              hideContent: widget.hideContent,
                              onTap: () => onEventTap(e),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          Divider(height: 1, color: gridColor),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              child: SizedBox(
                height: 24 * hourHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Column(
                        children: [
                          for (var h = 0; h < 24; h++)
                            SizedBox(
                              height: hourHeight,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Transform.translate(
                                    offset: const Offset(0, -6),
                                    child: Text(
                                      '$h',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: theme.hintColor),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: gridWidth,
                      height: 24 * hourHeight,
                      child: Stack(
                        children: [
                          // 休息日（周末/法定假日）整列底色
                          for (var i = 0; i < 7; i++)
                            if (restByDay[days[i]] == true)
                              Positioned(
                                left: dayWidth * i,
                                width: dayWidth,
                                top: 0,
                                bottom: 0,
                                child: ColoredBox(color: restTint),
                              ),
                          // 最左（周一）边界竖线 + 日列分隔线
                          for (var i = 0; i <= 7; i++)
                            Positioned(
                              left: dayWidth * i.clamp(0, 7) - (i == 7 ? 0.5 : 0),
                              top: 0,
                              bottom: 0,
                              child: Container(width: 0.5, color: gridColor),
                            ),
                          // 小时线
                          for (var h = 1; h < 24; h++)
                            Positioned(
                              left: 0,
                              right: 0,
                              top: h * hourHeight,
                              child: Container(
                                height: 0.5,
                                color: gridColor,
                              ),
                            ),
                          // 事件片段
                          for (var i = 0; i < 7; i++)
                            ..._dayFragments(
                              context,
                              groupsByDay[days[i]]!,
                              left: dayWidth * i,
                              width: dayWidth,
                            ),
                          // 当前时间线
                          if (days.contains(todayKey)) _nowIndicator(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  List<Widget> _dayFragments(
    BuildContext context,
    List<OverlapGroup> groups, {
    required double left,
    required double width,
  }) {
    final widgets = <Widget>[];
    for (final group in groups) {
      final colWidth = width / group.columnCount;
      for (final placed in group.fragments) {
        final f = placed.fragment;
        widgets.add(Positioned(
          left: left + colWidth * placed.column + 1,
          width: colWidth - 2,
          top: f.startMinute / 60 * hourHeight + 1,
          height:
              (f.endMinute - f.startMinute) / 60 * hourHeight - 2,
          child: _FragmentBlock(
            fragment: f,
            hideContent: widget.hideContent,
            onTap: () => onEventTap(f.event),
          ),
        ));
      }
    }
    return widgets;
  }

  Widget _nowIndicator() {
    final nowUtc = DateTime.now().toUtc();
    final local = CalendarTime.toCalendar(nowUtc);
    final minuteOfDay = local.hour * 60 + local.minute;
    final todayKey = CalendarTime.todayKey();
    if (!days.contains(todayKey)) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      top: minuteOfDay / 60 * hourHeight,
      child: Container(height: 1.5, color: Colors.redAccent),
    );
  }
}

class _AllDayChip extends StatelessWidget {
  const _AllDayChip({
    required this.event,
    required this.startsHere,
    required this.endsHere,
    required this.height,
    required this.fontSize,
    required this.hideContent,
    required this.onTap,
  });

  final Event event;
  final bool startsHere;
  final bool endsHere;
  final double height;
  final double fontSize;
  final bool hideContent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(height < 22 ? 2 : 4),
        child: Container(
          height: height,
          padding: hideContent ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(startsHere ? 4 : 0),
              right: Radius.circular(endsHere ? 4 : 0),
            ),
          ),
          alignment: Alignment.center,
          child: hideContent
              ? null
              : Row(
                  children: [
                    if (!startsHere)
                      Icon(Icons.arrow_left,
                          size: fontSize + 1,
                          color: theme.colorScheme.onSecondaryContainer),
                    Expanded(
                      child: Text(
                        event.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: fontSize,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    if (!endsHere)
                      Icon(Icons.arrow_right,
                          size: fontSize + 1,
                          color: theme.colorScheme.onSecondaryContainer),
                  ],
                ),
        ),
      ),
    );
  }
}

class _FragmentBlock extends StatelessWidget {
  const _FragmentBlock({
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
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: hideContent ? null : const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.85),
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(f.continuesFromPreviousDay ? 0 : 4),
            right: Radius.circular(f.continuesToNextDay ? 0 : 4),
          ),
        ),
        child: hideContent
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (f.continuesFromPreviousDay)
                        const Icon(Icons.arrow_left, size: 11),
                      Expanded(
                        child: Text(
                          f.event.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (f.continuesToNextDay)
                        const Icon(Icons.arrow_right, size: 11),
                    ],
                  ),
                  if (f.endMinute - f.startMinute >= 45)
                    Text(
                      '${CalendarTime.formatHm(f.event.startAt!)}'
                      '${f.continuesToNextDay ? ' →' : ' – ${CalendarTime.formatHm(f.event.endAt!)}'}',
                      style: TextStyle(
                          fontSize: 9,
                          color: theme.colorScheme.onPrimaryContainer),
                    ),
                ],
              ),
      ),
    );
  }
}
