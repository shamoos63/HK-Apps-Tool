import 'package:flutter/material.dart';

/// Declared as a Flutter asset (see pubspec.yaml).
const String kAppLogoAssetPath = 'Logo.png';

/// [AppBar] with the HK Apps Tool logo replacing the default back/menu affordance area.
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
    const logoSize = 30.0;
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 8,
      leading: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        child: Tooltip(
          message: 'HK Apps Tool',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              kAppLogoAssetPath,
              width: logoSize,
              height: logoSize,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.apps_rounded,
                size: logoSize,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
      leadingWidth: 48,
      title: title,
      actions: actions,
    );
  }
}
