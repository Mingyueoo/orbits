import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orbits_new/ui/app_shell.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // 使用 WidgetsBinding.instance.addPostFrameCallback 确保在帧渲染完成后执行导航。
    // 这可以确保 BuildContext 完全可用，避免在 widget 树未完全构建时尝试导航。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkFirstLaunch();
    });
  }

  // 检查是否首次启动应用
  Future<void> _checkFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    final bool? isFirstLaunch = prefs.getBool('is_first_launch');

    if (isFirstLaunch == null || !isFirstLaunch) {
      // 如果是第一次启动 (标志不存在或为 false)

      await prefs.setBool('is_first_launch', true); // 设置为已启动
      // 延迟 3 秒后跳转到主页面
      Future.delayed(const Duration(seconds: 3), () {
        // 确保 widget 仍然挂载在树上，以避免在异步操作后使用无效的 context
        if (mounted) {
          Navigator.pushReplacementNamed(context, AppShell.routeName);
        }
      });
    } else {
      if (mounted) {
        Navigator.pushReplacementNamed(context, AppShell.routeName);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FlutterLogo(size: 100), // Flutter Logo 作为示例
            SizedBox(height: 20),
            Text(
              'Welcome to the Orbitz',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 10),
            CircularProgressIndicator(), // 显示一个加载指示器
          ],
        ),
      ),
    );
  }
}
