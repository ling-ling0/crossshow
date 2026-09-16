/// 日历时区工具。
///
/// 开发文档 2.2 / 5.1：各端统一使用服务端日历时区（首版固定
/// Asia/Shanghai，即 UTC+8，无夏令时）展示，不随设备时区变化。
/// 因此首版以固定偏移实现"日历时区"；未来开放其他时区时必须
/// 引入完整 tzdata 并处理夏令时规则。
library;

/// Asia/Shanghai 的固定偏移（分钟）。无夏令时（自 1991 年起）。
const int calendarOffsetMinutes = 8 * 60;

/// 纯函数式日期助手，全部基于日历时区语义。
class CalendarTime {
  CalendarTime._();

  /// UTC 时间 → 日历时区的墙钟时间。
  static DateTime toCalendar(DateTime utc) =>
      utc.add(const Duration(minutes: calendarOffsetMinutes));

  /// 日历时区墙钟时间 → UTC。
  static DateTime fromCalendar(DateTime wallClock) =>
      wallClock.subtract(const Duration(minutes: calendarOffsetMinutes));

  /// 事件在日历时区的日期键 YYYY-MM-DD（全天即开始日期）。
  static String dateKeyOfUtc(DateTime utc) =>
      toCalendar(utc.toUtc()).toIso8601String().substring(0, 10);

  /// 当天零点（日历时区）对应的日期键。
  static String todayKey() {
    final nowUtc = DateTime.now().toUtc();
    return dateKeyOfUtc(nowUtc);
  }

  /// 日历日零点（日历时区）→ UTC。
  /// 注意：必须用带 Z 后缀的解析（把字段当作墙钟、与设备时区无关），
  /// 再减去日历偏移；无后缀的 parse 会按设备本地时区解释造成双重偏移。
  static DateTime dayStartUtc(String dateKey) => wallToUtc(dateKey, 0, 0);

  /// 日历时区的墙钟（日期 + 时分）→ UTC。
  static DateTime wallToUtc(String dateKey, int hour, int minute) {
    final wall = DateTime.parse(
        '${dateKey}T${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00Z');
    return wall.subtract(const Duration(minutes: calendarOffsetMinutes));
  }

  /// 日期键加 n 天。
  static String addDays(String dateKey, int n) =>
      DateTime.parse('${dateKey}T00:00:00')
          .add(Duration(days: n))
          .toIso8601String()
          .substring(0, 10);

  /// 所在周的周一（文档 2.2：周一为一周起点）。
  static String mondayOf(String dateKey) {
    final d = DateTime.parse('${dateKey}T00:00:00');
    final weekday = d.weekday; // DateTime.monday == 1
    return addDays(dateKey, -(weekday - 1));
  }

  /// 中文星期名（周一为起点）。
  static String weekdayLabel(String dateKey) {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final d = DateTime.parse('${dateKey}T00:00:00');
    return names[d.weekday - 1];
  }

  /// 普通事件在日历时区的显示时间 HH:mm。
  static String formatHm(DateTime utc) {
    final l = toCalendar(utc);
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  /// 版本一致的 RFC3339（不带小数秒，服务端可解析）。
  static String toRfc3339Utc(DateTime utc) => utc.toUtc().toIso8601String();
}
