import 'package:flutter/material.dart';
import 'package:orbits_new/background/ble_work_manager.dart';
import 'package:orbits_new/ui/splash_screen.dart';
import 'package:orbits_new/ui/app_shell.dart';
import 'package:orbits_new/ui/home.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // 确保 Flutter 绑定已初始化
  await initWorkManager(); // 初始化 WorkManager
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const SplashScreen(), // 如果需要欢迎页，请取消注释
      // home: const HomePage(), // 将主页设置为 HomePage
      title: 'Orbits Application',
      routes: {
        AppShell.routeName: (context) => const AppShell(), // 主应用框架路由
        // 以下是其他页面的路由定义。
        // 尽管这些页面主要在 AppShell 内部通过 PageView 管理，
        // 但如果需要从应用的其他部分（例如，通知点击或深层链接）直接导航到它们，
        // 它们作为顶级路由会很有用。
        // '/home': (context) => const HomePage(),
        '/home': (context) => const HomePage(),

        // '/contact_history': (context) => const DeviceTestListPage(),
        //
        // '/contact': (context) => const ContactListPage(),
        // '/settings': (context) => const SettingsPage(),
        // '/scan': (context) => const ScanWidget(),
      },
    );
  }
}
