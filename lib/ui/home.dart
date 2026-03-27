import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:orbits_new/theme/app_theme.dart';
import 'package:orbits_new/ui/qr_displayer.dart';
import 'package:orbits_new/ui/qr_scanner.dart';
import 'package:orbits_new/widgets/interactive_card.dart';
import 'package:orbits_new/widgets/info_card.dart';
import 'package:orbits_new/controllers/home_service_logic.dart'; // 导入新的业务逻辑类
import 'package:orbits_new/utils/qr_service.dart';
// import 'package:orbits_new/background/ble_work_manager.dart';
import 'package:orbits_new/utils/time_formatter.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 延迟初始化，确保Provider已准备好
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeApp();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 应用初始化逻辑
  Future<void> _initializeApp() async {
    try {
      final logic = Provider.of<HomeServiceLogic>(context, listen: false);

      // 1. 等待HomeServiceLogic初始化完成
      await Future.delayed(const Duration(milliseconds: 200));

      // 1. 先加载数据库数据
      await _loadDatabaseData(logic);

      print("[HomePage] App initialization completed successfully");
    } catch (e) {
      print("[HomePage] Error during app initialization: $e");
    }
  }

  /// 加载数据库数据
  Future<void> _loadDatabaseData(HomeServiceLogic logic) async {
    try {
      // 等待数据库加载完成
      await Future.delayed(const Duration(milliseconds: 500));

      // 获取已知设备列表
      final knownUserUUIDs = await logic.getKnownUserUUIDs();

      print(
        "[HomePage] Database loaded with ${knownUserUUIDs.length} known devices: $knownUserUUIDs",
      );
    } catch (e) {
      print("[HomePage] Error loading database data: $e");
    }
  }

  /// 监听应用程序生命周期状态变化，并通知逻辑层
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 获取 HomeServiceLogic 实例并调用相应方法
    final logic = Provider.of<HomeServiceLogic>(context, listen: false);
    logic.setModeForLifecycle(state);
  }

  /// 显示一个简单的对话框
  void _showDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Confirm"),
          ),
        ],
      ),
    );
  }

  /// 生成并显示我的二维码
  Future<void> _showMyQrCode(BuildContext context) async {
    final qrData = await QrService.instance.generateMyQrData();
    final userUuid = jsonDecode(qrData)['userUuid'] as String;
    if (!context.mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QrCodeDisplayPage(qrData: qrData, userUuid: userUuid),
      ),
    );
  }

  /// 启动二维码扫描器
  Future<void> _scanQrCode(BuildContext context) async {
    final hasPermission = await QrService.instance.requestCameraPermission();
    if (!hasPermission) {
      if (!context.mounted) return;
      _showDialog(
        context,
        "permission denied",
        "Please enable camera permissions in settings.",
      );
      return;
    }

    final result = await Navigator.push<String?>(
      context,
      MaterialPageRoute(builder: (_) => const QRScannerPage()),
    );

    if (result == null) return;

    try {
      final device = await QrService.instance.processScannedQrData(result);
      // 扫描成功后刷新扫描服务的UUID列表
      await _refreshScanServiceAfterQrScan();

      if (!context.mounted) return;
      _showDialog(
        context,
        "Added successfully",
        "${device.uuid}  added as a contact",
      );
    } catch (e) {
      if (!context.mounted) return;
      _showDialog(context, "QR Code Invalid", e.toString());
    }
  }

  /// 二维码扫描成功后刷新扫描服务
  Future<void> _refreshScanServiceAfterQrScan() async {
    try {
      final logic = Provider.of<HomeServiceLogic>(context, listen: false);
      await logic.refreshScanServiceUUIDs();
      print("[HomePage] Scan service UUIDs refreshed after QR scan");
    } catch (e) {
      print("[HomePage] Error refreshing scan service: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    // 使用 Consumer 来监听 HomeServiceLogic 的变化，当数据更新时，只重建这部分 UI
    return Consumer<HomeServiceLogic>(
      builder: (context, logic, child) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text("Orbitz"),
            centerTitle: true,
            backgroundColor: AppTheme.primaryColor.withAlpha(
              (255 * 0.9).round(),
            ),
            foregroundColor: Colors.white,
          ),
          backgroundColor: theme.scaffoldBackgroundColor,
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Circular Status Display
                  Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          AppTheme.primaryColor.withOpacity(0.85),
                          AppTheme.primaryColor.withOpacity(0.3),
                        ],
                        center: Alignment.center,
                        radius: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryColor.withOpacity(0.3),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),

                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            logic.currentMode == BleWorkMode.highFrequency
                                ? Icons.speed
                                : Icons.power_settings_new,
                            size: 48,
                            color: Colors.white,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            logic.currentMode == BleWorkMode.highFrequency
                                ? "High Frequency"
                                : "Low Power",
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Mode Switch Buttons
                  ElevatedButton(
                    onPressed: () {
                      // 切换模式：如果当前是 High Frequency，则切换到 Low Power；否则切换到 High Frequency。
                      if (logic.currentMode == BleWorkMode.highFrequency) {
                        logic.setServiceMode(BleWorkMode.lowPower);
                      } else {
                        logic.setServiceMode(BleWorkMode.highFrequency);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      // 按钮的颜色取决于当前的模式
                      backgroundColor:
                          logic.currentMode == BleWorkMode.highFrequency
                          ? AppTheme.accentColor
                          : AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      // 按钮的文本也取决于当前的模式
                      logic.currentMode == BleWorkMode.highFrequency
                          ? 'Switch to Low Power'
                          : 'Switch to High Frequency',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Info Cards Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      StreamBuilder<int>(
                        stream: logic.deviceCountStream,
                        builder: (context, snapshot) {
                          final count = snapshot.data ?? 0;
                          return InfoCard(
                            label: "Devices Found",
                            value: "$count",
                            color: AppTheme.primaryColor.withAlpha(
                              (255 * 0.8).round(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 16),
                      // 同样为总时间创建一个 StreamBuilder
                      StreamBuilder<int>(
                        stream: logic.totalMinutesStream,
                        builder: (context, snapshot) {
                          print(
                            "[UI] StreamBuilder update - connectionState: ${snapshot.connectionState}, data: ${snapshot.data}, error: ${snapshot.error}",
                          );
                          final minutes = snapshot.data ?? 0;
                          // 使用时间格式化工具
                          final formattedTime =
                              TimeFormatter.formatMinutesToHoursMinutes(
                                minutes,
                              );
                          return InfoCard(
                            label: "Contact Time",
                            value: formattedTime,
                            color: AppTheme.accentColor.withAlpha(
                              (255 * 0.7).round(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // QR Code Cards
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      InteractiveCard(
                        label: "My QR Code",
                        icon: Icons.qr_code,
                        onTap: () => _showMyQrCode(context),
                        color: AppTheme.primaryColor.withAlpha(
                          (255 * 0.7).round(),
                        ),
                      ),
                      const SizedBox(width: 16),
                      InteractiveCard(
                        label: "Add Contact",
                        icon: Icons.qr_code_scanner,
                        onTap: () => _scanQrCode(context),
                        color: AppTheme.accentColor.withAlpha(
                          (255 * 0.7).round(),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Status Message
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text(
                      logic.serviceStatusMessage,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
