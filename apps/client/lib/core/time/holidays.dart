/// 法定假日数据（assets/holidays.json）与休息日判定。
///
/// 规则（开发文档 2.1 UI 需求，2026-09-15）：
/// * 周六/周日为休息日；
/// * 法定假日（含工作日连休中的平日）为休息日；
/// * 调休上班日（周末上班）显示为普通工作日。
/// 假日数据以国务院公告为准，用户可直接编辑 assets/holidays.json。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class Holidays {
  Holidays._();

  static Map<String, String> _holidays = {};
  static Map<String, String> _workdays = {};

  /// 应用启动时加载一次；文件缺失或损坏时降级为仅周末判定。
  static Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/holidays.json');
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _holidays = (j['holidays'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v.toString()));
      _workdays = (j['workdays'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      _holidays = {};
      _workdays = {};
    }
  }

  /// 当日法定假日名称；非假日返回 null。
  static String? holidayName(String dayKey) => _holidays[dayKey];

  /// 调休上班日名称（周末但上班）；非调休日返回 null。
  static String? workdayName(String dayKey) => _workdays[dayKey];

  /// 是否休息日：法定假日，或（周末且非调休上班日）。
  static bool isRestDay(String dayKey, {required bool isWeekend}) {
    if (_holidays.containsKey(dayKey)) return true;
    if (_workdays.containsKey(dayKey)) return false;
    return isWeekend;
  }
}
