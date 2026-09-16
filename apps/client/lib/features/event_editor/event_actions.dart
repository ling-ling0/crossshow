/// 事件操作：范围选择对话框 + 快捷删除（列表/时间轴的详情卡片使用）。
/// 编辑器内的删除仍走编辑页自己的冲突处理流程；本文件的快捷删除
/// 冲突时仅提示，复杂处理引导用户进入编辑页。
library;

import 'package:flutter/material.dart';

import '../../core/models/errors.dart';
import '../../core/models/models.dart';
import '../../core/repositories/event_repository.dart';

/// 系列成员操作范围选择。返回 'one' | 'batch' | null（取消）。
Future<String?> askEventScope(
  BuildContext context, {
  required bool isDelete,
}) {
  final label = isDelete ? '删除' : '修改';
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('$label重复事件'),
      content: Text('这是重复事件中的一次。要$label的范围是？'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'batch'),
            child: const Text('本次及以后')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, 'one'),
            child: const Text('仅本次')),
      ],
    ),
  );
}

/// 删除确认对话框：所有删除路径（快捷删除、编辑器删除、单次/批量）共用。
Future<bool> confirmDelete(BuildContext context, String title) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('确认删除'),
      content: Text('确定删除「$title」吗？此操作无法撤销。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// 快捷删除：先确认；系列成员再问范围；"本次及以后"走预览→确认→提交。
/// 返回是否删除成功（用户取消返回 false）。
Future<bool> quickDeleteEvent(
  BuildContext context,
  EventRepository repo,
  Event event,
) async {
  if (!context.mounted) return false;
  if (!await confirmDelete(context, event.title)) return false;
  if (!context.mounted) return false;
  var scope = 'one';
  if (event.isSeriesMember) {
    scope = await askEventScope(context, isDelete: true) ?? 'cancel';
    if (scope == 'cancel') return false;
  }
  try {
    if (scope == 'batch') {
      final previewOp = repo.beginWrite();
      final preview = await repo.previewSeriesChange(
        event.id,
        SeriesChangePreviewInput(
            action: 'delete', expectedVersion: event.version),
        previewOp,
      );
      if (!context.mounted) return false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除本次及以后'),
          content:
              Text('将删除 ${preview.affectedCount} 个事件（含选中的这次）。已结束的记录不会被删除。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return false;
      final commitOp = repo.beginWrite();
      await repo.commitSeriesChange(event.id, preview.token, commitOp);
    } else {
      final op = repo.beginWrite();
      await repo.delete(event.id, event.version, op);
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.isVersionConflict
            ? '事件已被其他设备修改，请打开事件后处理'
            : '删除失败：${e.message}'),
      ));
    }
    return false;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
    return false;
  }
}
