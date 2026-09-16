/// 与 api/openapi.yaml 对应的数据模型。
///
/// 时间字段一律 UTC；日期字段为日历时区（首版固定 Asia/Shanghai）的
/// YYYY-MM-DD 文本。展示转换统一走 core/time/calendar_time.dart。
library;

/// 普通事件 / 全天事件 / 重复系列成员的统一表示。
class Event {
  Event({
    required this.id,
    this.seriesId,
    this.occurrenceIndex,
    required this.title,
    required this.notes,
    required this.allDay,
    required this.timezone,
    required this.version,
    this.seriesVersion,
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDateExclusive,
  });

  final String id;
  final String? seriesId;
  final int? occurrenceIndex;
  final String title;
  final String notes;
  final bool allDay;

  /// 普通事件：UTC 时间；全天为空。
  final DateTime? startAt;
  final DateTime? endAt; // 半开区间 [start, end)

  /// 全天事件：包含式开始日期 / 不含的结束日期；普通事件为空。
  final String? startDate;
  final String? endDateExclusive;

  final String timezone;
  final int version;
  final int? seriesVersion;

  bool get isSeriesMember => seriesId != null;

  factory Event.fromJson(Map<String, dynamic> j) => Event(
        id: j['id'] as String,
        seriesId: j['series_id'] as String?,
        occurrenceIndex: (j['occurrence_index'] as num?)?.toInt(),
        title: j['title'] as String,
        notes: (j['notes'] as String?) ?? '',
        allDay: j['all_day'] as bool,
        startAt: j['start_at'] == null
            ? null
            : DateTime.parse(j['start_at'] as String).toUtc(),
        endAt: j['end_at'] == null
            ? null
            : DateTime.parse(j['end_at'] as String).toUtc(),
        startDate: j['start_date'] as String?,
        endDateExclusive: j['end_date_exclusive'] as String?,
        timezone: j['timezone'] as String,
        version: (j['version'] as num).toInt(),
        seriesVersion: (j['series_version'] as num?)?.toInt(),
      );

  /// 时间网格片段计算统一在 features/calendar/layout_logic.dart。
}

/// GET /events/{id} 返回的系列信息。
class SeriesInfo {
  SeriesInfo({
    required this.id,
    required this.intervalWeeks,
    required this.occurrenceCount,
    required this.timezone,
    required this.version,
    required this.remainingAfterIndex,
  });

  final String id;
  final int intervalWeeks;
  final int occurrenceCount;
  final String timezone;
  final int version;
  final int remainingAfterIndex;

  factory SeriesInfo.fromJson(Map<String, dynamic> j) => SeriesInfo(
        id: j['id'] as String,
        intervalWeeks: (j['interval_weeks'] as num).toInt(),
        occurrenceCount: (j['occurrence_count'] as num).toInt(),
        timezone: j['timezone'] as String,
        version: (j['version'] as num).toInt(),
        remainingAfterIndex: (j['remaining_after_index'] as num).toInt(),
      );
}

class EventDetail {
  EventDetail({required this.event, this.series});

  final Event event;
  final SeriesInfo? series;

  factory EventDetail.fromJson(Map<String, dynamic> j) => EventDetail(
        event: Event.fromJson(j['event'] as Map<String, dynamic>),
        series: j['series'] == null
            ? null
            : SeriesInfo.fromJson(j['series'] as Map<String, dynamic>),
      );
}

/// 创建请求体。
class CreateEventInput {
  CreateEventInput({
    required this.title,
    required this.allDay,
    required this.timezone,
    this.notes = '',
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDateExclusive,
    this.repeatType,
    this.repeatCount,
  });

  final String title;
  final String notes;
  final bool allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? startDate;
  final String? endDateExclusive;
  final String timezone;

  /// 重复类型：null=不重复；daily/weekdays/weekly/biweekly（文档 2.1）。
  final String? repeatType;
  final int? repeatCount;

  Map<String, dynamic> toJson() => {
        'title': title,
        'notes': notes,
        'all_day': allDay,
        if (!allDay) 'start_at': startAt!.toUtc().toIso8601String(),
        if (!allDay) 'end_at': endAt!.toUtc().toIso8601String(),
        if (allDay) 'start_date': startDate,
        if (allDay) 'end_date_exclusive': endDateExclusive,
        'timezone': timezone,
        if (repeatType != null)
          'repeat': {'type': repeatType, 'count': repeatCount},
      };
}

/// 单次修改请求体（PATCH；仅出现的字段会被修改）。
class PatchEventInput {
  PatchEventInput({
    required this.expectedVersion,
    this.title,
    this.notes,
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDateExclusive,
  });

  final int expectedVersion;
  final String? title;
  final String? notes;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? startDate;
  final String? endDateExclusive;

  Map<String, dynamic> toJson() => {
        'expected_version': expectedVersion,
        if (title != null) 'title': title,
        if (notes != null) 'notes': notes,
        if (startAt != null) 'start_at': startAt!.toUtc().toIso8601String(),
        if (endAt != null) 'end_at': endAt!.toUtc().toIso8601String(),
        if (startDate != null) 'start_date': startDate,
        if (endDateExclusive != null) 'end_date_exclusive': endDateExclusive,
      };
}

/// "本次及以后"预览请求。
class SeriesChangePreviewInput {
  SeriesChangePreviewInput({
    required this.action,
    required this.expectedVersion,
    this.changes,
  });

  final String action; // update | delete
  final int expectedVersion;
  final Map<String, dynamic>? changes;

  Map<String, dynamic> toJson() => {
        'action': action,
        'expected_version': expectedVersion,
        if (changes != null) 'changes': changes,
      };
}

/// "本次及以后"预览结果。
class SeriesChangePreview {
  SeriesChangePreview({
    required this.affectedCount,
    required this.digest,
    required this.token,
    required this.expiresAt,
  });

  final int affectedCount;
  final String digest;
  final String token;
  final DateTime expiresAt;

  factory SeriesChangePreview.fromJson(Map<String, dynamic> j) =>
      SeriesChangePreview(
        affectedCount: (j['affected_count'] as num).toInt(),
        digest: j['digest'] as String,
        token: j['token'] as String,
        expiresAt: DateTime.parse(j['expires_at'] as String).toUtc(),
      );
}

/// 服务端能力（GET /config）。
class ServerConfig {
  ServerConfig({
    required this.timezone,
    required this.maxRepeatCount,
    required this.maxQuerySpanDays,
    required this.maxTitleLength,
    required this.maxNotesLength,
  });

  final String timezone;
  final int maxRepeatCount;
  final int maxQuerySpanDays;
  final int maxTitleLength;
  final int maxNotesLength;

  factory ServerConfig.fromJson(Map<String, dynamic> j) {
    final caps = j['capabilities'] as Map<String, dynamic>;
    return ServerConfig(
      timezone: j['timezone'] as String,
      maxRepeatCount: (caps['max_repeat_count'] as num).toInt(),
      maxQuerySpanDays: (caps['max_query_span_days'] as num).toInt(),
      maxTitleLength: (caps['max_title_length'] as num).toInt(),
      maxNotesLength: (caps['max_notes_length'] as num).toInt(),
    );
  }
}
