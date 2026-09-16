/// 设置页（开发文档 6.3 / 9.2）：服务器 URL 输入、连接测试、同步信息。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/repositories/event_repository.dart';
import '../../core/settings/settings_store.dart';
import '../../core/sync/sync_controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url;
  bool _testing = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: context.read<SettingsStore>().baseUrl ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    final raw = _url.text.trim();
    if (raw.isEmpty) {
      setState(() => _result = '请输入服务器地址');
      return;
    }
    final normalized = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      setState(() => _result = '地址需以 http:// 或 https:// 开头');
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    final settings = context.read<SettingsStore>();
    final repo = context.read<EventRepository>();
    await settings.setBaseUrl(normalized);
    repo.baseUrl = normalized;
    try {
      final cfg = await repo.config();
      setState(() {
        _result = '连接成功：服务端时区 ${cfg.timezone}';
        _testing = false;
      });
      if (mounted) context.read<SyncController>().refreshAll();
    } catch (e) {
      setState(() {
        _result = '连接失败：$e';
        _testing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final lastSync = settings.lastSyncAt?.toLocal();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('服务器'),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'http://192.168.1.10:8080',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _testing ? null : _saveAndTest,
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_sync_outlined),
            label: const Text('保存并测试连接'),
          ),
          if (_result != null) ...[
            const SizedBox(height: 8),
            Text(_result!),
          ],
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('最近成功同步'),
            subtitle: Text(lastSync == null
                ? '从未同步'
                : '${lastSync.year}-${lastSync.month.toString().padLeft(2, '0')}-${lastSync.day.toString().padLeft(2, '0')} '
                    '${lastSync.hour.toString().padLeft(2, '0')}:${lastSync.minute.toString().padLeft(2, '0')}'),
          ),
          const Divider(height: 32),
          const Text('关于'),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('CrossShow'),
            subtitle: Text('v0.1.0 · 日历时区固定为 Asia/Shanghai · 首版无账号体系，请勿在公共网络暴露服务端口'),
          ),
        ],
      ),
    );
  }
}
