import 'package:flutter/material.dart';
import 'package:provider/provider.dart'; // 导入 provider 包
import 'package:orbits_new/background/ble_work_manager.dart';
import 'package:orbits_new/ui/splash_screen.dart';
import 'package:orbits_new/ui/app_shell.dart';
import 'package:orbits_new/ui/home.dart';
import 'package:orbits_new/controllers/home_service_logic.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // 确保 Flutter 绑定已初始化
  await initWorkManager(); // 初始化 WorkManager

  runApp(
    // Use ChangeNotifierProvider instead of the generic Provider
    ChangeNotifierProvider<HomeServiceLogic>(
      create: (_) => HomeServiceLogic(), // Instantiate your ChangeNotifier
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const SplashScreen(), // 如果需要欢迎页，请取消注释
      // home: const HomePage(), // 将主页设置为 HomePage
      title: 'Orbits Application',
      routes: {
        AppShell.routeName: (context) => const AppShell(),
        '/home': (context) => const HomePage(),
      },
    );
  }
}
