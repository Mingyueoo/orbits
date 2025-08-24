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

  String formatDuration(Duration duration) {
    return '${duration.inMinutes} min';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detected Devices'),
        centerTitle: true,
        backgroundColor: AppTheme.primaryColor.withOpacity(0.9),
        foregroundColor: Colors.white,
      ),

      // 【修改点 1】: StreamBuilder 监听 deviceUpdates 流。
      body: StreamBuilder(
        // stream: deviceDao.deviceUpdates,
        stream: deviceDao.getDeviceCountStream(),
        builder: (context, snapshot) {
          // 【修改点 2】: 将 FutureBuilder 嵌套在 StreamBuilder 的 builder 中。
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
                      // final duration = (first != null && last != null)
                      //     ? last.difference(first).inMinutes
                      //     : 0;
                      final duration = d.contactDuration;

                      return Card(
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
                          title: Text(
                            d.uuid,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
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
                          trailing: ElevatedButton(
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
                            child: Text(isBound ? 'Bound' : 'Bind Contact'),
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
