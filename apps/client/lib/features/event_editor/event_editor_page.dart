/// 事件编辑器（开发文档 4.3 / 5.3 / 8）。
///
/// * 标题必填（去首尾空白 1–200）；备注可空 ≤10,000；
/// * 全天开关切换日期/时间字段（均使用包含式日期语义，结束字段按
///   服务端"不含"约定提交）；
/// * 创建时可选不重复 / 每周 / 每双周 + 总次数（含首次）；
/// * 系列成员保存/删除前选择"仅本次"或"本次及以后"；
/// * 保存中禁用重复提交；失败保留输入；409 展示服务器版本由用户核对。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/errors.dart';
import '../../core/models/models.dart';
import '../../core/repositories/event_repository.dart';
import '../../core/time/calendar_time.dart';
import 'event_actions.dart';

class EventEditorPage extends StatefulWidget {
  const EventEditorPage({
    super.key,
    required this.selectedDay,
    this.original,
  });

  /// 非空 = 编辑已有事件；空 = 创建。
  final Event? original;
  final String selectedDay;

  @override
  State<EventEditorPage> createState() => _EventEditorPageState();
}

class _EventEditorPageState extends State<EventEditorPage> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late bool _allDay;
  late String _startDate; // 包含
  late String _endDate; // 界面展示的结束日期（全天=最后一天含；普通=结束日期）
  late TimeOfDay _start;
  late TimeOfDay _end;
  late String? _repeatType; // null=不重复；daily/weekdays/weekly/biweekly
  late int _repeatCount;

  late Event _orig; // 可变：409 覆盖保存时以服务器最新版本重试

  bool _saving = false;
  String? _error;

  bool get _editing => widget.original != null;

  @override
  void initState() {
    super.initState();
    final orig = widget.original;
    if (orig != null) _orig = orig;
    _title = TextEditingController(text: orig?.title ?? '');
    _notes = TextEditingController(text: orig?.notes ?? '');
    if (orig == null) {
      _allDay = false;
      _startDate = widget.selectedDay;
      _endDate = widget.selectedDay;
      final now = TimeOfDay.fromDateTime(
          CalendarTime.toCalendar(DateTime.now().toUtc()));
      _start = TimeOfDay(hour: now.hour, minute: 0);
      _end = TimeOfDay(hour: (now.hour + 1) % 24, minute: 0);
      _repeatType = null;
      _repeatCount = 1;
    } else {
      _allDay = orig.allDay;
      if (orig.allDay) {
        _startDate = orig.startDate!;
        // 服务端存"不含"日期，界面回显为包含式最后一天
        _endDate = CalendarTime.addDays(orig.endDateExclusive!, -1);
      } else {
        final s = CalendarTime.toCalendar(orig.startAt!);
        final e = CalendarTime.toCalendar(orig.endAt!);
        _startDate = CalendarTime.dateKeyOfUtc(orig.startAt!);
        _endDate = CalendarTime.dateKeyOfUtc(orig.endAt!); // 精确回显（含午夜结束）
        _start = TimeOfDay(hour: s.hour, minute: s.minute);
        _end = TimeOfDay(hour: e.hour, minute: e.minute);
      }
      _repeatType = null; // 首版不支持重设已有系列的周期/次数
      _repeatCount = 1;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  // ---- 组装提交内容 ----

  ({DateTime startUtc, DateTime endUtc}) _timedUtc() {
    final s = CalendarTime.wallToUtc(_startDate, _start.hour, _start.minute);
    final e = CalendarTime.wallToUtc(_endDate, _end.hour, _end.minute);
    return (startUtc: s, endUtc: e);
  }

  Map<String, dynamic> _changesForSeries() {
    // 仅传播实际改变的字段（文档 5.3）。
    final changes = <String, dynamic>{};
    if (_title.text.trim() != _orig.title) {
      changes['title'] = _title.text.trim();
    }
    if (_notes.text != _orig.notes) {
      changes['notes'] = _notes.text;
    }
    if (_orig.allDay) {
      if (_startDate != _orig.startDate!) {
        changes['start_date'] = _startDate;
      }
      final newEndExcl = CalendarTime.addDays(_endDate, 1);
      if (newEndExcl != _orig.endDateExclusive!) {
        changes['end_date_exclusive'] = newEndExcl;
      }
    } else {
      final t = _timedUtc();
      if (t.startUtc != _orig.startAt!) changes['start_at'] = t.startUtc.toIso8601String();
      if (t.endUtc != _orig.endAt!) changes['end_at'] = t.endUtc.toIso8601String();
    }
    return changes;
  }

  CreateEventInput _buildCreate() {
    if (_allDay) {
      return CreateEventInput(
        title: _title.text.trim(),
        notes: _notes.text,
        allDay: true,
        startDate: _startDate,
        endDateExclusive: CalendarTime.addDays(_endDate, 1),
        timezone: 'Asia/Shanghai',
        repeatType: _repeatType,
        repeatCount: _repeatType == null ? null : _repeatCount,
      );
    }
    final t = _timedUtc();
    return CreateEventInput(
      title: _title.text.trim(),
      notes: _notes.text,
      allDay: false,
      startAt: t.startUtc,
      endAt: t.endUtc,
      timezone: 'Asia/Shanghai',
      repeatType: _repeatType,
      repeatCount: _repeatType == null ? null : _repeatCount,
    );
  }

  // ---- 保存 / 删除 ----

  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '标题不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = context.read<EventRepository>();
    var navigated = false;
    try {
      if (!_editing) {
        final op = repo.beginWrite();
        await repo.create(_buildCreate(), op);
      } else if (!_orig.isSeriesMember) {
        final op = repo.beginWrite();
        await _patchSingle(repo, op);
      } else {
        // 系列成员：先选择范围（文档 4.3）
        final scope = await _askScope(allowDelete: false);
        if (scope == null) {
          setState(() => _saving = false);
          return;
        }
        if (scope == 'one') {
          final op = repo.beginWrite();
          await _patchSingle(repo, op);
        } else {
          await _seriesUpdate(repo);
        }
      }
      navigated = mounted; // 成功路径：pop 前后都不再复位 _saving
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (e.isVersionConflict) {
        await _handleConflict(repo, e);
      } else {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '$e';
      });
    } finally {
      // 兜底保证：任何未预期路径都不会把表单永久锁在"保存中"。
      if (!navigated && mounted && _saving) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _patchSingle(EventRepository repo, IdempotentOp op) async {
    // 仅传播实际改变的字段（文档 5.3）；未修改字段保持原值。
    final changes = _changesForSeries();
    final input = PatchEventInput(
      expectedVersion: _orig.version,
      title: changes['title'] as String?,
      notes: changes['notes'] as String?,
      startAt: changes['start_at'] != null
          ? DateTime.parse(changes['start_at'] as String)
          : null,
      endAt: changes['end_at'] != null
          ? DateTime.parse(changes['end_at'] as String)
          : null,
      startDate: changes['start_date'] as String?,
      endDateExclusive: changes['end_date_exclusive'] as String?,
    );
    await repo.patch(_orig.id, input, op);
  }

  Future<void> _seriesUpdate(EventRepository repo) async {
    final changes = _changesForSeries();
    if (changes.isEmpty) {
      setState(() {
        _saving = false;
        _error = '没有检测到修改';
      });
      return;
    }
    final previewOp = repo.beginWrite();
    var preview = await repo.previewSeriesChange(
      _orig.id,
      SeriesChangePreviewInput(
        action: 'update',
        expectedVersion: _orig.version,
        changes: changes,
      ),
      previewOp,
    );
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('本次及以后'),
        content: Text('${preview.digest}\n\n共 ${preview.affectedCount} 个事件将被修改，且不会改动已结束的记录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认修改')),
        ],
      ),
    );
    if (confirmed != true) {
      setState(() => _saving = false);
      return;
    }
    try {
      final commitOp = repo.beginWrite();
      await repo.commitSeriesChange(_orig.id, preview.token, commitOp);
    } on ApiException catch (e) {
      if (e.isPreviewExpired) {
        // 预览失效：重新预览一次（成员/版本可能已变）
        final op2 = repo.beginWrite();
        preview = await repo.previewSeriesChange(
          _orig.id,
          SeriesChangePreviewInput(
            action: 'update',
            expectedVersion: _orig.version,
            changes: changes,
          ),
          op2,
        );
        final op3 = repo.beginWrite();
        await repo.commitSeriesChange(_orig.id, preview.token, op3);
      } else {
        rethrow;
      }
    }
  }

  Future<void> _delete() async {
    if (_saving || !_editing) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = context.read<EventRepository>();
    var navigated = false;
    try {
      if (!await confirmDelete(context, _orig.title)) {
        setState(() => _saving = false);
        return;
      }
      String scope = 'one';
      if (_orig.isSeriesMember) {
        final s = await _askScope(allowDelete: true);
        if (s == null) {
          setState(() => _saving = false);
          return;
        }
        scope = s;
      }
      if (scope == 'batch') {
        final previewOp = repo.beginWrite();
        final preview = await repo.previewSeriesChange(
          _orig.id,
          SeriesChangePreviewInput(action: 'delete', expectedVersion: _orig.version),
          previewOp,
        );
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除本次及以后'),
            content: Text('将删除 ${preview.affectedCount} 个事件（含选中的这次）。已结束的记录不会被删除。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor:
                          Theme.of(ctx).colorScheme.error),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('确认删除')),
            ],
          ),
        );
        if (confirmed != true) {
          setState(() => _saving = false);
          return;
        }
        final commitOp = repo.beginWrite();
        await repo.commitSeriesChange(_orig.id, preview.token, commitOp);
      } else {
        final op = repo.beginWrite();
        await repo.delete(_orig.id, _orig.version, op);
      }
      navigated = mounted; // 成功路径：pop 前后都不再复位 _saving
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (e.isVersionConflict) {
        await _handleConflict(repo, e);
      } else {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '$e';
      });
    } finally {
      // 兜底保证：任何未预期路径都不会把表单永久锁在"保存中"。
      if (!navigated && mounted && _saving) {
        setState(() => _saving = false);
      }
    }
  }

  /// 系列成员操作范围选择。返回 'one' | 'batch' | null（取消）。
  Future<String?> _askScope({required bool allowDelete}) =>
      askEventScope(context, isDelete: allowDelete);

  /// 409：保留用户输入，展示服务器新版本，由用户核对后再次保存（文档 8）。
  Future<void> _handleConflict(EventRepository repo, ApiException e) async {
    Event? serverEvent;
    try {
      final detail = await repo.get(_orig.id);
      serverEvent = detail.event;
    } catch (_) {
      serverEvent = null;
    }
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('事件已被其他设备修改'),
        content: serverEvent == null
            ? Text('${e.message}\n\n事件可能已被删除。')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('服务器上的当前内容：'),
                  const SizedBox(height: 6),
                  Text(
                    '「${serverEvent.title}」'
                    '${serverEvent.allDay ? '（全天 ${serverEvent.startDate} 起）' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text('你的输入已保留。可选择丢弃自己的修改，或以当前输入覆盖保存。'),
                ],
              ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep-mine'),
              child: const Text('保持我的输入')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'reload'),
              child: const Text('放弃修改，加载最新')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'overwrite'),
              child: const Text('以我的输入覆盖保存')),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'reload':
        Navigator.of(context).pop(true); // 触发外层刷新
      case 'overwrite':
        if (serverEvent == null) {
          setState(() {
            _saving = false;
            _error = '事件已被删除，无法覆盖保存';
          });
          return;
        }
        // 以服务器最新版本号重试一次（用户显式确认的最后写入胜出）
        _orig = serverEvent;
        setState(() => _saving = false);
        await _save();
      default:
        setState(() => _saving = false);
    }
  }

  // ---- UI ----

  Future<void> _pickDate({required bool isEnd}) async {
    final initial = DateTime.parse(
        '${isEnd ? _endDate : _startDate}T00:00:00');
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    final key = picked.toIso8601String().substring(0, 10);
    setState(() {
      if (isEnd) {
        _endDate = key;
        if (_endDate.compareTo(_startDate) < 0) _startDate = _endDate;
      } else {
        _startDate = key;
        if (_endDate.compareTo(_startDate) < 0) _endDate = _startDate;
      }
    });
  }

  Future<void> _pickTime({required bool isEnd}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isEnd ? _end : _start,
    );
    if (picked == null) return;
    setState(() => isEnd ? _end = picked : _start = picked);
  }

  @override
  Widget build(BuildContext context) {
    final endLabel = _allDay ? '最后一天（含）' : '结束';
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing ? '编辑事件' : '新建事件'),
          actions: [
            if (_editing)
              IconButton(
                tooltip: '删除',
                onPressed: _saving ? null : _delete,
                icon: const Icon(Icons.delete_outline),
              ),
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存'),
            ),
          ],
        ),
        body: AbsorbPointer(
          absorbing: _saving,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _title,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: '标题（必填）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('全天'),
                value: _allDay,
                onChanged: (v) => setState(() => _allDay = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _pickDate(isEnd: false),
                      child: Text(_allDay ? '开始：$_startDate' : '日期：$_startDate'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _pickDate(isEnd: true),
                      child: Text('$endLabel：$_endDate'),
                    ),
                  ),
                  if (!_allDay) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _pickTime(isEnd: false),
                      child: Text(_start.format(context)),
                    ),
                    const Text(' – '),
                    OutlinedButton(
                      onPressed: () => _pickTime(isEnd: true),
                      child: Text(_end.format(context)),
                    ),
                  ],
                ],
              ),
              if (!_editing) ...[
                const SizedBox(height: 16),
                const Text('重复'),
                RadioGroup<String?>(
                  groupValue: _repeatType,
                  onChanged: (v) => setState(() => _repeatType = v),
                  child: Column(
                    children: const [
                      RadioListTile<String?>(
                        value: null,
                        title: Text('不重复'),
                      ),
                      RadioListTile<String?>(
                        value: 'daily',
                        title: Text('每天'),
                      ),
                      RadioListTile<String?>(
                        value: 'weekdays',
                        title: Text('工作日（周一至周五）'),
                      ),
                      RadioListTile<String?>(
                        value: 'weekly',
                        title: Text('每周'),
                      ),
                      RadioListTile<String?>(
                        value: 'biweekly',
                        title: Text('每双周'),
                      ),
                    ],
                  ),
                ),
                if (_repeatType != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('总次数（含首次）'),
                    trailing: SizedBox(
                      width: 120,
                      child: TextFormField(
                        initialValue: '$_repeatCount',
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.end,
                        onChanged: (v) =>
                            _repeatCount = int.tryParse(v) ?? _repeatCount,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _notes,
                maxLines: 5,
                maxLength: 10000,
                decoration: const InputDecoration(
                  labelText: '备注（可空）',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
