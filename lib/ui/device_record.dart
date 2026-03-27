import 'package:flutter/material.dart';
import 'package:orbits_new/database/models/contact_device.dart';
import 'package:orbits_new/database/models/contact_binding.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/database/dao/binding_dao.dart';
import 'package:orbits_new/ui/bind_contact.dart';
import 'package:orbits_new/theme/app_theme.dart';

class DeviceRecordPage extends StatefulWidget {
  const DeviceRecordPage({super.key});

  @override
  State<DeviceRecordPage> createState() => _DeviceRecordPageState();
}

class _DeviceRecordPageState extends State<DeviceRecordPage> {
  final DeviceDao deviceDao = DeviceDao();
  final BindingDao bindingDao = BindingDao();

  // 记录展开状态的Map
  final Map<String, bool> _expandedUuids = {};

  /// 格式化UUID显示
  String _formatUuid(String uuid) {
    if (_expandedUuids[uuid] == true) {
      return uuid; // 显示完整UUID
    } else {
      // 显示前8位...后4位
      if (uuid.length > 12) {
        return '${uuid.substring(0, 8)}...${uuid.substring(uuid.length - 4)}';
      }
      return uuid;
    }
  }

  /// 切换UUID展开状态
  void _toggleUuidExpansion(String uuid) {
    setState(() {
      _expandedUuids[uuid] = !(_expandedUuids[uuid] ?? false);
    });
  }

  /// 显示删除确认对话框
  Future<bool> _showDeleteConfirmation(
    BuildContext context,
    String deviceUuid,
  ) async {
    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Delete Device'),
              content: Text(
                'Are you sure you want to delete the device "$deviceUuid" ?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Confirm'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  /// 删除设备
  Future<void> _deleteDevice(String deviceUuid) async {
    try {
      // 先删除绑定关系（如果存在）
      await bindingDao.deleteBinding(deviceUuid);

      // 删除设备
      await deviceDao.deleteDevice(deviceUuid);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Device "$deviceUuid" deleted'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deletion failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detected Devices'),
        centerTitle: true,
        backgroundColor: AppTheme.primaryColor.withAlpha((255 * 0.9).round()),
        foregroundColor: Colors.white,
      ),

      // StreamBuilder 监听 deviceUpdates 流。
      body: StreamBuilder(
        // stream: deviceDao.deviceUpdates,
        stream: deviceDao.getDeviceCountStream(),
        builder: (context, snapshot) {
          // 将 FutureBuilder 嵌套在 StreamBuilder 的 builder 中。
          // 这样，每次 Stream 收到通知时，整个 FutureBuilder 都会重建，并重新调用 Future。
          return FutureBuilder<List<ContactDevice>>(
            future: deviceDao.getAllDevices(),
            builder: (context, deviceSnapshot) {
              if (deviceSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              } else if (deviceSnapshot.hasError) {
                return Center(child: Text('Error: ${deviceSnapshot.error}'));
              } else if (!deviceSnapshot.hasData ||
                  deviceSnapshot.data!.isEmpty) {
                return Center(
                  child: Text(
                    'No nearby devices detected',
                    style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
                  ),
                );
              }

              final devices = deviceSnapshot.data!;

              return ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, index) {
                  final d = devices[index];
                  final isBoundFuture = bindingDao.getBindingByUuid(d.uuid);

                  return FutureBuilder<ContactBinding?>(
                    future: isBoundFuture,
                    builder: (context, bindingSnapshot) {
                      final isBound = bindingSnapshot.data != null;
                      final first = DateTime.tryParse(d.firstSeen);
                      final last = DateTime.tryParse(d.lastSeen);
                      final duration = d.contactDuration;

                      return Dismissible(
                        key: Key(d.uuid),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20.0),
                          color: Colors.red,
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        confirmDismiss: (direction) async {
                          return await _showDeleteConfirmation(context, d.uuid);
                        },
                        onDismissed: (direction) {
                          _deleteDevice(d.uuid);
                        },
                        child: Card(
                          elevation: 1,
                          margin: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            title: GestureDetector(
                              onTap: () => _toggleUuidExpansion(d.uuid),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _formatUuid(d.uuid),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    _expandedUuids[d.uuid] == true
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    size: 16,
                                    color: Colors.grey,
                                  ),
                                ],
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('First Seen: ${first?.toLocal()}'),
                                  Text('Last Seen: ${last?.toLocal()}'),
                                  Text('Duration: $duration min'),
                                  Text('RSSI: ${d.rssi} dBm'),
                                ],
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 删除按钮
                                IconButton(
                                  onPressed: () async {
                                    final shouldDelete =
                                        await _showDeleteConfirmation(
                                          context,
                                          d.uuid,
                                        );
                                    if (shouldDelete) {
                                      await _deleteDevice(d.uuid);
                                    }
                                  },
                                  icon: const Icon(Icons.delete_outline),
                                  color: Colors.red,
                                  tooltip: 'delete devices',
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  onPressed: isBound
                                      ? null
                                      : () async {
                                          final result = await Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  ContactBindPage(uuid: d.uuid),
                                            ),
                                          );
                                          if (result != null) {
                                            // 绑定成功后，通过 insertDevice 触发一次 Stream 更新。
                                            // 这里的 d 是旧的 ContactDevice 对象，但由于 insertDevice 会检查 uuid，
                                            // 只是为了触发更新，并不会真的插入一个新设备。
                                            deviceDao.insertDevice(d);
                                          }
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isBound
                                        ? AppTheme.primaryColor
                                        : AppTheme.accentColor,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                  ),
                                  child: Text(
                                    isBound ? 'Bound' : 'Bind Contact',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
