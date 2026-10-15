import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app_theme.dart';
import 'branded_app_bar.dart' show kAppLogoAssetPath;

/// Windows and Linux draw their own title bar (the system one is hidden at startup).
/// macOS keeps its native traffic lights.
bool get useCustomTitleBar =>
    Platform.isWindows || Platform.isLinux || Platform.environment['HK_CUSTOM_TITLEBAR'] == '1';

/// In-app title bar: drag to move, double-click to maximize, theme switch,
/// and minimize / maximize / close buttons.
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key});

  static const height = 40.0;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _maximized = false;
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);
  @override
  void onWindowFocus() => setState(() => _focused = true);
  @override
  void onWindowBlur() => setState(() => _focused = false);

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final fg = _focused ? scheme.onSurface : scheme.onSurfaceVariant;
    return Container(
      height: WindowTitleBar.height,
      decoration: BoxDecoration(
        color: dark ? scheme.surfaceContainerLowest : scheme.surface,
        border: dark ? null : Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(
                child: DragToMoveArea(
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.asset(kAppLogoAssetPath, width: 20, height: 20, fit: BoxFit.cover),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'HK Apps Tool',
                        style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.2),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
              _ThemeSwitch(color: fg),
              const SizedBox(width: 6),
              _CaptionButton(
                tooltip: 'Minimize',
                icon: Icons.horizontal_rule_rounded,
                color: fg,
                onPressed: windowManager.minimize,
              ),
              _CaptionButton(
                tooltip: _maximized ? 'Restore' : 'Maximize',
                icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
                iconSize: _maximized ? 14 : 16,
                color: fg,
                onPressed: _toggleMaximize,
              ),
              _CaptionButton(
                tooltip: 'Close',
                icon: Icons.close_rounded,
                color: fg,
                hoverColor: const Color(0xFFE81123),
                hoverIconColor: Colors.white,
                onPressed: windowManager.close,
              ),
            ],
          ),
          if (dark)
            // Thin neon line along the bottom edge.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 1.5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    scheme.primary.withValues(alpha: 0.0),
                    scheme.primary,
                    scheme.secondary,
                    scheme.tertiary.withValues(alpha: 0.0),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThemeSwitch extends StatelessWidget {
  const _ThemeSwitch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final mode = ThemeController.instance.value;
    final icon = switch (mode) {
      ThemeMode.light => Icons.light_mode_rounded,
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };
    return PopupMenuButton<ThemeMode>(
      tooltip: 'Theme',
      initialValue: mode,
      position: PopupMenuPosition.under,
      onSelected: ThemeController.instance.set,
      itemBuilder: (_) => const [
        PopupMenuItem(value: ThemeMode.light, child: _ThemeItem(Icons.light_mode_rounded, 'Light')),
        PopupMenuItem(value: ThemeMode.dark, child: _ThemeItem(Icons.dark_mode_rounded, 'Dark (neon)')),
        PopupMenuItem(value: ThemeMode.system, child: _ThemeItem(Icons.brightness_auto_rounded, 'Match system')),
      ],
      child: GestureDetector(
        onDoubleTap: () => ThemeController.instance.toggle(brightness),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

class _ThemeItem extends StatelessWidget {
  const _ThemeItem(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
      );
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.iconSize = 16,
    this.hoverColor,
    this.hoverIconColor,
  });

  final String tooltip;
  final IconData icon;
  final double iconSize;
  final Color color;
  final Color? hoverColor;
  final Color? hoverIconColor;
  final Future<void> Function() onPressed;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final hoverBg = widget.hoverColor ?? (dark ? scheme.primary.withValues(alpha: 0.14) : scheme.primaryContainer);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 46,
            height: WindowTitleBar.height,
            color: _hover ? hoverBg : Colors.transparent,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hover ? (widget.hoverIconColor ?? (dark ? scheme.primary : scheme.primary)) : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}
