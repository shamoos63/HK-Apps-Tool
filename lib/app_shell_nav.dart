/// Indices must match the `pages` list in [AppShell].
const int kShellTabInstall = 0;
const int kShellTabSearch = 1;
const int kShellTabDownloads = 2;
const int kShellTabDevice = 3;
const int kShellTabAbout = 4;

/// Lets other pages switch the navigation rail tab (e.g. open Downloads after starting a fetch).
class AppShellNav {
  AppShellNav._();

  static void Function(int index)? _go;

  static void register(void Function(int index) fn) => _go = fn;

  static void unregister() => _go = null;

  static void goTo(int index) => _go?.call(index);
}
