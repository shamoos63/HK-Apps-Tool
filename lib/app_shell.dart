import 'package:flutter/material.dart';

import 'about_page.dart';
import 'app_shell_nav.dart';
import 'apkpure_search_page.dart';
import 'device_apps_page.dart';
import 'downloads_page.dart';
import 'local_install_page.dart';
import 'widgets/branded_app_bar.dart';
import 'services/combined_apk_store_service.dart';
import 'services/download_queue.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.install_mobile_outlined, label: 'Install'),
    (icon: Icons.search_rounded, label: 'Search'),
    (icon: Icons.download_rounded, label: 'Downloads'),
    (icon: Icons.apps_outlined, label: 'Device'),
    (icon: Icons.info_outline_rounded, label: 'About'),
  ];

  @override
  void initState() {
    super.initState();
    AppShellNav.register(_goTab);
  }

  @override
  void dispose() {
    CombinedApkStoreService.shared.close();
    AppShellNav.unregister();
    super.dispose();
  }

  void _goTab(int index) {
    if (!mounted) return;
    setState(() => _index = index.clamp(0, _destinations.length - 1));
  }

  Widget _railIcon(int index) {
    final iconData = _destinations[index].icon;
    final icon = Icon(iconData);
    if (index != kShellTabDownloads) return icon;
    final n = DownloadQueue.instance.activeRunningCount;
    if (n <= 0) return icon;
    return Badge(
      label: Text('$n'),
      isLabelVisible: true,
      child: icon,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const LocalInstallPage(),
      const ApkpureSearchPage(),
      const DownloadsPage(),
      const DeviceAppsPage(),
      const AboutPage(),
    ];
    return Scaffold(
      body: ListenableBuilder(
        listenable: DownloadQueue.instance,
        builder: (context, _) {
          return Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: _goTab,
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
                  child: Column(
                    children: [
                      Tooltip(
                        message: 'HK Apps Tool',
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: Image.asset(
                              kAppLogoAssetPath,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.high,
                              gaplessPlayback: true,
                              errorBuilder: (context, error, stackTrace) => Icon(
                                Icons.apps_rounded,
                                size: 40,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'HK Apps\nTool',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.15,
                              height: 1.15,
                            ),
                      ),
                    ],
                  ),
                ),
                destinations: [
                  for (var i = 0; i < _destinations.length; i++)
                    NavigationRailDestination(
                      icon: _railIcon(i),
                      selectedIcon: _railIcon(i),
                      label: Text(_destinations[i].label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                // Keep each tab's State alive so Search results / text survive tab switches.
                child: IndexedStack(
                  index: _index,
                  children: pages,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
