import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_shell.dart';
import 'app_theme.dart';
import 'services/app_paths.dart';
import 'services/install_queue.dart';
import 'widgets/window_title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(AppPaths.purgeStaleExtractDirectories());
  unawaited(InstallQueue.instance.loadSettings());
  await ThemeController.instance.load();

  if (useCustomTitleBar) {
    // Hide the system title bar; the app draws its own (see WindowTitleBar).
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
        minimumSize: Size(980, 640),
        title: 'HK Apps Tool',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  runApp(const HkAppsToolApp());
}

class HkAppsToolApp extends StatelessWidget {
  const HkAppsToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (context, mode, _) => MaterialApp(
        title: 'HK Apps Tool',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildAppDarkTheme(),
        themeMode: mode,
        home: const AppShell(),
      ),
    );
  }
}
