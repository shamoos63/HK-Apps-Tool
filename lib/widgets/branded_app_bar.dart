import 'package:flutter/material.dart';

/// Declared as a Flutter asset (see pubspec.yaml).
const String kAppLogoAssetPath = 'Logo.png';

/// Page [AppBar] used by every tab.
class BrandedAppBar extends StatelessWidget implements PreferredSizeWidget {
  const BrandedAppBar({
    super.key,
    required this.title,
    this.actions,
  });

  final Widget title;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    // The logo already sits in the navigation rail (and the title bar on Windows).
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 20,
      title: title,
      actions: actions,
    );
  }
}
