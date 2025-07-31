import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:orbits_new/plugins/ble_uuid_broadcaster.dart';
import 'package:orbits_new/plugins/ble_scan_service.dart';
import 'package:orbits_new/background/ble_work_manager.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/theme/app_theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  String _serviceStatusMessage = 'Service not started';
  bool _isServiceRunning = false;
  final DeviceDao deviceDao = DeviceDao();
  int deviceCount = 0;
  int totalMinutes = 0;

  final BluetoothScanService _bluetoothScanService = BluetoothScanService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bluetoothScanService.init();
    _checkInitialServiceStatus();

    _loadStats(); //load devices
  }

  Future<void> _loadStats() async {
    final count = await deviceDao.getDeviceCount();
    final minutes = await deviceDao.getTotalContactMinutes();

    setState(() {
      deviceCount = count;
      totalMinutes = minutes;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAllServices();
    _bluetoothScanService.dispose();
    super.dispose();
  }

  /// 检查原生服务的初始运行状态并同步 UI
  Future<void> _checkInitialServiceStatus() async {
    final bool broadcastRunning = await BleUuidBroadcaster.isServiceRunning();
    final bool scanServiceRunning = await _bluetoothScanService
        .isServiceRunning();

    setState(() {
      _isServiceRunning = broadcastRunning || scanServiceRunning;
      _updateServiceStatusDisplay(_isServiceRunning);
    });

    if (_isServiceRunning) {
      BleUuidBroadcaster.setAdvertisingMode('high_frequency');
      _bluetoothScanService.setScanMode('high_frequency');
    }
  }

  /// 监听应用程序生命周期状态变化
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isServiceRunning) {
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        print('App entered foreground');
        BleUuidBroadcaster.setAdvertisingMode('high_frequency');
        _bluetoothScanService.setScanMode('high_frequency');
        _updateServiceStatusDisplay(true, mode: 'Foreground High-Freq');
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        print('App entered background or is hidden');
        BleUuidBroadcaster.setAdvertisingMode('low_power');
        _bluetoothScanService.setScanMode('low_power');
        _updateServiceStatusDisplay(true, mode: 'Background Low-Power');
        break;
      default:
        break;
    }
  }

  /// 启动所有 BLE 服务
  Future<void> _startAllServices() async {
    if (_isServiceRunning) return;

    try {
      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        _showDialog(
          'Bluetooth Off',
          'Please enable Bluetooth in system settings and try again.',
        );
        return;
      }

      final Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      if (statuses.values.any((status) => status.isDenied)) {
        _showDialog(
          'Permissions Denied',
          'Bluetooth detection service requires Bluetooth and location permissions. Please grant them in app settings.',
        );
        return;
      }

      await BleUuidBroadcaster.startBroadcast();
      await _bluetoothScanService.startScanningService();
      await registerBleScanTask();

      BleUuidBroadcaster.setAdvertisingMode('high_frequency');
      _bluetoothScanService.setScanMode('high_frequency');

      setState(() {
        _isServiceRunning = true;
        _updateServiceStatusDisplay(true, mode: 'Foreground High-Freq');
      });
    } on PlatformException catch (e) {
      setState(() {
        _isServiceRunning = false;
        _updateServiceStatusDisplay(false, error: 'Start failed: ${e.message}');
      });
    } catch (e) {
      setState(() {
        _isServiceRunning = false;
        _updateServiceStatusDisplay(false, error: 'Start failed: $e');
      });
    }
  }

  /// 停止所有 BLE 服务
  Future<void> _stopAllServices() async {
    if (!_isServiceRunning) return;

    try {
      await BleUuidBroadcaster.stopBroadcast();
      await _bluetoothScanService.stopScanningService();
      await cancelBleScanTask();

      setState(() {
        _isServiceRunning = false;
        _updateServiceStatusDisplay(false);
      });
    } on PlatformException catch (e) {
      setState(() {
        _isServiceRunning = true;
        _updateServiceStatusDisplay(true, error: 'Stop failed: ${e.message}');
      });
    } catch (e) {
      setState(() {
        _isServiceRunning = true;
        _updateServiceStatusDisplay(true, error: 'Stop failed: $e');
      });
    }
  }

  /// 更新 UI 上服务的状态显示
  void _updateServiceStatusDisplay(
    bool running, {
    String? error,
    String mode = '',
  }) {
    setState(() {
      if (error != null) {
        _serviceStatusMessage = 'Bluetooth Detection Service: Error - $error';
      } else if (running) {
        _serviceStatusMessage = 'Bluetooth Detection Service: Active ($mode)';
      } else {
        _serviceStatusMessage = 'Bluetooth Detection Service: Off';
      }
    });
  }

  /// 显示一个简单的对话框
  void _showDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Orbits"),
        centerTitle: true,
        backgroundColor: AppTheme.primaryColor.withOpacity(0.9),
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
                      const Icon(
                        Icons.bluetooth_searching,
                        size: 48,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isServiceRunning ? "Active" : "Inactive",
                        style: const TextStyle(
                          fontSize: 20,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              //
              ElevatedButton(
                onPressed: () {
                  if (_isServiceRunning) {
                    _stopAllServices();
                  } else {
                    _startAllServices();
                  }
                },
                style: ElevatedButton.styleFrom(
                  // 根据状态改变背景颜色
                  backgroundColor: _isServiceRunning
                      ? AppTheme.primaryColor
                      : AppTheme.accentColor,
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
                  // 根据状态改变按钮文本
                  _isServiceRunning ? 'Stop Service' : 'Start Service',
                  style: const TextStyle(fontSize: 16),
                ),
              ),

              const SizedBox(height: 32),

              // Info Cards Row
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _InfoCard(
                    label: "Devices Found",
                    value: "$deviceCount",
                    color: AppTheme.primaryColor.withOpacity(0.8),
                  ),
                  const SizedBox(width: 16),
                  _InfoCard(
                    label: "Contact Time",
                    value: "$totalMinutes",
                    color: AppTheme.accentColor.withOpacity(0.7),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Optional cards (for future actions or toggles)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _InfoCard(
                    label: "Optional cards",
                    value: "-",
                    color: AppTheme.primaryColor.withOpacity(0.7),
                  ),
                  const SizedBox(width: 16),
                  _InfoCard(
                    label: "Optional cards",
                    value: "-",
                    color: AppTheme.accentColor.withOpacity(0.7),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _InfoCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
