import 'package:flutter/material.dart';

import 'screens/admin_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/my_clubs_screen.dart';
import 'screens/profile_screen.dart';

class ClubsterApp extends StatelessWidget {
  const ClubsterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clubster',
      theme: ThemeData(useMaterial3: true),
      home: const NavShell(),
    );
  }
}

/// Bottom-nav shell wiring the four top-level sections together.
/// TODO: real routing (go_router or similar) once screens have content.
class NavShell extends StatefulWidget {
  const NavShell({super.key});

  @override
  State<NavShell> createState() => _NavShellState();
}

class _NavShellState extends State<NavShell> {
  int _selectedIndex = 0;

  static const _screens = [
    DiscoverScreen(),
    MyClubsScreen(),
    ProfileScreen(),
    AdminScreen(),
  ];

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: 'Discover',
    ),
    NavigationDestination(
      icon: Icon(Icons.groups_outlined),
      selectedIcon: Icon(Icons.groups),
      label: 'My Clubs',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: 'Profile',
    ),
    NavigationDestination(
      icon: Icon(Icons.admin_panel_settings_outlined),
      selectedIcon: Icon(Icons.admin_panel_settings),
      label: 'Admin',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: _destinations,
      ),
    );
  }
}
