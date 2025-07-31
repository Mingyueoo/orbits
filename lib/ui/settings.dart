import 'package:flutter/material.dart';
import 'package:orbits_new/theme/app_theme.dart';

import 'package:orbits_new/utils/bluetooth.dart';
import 'package:orbits_new/utils/permission.dart';
import 'package:orbits_new/utils/version.dart';

import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/database/dao/binding_dao.dart';
import 'package:permission_handler/permission_handler.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final DeviceDao deviceDao = DeviceDao();
  final BindingDao bindingDao = BindingDao();
  bool bluetoothGranted = false;
  bool isBluetoothOn = false;
  String appVersion = 'Loading...';

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final granted = await PermissionService.isNearbyPermissionGranted();
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

  Future<void> _openBluetoothSettings() async {
    await BluetoothService.openBluetoothSettings();
  }

  Future<void> _clearDevices() async {
    await deviceDao.clearAll();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All devices have been cleared.')),
    );
  }

  Future<void> _clearBindings() async {
    await bindingDao.deleteAllBindings();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All contact bindings have been cleared.')),
    );
  }

  Widget _buildCard({required String title, required List<Widget> children}) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: Colors.white.withOpacity(0.85),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppTheme.primaryColor,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(String label, String status, {Color? statusColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 16, color: Colors.black87),
        ),
        Text(
          status,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: statusColor ?? AppTheme.accentColor,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(String text, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(text, style: const TextStyle(fontSize: 16)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App Settings')),
      body: RefreshIndicator(
        onRefresh: _refreshStatus,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 20),
          children: [
            _buildCard(
              title: 'Permission Status',
              children: [
                _buildStatusRow(
                  'Bluetooth Permission:',
                  bluetoothGranted ? 'Granted' : 'Not Granted',
                  statusColor: bluetoothGranted ? Colors.green : Colors.red,
                ),
                const SizedBox(height: 8),
                _buildActionButton(
                  'Manage Permissions',
                  _openPermissionSettings,
                ),
              ],
            ),
            _buildCard(
              title: 'Bluetooth Settings',
              children: [
                _buildStatusRow(
                  'Bluetooth Status:',
                  isBluetoothOn ? 'Enabled' : 'Disabled',
                  statusColor: isBluetoothOn ? Colors.green : Colors.red,
                ),
                const SizedBox(height: 8),
                _buildActionButton(
                  'Go to Bluetooth Settings',
                  _openBluetoothSettings,
                ),
              ],
            ),
            _buildCard(
              title: 'Clear Data',
              children: [
                _buildActionButton('Clear Saved Devices', _clearDevices),
                const SizedBox(height: 8),
                _buildActionButton('Clear Contact Bindings', _clearBindings),
              ],
            ),
            _buildCard(
              title: 'App Information',
              children: [_buildStatusRow('App Version:', appVersion)],
            ),
          ],
        ),
      ),
    );
  }
}
