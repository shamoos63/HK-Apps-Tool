import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      home: const AppShell(),
    );
  }
}
