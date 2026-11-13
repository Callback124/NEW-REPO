import 'package:flutter/material.dart';

import 'bubble_nav_bar.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.init();
  runApp(const StratusApp());
}

ThemeData _theme(Brightness b) {
  final dark = b == Brightness.dark;
  final bg = dark ? const Color(0xFF0D0E12) : const Color(0xFFF5F5F8);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4A5AF0), brightness: b)
      .copyWith(surface: bg);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF16181E) : Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      fillColor: dark ? const Color(0xFF1F222A) : const Color(0xFFEBECF1),
    ),
  );
}

class StratusApp extends StatelessWidget {
  const StratusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: 'Stratus',
        debugShowCheckedModeBanner: false,
        themeMode: app.theme,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const Shell(),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _i = 0;

  static const _pages = <Widget>[HomePage(), SearchPage(), LibraryPage(), SettingsPage()];
  static const _dest = <({IconData icon, IconData selected, String label})>[
    (icon: Icons.home_outlined, selected: Icons.home, label: 'Home'),
    (icon: Icons.search, selected: Icons.search, label: 'Search'),
    (icon: Icons.bookmark_border, selected: Icons.bookmark, label: 'Library'),
    (icon: Icons.tune, selected: Icons.tune, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final body = IndexedStack(index: _i, children: _pages);
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _i,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (v) => setState(() => _i = v),
              destinations: [
                for (final d in _dest)
                  NavigationRailDestination(
                      icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
              ],
            ),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: BubbleNavBar(
        index: _i,
        onChanged: (v) => setState(() => _i = v),
        items: [
          for (final d in _dest)
            BubbleNavItem(icon: d.icon, selectedIcon: d.selected, label: d.label),
        ],
      ),
    );
  }
}
