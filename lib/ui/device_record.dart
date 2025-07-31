import 'package:flutter/material.dart';
import 'package:orbits_new/database/models/contact_device.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/ui/bind_contact.dart';
import 'package:orbits_new/theme/app_theme.dart';
import 'package:uuid/uuid.dart'; //测试完删除

class DeviceRecord extends StatefulWidget {
  const DeviceRecord({super.key});

  @override
  State<DeviceRecord> createState() => _DeviceRecordState();
}

class _DeviceRecordState extends State<DeviceRecord> {
  final DeviceDao deviceDao = DeviceDao();
  List<ContactDevice> devices = [];
  // 将时间转换成分钟--the method does not seem to be used
  String formatDuration(Duration duration) {
    return '${duration.inMinutes} min';
  }

  @override
  void initState() {
    super.initState();
    loadDevices();
  }

  Future<void> loadDevices() async {
    final list = await deviceDao.getAllDevices();
    setState(() {
      devices = list;
    });
  }

  // ======================================================================================================
  /// 添加一个用于生成和插入测试设备的方法 add a method to generate test devices
  Future<void> _addTestDevice() async {
    // 导入 uuid 库以生成唯一的设备ID
    final uuid = const Uuid().v4();
    final now = DateTime.now();
    final firstSeenTime = now.subtract(
      const Duration(minutes: 1),
    ); // firstSeen 设置为1分钟前

    // 创建一个 ContactDevice 实例
    final testDevice = ContactDevice(
      uuid: uuid,
      rssi: -50, // 示例RSSI值
      firstSeen: firstSeenTime.toIso8601String(),
      lastSeen: now.toIso8601String(),
    );

    // 将测试设备插入到数据库
    await deviceDao.insertDevice(testDevice);

    // 重新加载设备列表以更新UI
    await loadDevices();

    // 提示用户添加成功
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Test device with UUID $uuid added.')),
      );
    }
  }
  // ======================================================================================================

  // 应该获取真实的手机绑定？？？No devices found是有效的
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detected Devices'),
        centerTitle: true,
        backgroundColor: AppTheme.primaryColor.withOpacity(0.9),
        foregroundColor: Colors.white,
      ),

      body: devices.isEmpty
          ? Center(
              child: Text(
                'No nearby devices detected',
                style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
              ),
            )
          : ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                // d is as one device
                final d = devices[index];
                final first = DateTime.tryParse(d.firstSeen);
                final last = DateTime.tryParse(d.lastSeen);
                final duration = (first != null && last != null)
                    ? last.difference(first).inMinutes
                    : 0;

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
                          Text('Duration: $duration'),
                          Text('RSSI: ${d.rssi} dBm'),
                        ],
                      ),
                    ),
                    trailing: ElevatedButton(
                      // onPressed: () {
                      //   // Navigate to contact binding screen or handle action
                      //   ScaffoldMessenger.of(context).showSnackBar(
                      //     SnackBar(content: Text('Bind contact for ${d.uuid}')),
                      //   );
                      // },
                      onPressed: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ContactBindPage(uuid: d.uuid),
                          ),
                        );

                        // 如果绑定成功，刷新页面
                        if (result == true) {
                          await loadDevices();
                        }
                      },

                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: const Text('Bind Contact'),
                    ),
                  ),
                );
              },
            ),

      // ===============================================
      // add test device to show the list
      floatingActionButton: FloatingActionButton(
        onPressed: _addTestDevice,
        backgroundColor: AppTheme.primaryColor,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      // ===============================================
    );
  }
}
