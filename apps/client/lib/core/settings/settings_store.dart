/// 客户端配置持久化（文档 6.3）：
/// 服务器 URL、当前视图偏好；不承担权威日程存储。
library;

import 'package:shared_preferences/shared_preferences.dart';

class SettingsStore {
  SettingsStore(this._prefs);

  static const _kBaseUrl = 'server.baseUrl';
  static const _kPreferredView = 'ui.preferredView'; // day | week
  static const _kLastSync = 'sync.lastSuccessAt';

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStore(prefs);
  }

  String? get baseUrl => _prefs.getString(_kBaseUrl);
  Future<void> setBaseUrl(String? v) async {
    if (v == null || v.isEmpty) {
      await _prefs.remove(_kBaseUrl);
    } else {
      await _prefs.setString(_kBaseUrl, v);
    }
  }

  /// 仅作为记忆用户上次的视图选择；宽屏/紧凑布局仍按窗口宽度决定默认值。
  String? get preferredView => _prefs.getString(_kPreferredView);
  Future<void> setPreferredView(String v) =>
      _prefs.setString(_kPreferredView, v);

  /// 最近一次成功同步时间（本地展示用）。
  DateTime? get lastSyncAt {
    final v = _prefs.getString(_kLastSync);
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<void> setLastSyncAt(DateTime t) =>
      _prefs.setString(_kLastSync, t.toIso8601String());
}
