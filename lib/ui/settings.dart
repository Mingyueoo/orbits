import 'package:flutter/material.dart';
import 'package:orbits_new/theme/app_theme.dart';
import 'package:orbits_new/utils/bluetooth.dart';
import 'package:orbits_new/utils/permission.dart';
import 'package:orbits_new/utils/version.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/database/dao/binding_dao.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:orbits_new/plugins/ble_scan_service.dart';
import 'package:orbits_new/utils/secure_storage_service.dart';
import 'package:orbits_new/controllers/home_service_logic.dart';
import 'package:provider/provider.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  final DeviceDao deviceDao = DeviceDao();
  final BindingDao bindingDao = BindingDao();
  final SecureStorageService _secureStorageService = SecureStorageService();
  final BluetoothScanService _bluetoothScanService = BluetoothScanService();
  bool bluetoothGranted = false;
  bool isBluetoothOn = false;
  String appVersion = 'Loading...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 添加生命周期监听
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 移除生命周期监听
    super.dispose();
  }

  // 监听应用从后台回到前台
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshStatus();
    }
  }

  Future<void> _refreshStatus() async {
    final granted = await PermissionServiceShow.isNearbyPermissionGranted();
    final btOn = await BluetoothService.isBluetoothEnabled();
    final version = await VersionUtil.getAppVersion();
    setState(() {
      bluetoothGranted = granted;
      isBluetoothOn = btOn;
      appVersion = version;
    });
  }

  Future<void> _openPermissionSettings() async {
    await openAppSettings();
  }

  // 新增：跳转到系统蓝牙设置页面的方法
  Future<void> _openBluetoothSettings() async {
    // 假设 BluetoothService.openBluetoothSettings() 已经实现
    // 它会调用原生代码，跳转到系统的蓝牙设置页面
    await BluetoothService.openBluetoothSettings();
  }

  Future<void> _clearDevices() async {
    final confirmed = await _showConfirmationDialog(
      'Clear Devices',
      'Are you sure you want to clear all saved devices?',
    );
    if (confirmed) {
      await deviceDao.clearAll();
      // 重启扫描服务，使其重新获取空的UUID列表
      await _restartScanService();
      await bindingDao.deleteAllBindings();

      _showSnackBar(
        'All devices have been cleared. You will need to scan QR codes again to re-add devices.',
      );
    }
  }

  Future<void> _restartScanService() async {
    try {
      // 停止扫描服务
      await _bluetoothScanService.stopScanningService();

      // 重新启动扫描服务（此时会获取空的UUID列表）
      final String secretKey = await _secureStorageService
          .getOrCreateSecretKey();
      final List<String> knownUserUUIDs = await deviceDao
          .getAllUserUUIDs(); // 空列表

      await _bluetoothScanService.startScanningService(
        secretKey: secretKey,
        knownUserUUIDs: knownUserUUIDs, // 空列表
      );

      print("[Settings] Scan service restarted with empty UUID list");
    } catch (e) {
      print("[Settings] Error restarting scan service: $e");
    }
  }

  Future<void> _clearBindings() async {
    final confirmed = await _showConfirmationDialog(
      'Clear Bindings',
      'Are you sure you want to clear all contact bindings?',
    );
    if (confirmed) {
      await bindingDao.deleteAllBindings();
      _showSnackBar('All contact bindings have been cleared.');
    }
  }

  Future<bool> _showConfirmationDialog(String title, String content) async {
    return await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Clear'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 构建开机自启动开关
  Widget _buildAutoStartSwitch() {
    return FutureBuilder<bool>(
      future: _getAutoStartStatus(),
      builder: (context, snapshot) {
        final isEnabled = snapshot.data ?? false;

        return Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: SwitchListTile(
            title: const Text('Auto-start'),
            subtitle: const Text('Starts BLE service on boot'),
            value: isEnabled,
            onChanged: (value) async {
              await _setAutoStartEnabled(value);
              if (mounted) {
                setState(() {});
              }
            },
            secondary: const Icon(
              Icons.power_settings_new,
              color: AppTheme.primaryColor,
            ),
          ),
        );
      },
    );
  }

  /// 【新增】获取开机自启动状态
  Future<bool> _getAutoStartStatus() async {
    try {
      final logic = Provider.of<HomeServiceLogic>(context, listen: false);
      return await logic.isAutoStartEnabled();
    } catch (e) {
      print("[Settings] Error getting auto-start status: $e");
      return false;
    }
  }

  /// 设置开机自启动
  Future<void> _setAutoStartEnabled(bool enabled) async {
    try {
      final logic = Provider.of<HomeServiceLogic>(context, listen: false);
      await logic.setAutoStartEnabled(enabled);

      _showSnackBar(enabled ? 'Auto-start enabled' : 'Auto-start disabled');
    } catch (e) {
      print("[Settings] Error setting auto-start: $e");
      _showSnackBar('Failed to set auto-start: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Settings'),
        centerTitle: true,
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
      ),
      body: RefreshIndicator(
        onRefresh: _refreshStatus,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          children: [
            // 权限设置卡片
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.security,
                  color: AppTheme.primaryColor,
                ),
                title: const Text('Bluetooth Permissions'),
                subtitle: Text(bluetoothGranted ? 'Granted' : 'Not Granted'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: _openPermissionSettings,
                tileColor: bluetoothGranted
                    ? null
                    : Colors.red.withAlpha((255 * 0.05).round()),
              ),
            ),
            const SizedBox(height: 10),

            // 蓝牙状态设置卡片
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.bluetooth,
                  color: AppTheme.primaryColor,
                ),
                title: const Text('Bluetooth Status'),
                subtitle: Text(isBluetoothOn ? 'Enabled' : 'Disabled'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: _openBluetoothSettings,
              ),
            ),
            const SizedBox(height: 10),
            // 开机自启动开关卡片
            _buildAutoStartSwitch(),
            const SizedBox(height: 10),

            // 数据清除卡片
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.delete_forever,
                      color: Colors.red,
                    ),
                    title: const Text('Clear Saved Devices'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _clearDevices,
                  ),
                  const Divider(height: 0, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.link_off, color: Colors.red),
                    title: const Text('Clear Contact Bindings'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _clearBindings,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // 应用信息卡片
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.info_outline,
                  color: AppTheme.primaryColor,
                ),
                title: const Text('App Version'),
                trailing: Text(appVersion),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
