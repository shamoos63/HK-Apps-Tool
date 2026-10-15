import 'dart:async';

import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'app_theme.dart';
import 'services/app_paths.dart';
import 'services/install_queue.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(AppPaths.purgeStaleExtractDirectories());
  unawaited(InstallQueue.instance.loadSettings());
  runApp(const HkAppsToolApp());
}

class HkAppsToolApp extends StatelessWidget {
  const HkAppsToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HK Apps Tool',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      darkTheme: buildAppDarkTheme(),
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}
