import 'package:flutter/material.dart';
import 'package:orbits_new/theme/app_theme.dart';


import 'package:orbits_new/ui/contact_list.dart';
import 'package:orbits_new/ui/settings.dart';
import 'package:orbits_new/ui/home.dart';
import 'package:orbits_new/ui/device_record.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  static const String routeName = '/app_shell';

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  late PageController _pageController;

  static const List<Widget> _pages = <Widget>[
    HomePage(),
    DeviceRecord(),
    ContactListPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _selectedIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      // appBar: AppBar(
      //   title: const Text('Orbits'),
      //   centerTitle: true,
      //   backgroundColor: AppTheme.primaryColor.withOpacity(0.9),
      //   foregroundColor: Colors.white,
      //   elevation: 0.5,
      // ),
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: _pages,
        onPageChanged: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.device_hub_rounded),
            label: 'Records',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.supervised_user_circle_rounded),
            label: 'Contact',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: AppTheme.primaryColor,
        unselectedItemColor: Colors.grey.withOpacity(0.7),
        backgroundColor: Colors.white.withOpacity(0.96),
        onTap: _onItemTapped,
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 12,
        unselectedFontSize: 12,
        showUnselectedLabels: true,
        elevation: 8,
      ),
    );
  }
}
