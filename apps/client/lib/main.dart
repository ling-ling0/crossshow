/// CrossShow 客户端入口。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/network/api_client.dart';
import 'core/repositories/event_repository.dart';
import 'core/settings/settings_store.dart';
import 'core/time/holidays.dart';
import 'core/sync/sync_controller.dart';
import 'features/calendar/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Holidays.load(); // 法定假日数据（assets/holidays.json）
  final settings = await SettingsStore.load();
  final api = ApiClient()..baseUrl = settings.baseUrl;
  final repository = EventRepository(api);

  runApp(CrossShowApp(
    settings: settings,
    repository: repository,
  ));
}

class CrossShowApp extends StatelessWidget {
  const CrossShowApp({
    super.key,
    required this.settings,
    required this.repository,
  });

  final SettingsStore settings;
  final EventRepository repository;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: settings),
        Provider.value(value: repository),
        ChangeNotifierProvider(
          create: (_) => SyncController(repository: repository, settings: settings),
        ),
      ],
      child: MaterialApp(
        title: 'CrossShow',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3A6EA5)),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF3A6EA5),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const CalendarHomePage(),
      ),
    );
  }
}
