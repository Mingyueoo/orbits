import 'package:flutter/material.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/database/dao/binding_dao.dart';
import 'package:orbits_new/database/models/contact_device.dart';
import 'package:orbits_new/database/models/contact_binding.dart';
import 'package:orbits_new/database/models/contact_summary.dart';
import 'package:orbits_new/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:orbits_new/ui/bind_contact.dart';

class ContactListPage extends StatefulWidget {
  const ContactListPage({super.key});

  @override
  State<ContactListPage> createState() => _ContactListPageState();
}

class _ContactListPageState extends State<ContactListPage> {
  final DeviceDao deviceDao = DeviceDao();
  final BindingDao bindingDao = BindingDao();
  List<ContactSummary> contactSummaries = [];
  List<ContactDevice> devices = [];
  Map<String, ContactBinding?> bindingMap = {};

  @override
  void initState() {
    super.initState();
    _loadAllContactData(); // Call a new method to load both devices and summaries
  }

  // Refactored to load all necessary data and prepare summaries
  // 数据加载逻辑 _loadAllContactData() 中会重新获取设备和绑定信息
  Future<void> _loadAllContactData() async {
    try {
      final list = await deviceDao.getAllDevices();
      final bindings = await bindingDao.getAllBindings();

      setState(() {
        devices = list;
        bindingMap = {for (var b in bindings) b.uuid: b};
        // Update contactSummaries after loading devices and bindings
        contactSummaries = _createContactSummaries(devices, bindingMap);
      });
    } catch (e) {
      // Handle database loading errors, e.g., show a SnackBar or a dialog
      print("Error loading contact data: $e");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load contacts: $e')));
    }
  }

  // Helper method to create ContactSummary list from devices and bindingMap
  List<ContactSummary> _createContactSummaries(
    List<ContactDevice> devices,
    Map<String, ContactBinding?> bindingMap,
  ) {
    List<ContactSummary> result = [];

    // Iterate through devices and try to find a binding
    for (final device in devices) {
      final binding = bindingMap[device.uuid];
      if (binding != null) {
        result.add(
          ContactSummary(
            name: binding.name,
            relationship: binding.relationship,
            uuid: device.uuid,
            rssi: device.rssi,
            durationMinutes: device.contactDuration,
            phoneNumber: binding.phoneNumber,
          ),
        );
      }
    }

    // Sort by contact duration in descending order
    result.sort((a, b) => b.durationMinutes.compareTo(a.durationMinutes));
    return result;
  }

  // 删除绑定联系人
  Future<void> _deleteBinding(String uuid) async {
    // 弹出确认对话框
    final bool? confirm = await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Delete Contact"),
          content: const Text("Are you sure you want to delete this contact?"),
          actions: <Widget>[
            TextButton(
              child: const Text("Cancel"),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text("Delete"),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      // 从数据库中删除绑定
      await bindingDao.deleteBinding(uuid);
      // 重新加载所有数据以更新UI
      await _loadAllContactData();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact deleted successfully!')),
      );
    }
  }

  // 新增：编辑绑定联系人
  void _editBinding(ContactBinding binding) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ContactBindPage(
          uuid: binding.uuid,
          initialBinding: binding, // 传入当前的绑定信息
        ),
      ),
    );

    if (result == true) {
      await _loadAllContactData(); // 编辑成功后刷新列表
    }
  }

  // 在 _ContactListPageState 类中添加此方法
  Future<void> _makePhoneCall(String phoneNumber) async {
    debugPrint('Attempting to call number: $phoneNumber'); // 增加这一行
    if (phoneNumber == "N/A" || phoneNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Phone number not available.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);
    debugPrint('Launch URI is: $launchUri'); // 增加这一行

    try {
      if (await canLaunchUrl(launchUri)) {
        debugPrint('canLaunchUrl returned true, launching URL...'); // 增加这一行
        await launchUrl(launchUri);
      } else {
        debugPrint('canLaunchUrl returned false!'); // 增加这一行
        throw 'Could not launch $launchUri';
      }
    } catch (e) {
      print('Error launching phone call: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to make call: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _navigateToBind(String uuid) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ContactBindPage(uuid: uuid)),
    );
    // 现在想只更新一个 uuid 对应的记录，目前是刷新所有！
    if (result == true) {
      _loadAllContactData(); // Refresh all data if a binding was successful

      // 增加一个SnackBar来提供即时反馈
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Contact successfully bound!'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Contact List"),
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
        elevation: 2,
        centerTitle: true,
      ),
      body: contactSummaries.isEmpty
          ? const Center(child: Text("No contact devices found."))
          : ListView.builder(
              itemCount: contactSummaries.length,
              itemBuilder: (_, i) {
                final summary = contactSummaries[i];

                // 从 bindingMap 中获取完整的绑定对象以进行编辑
                final binding = bindingMap[summary.uuid];

                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  // color: Colors.white.withOpacity(0.9),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.primaryColor,
                      child: Text(
                        summary.name[0],
                        // contact['name'][0],
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text(
                      summary.name,
                      // contact['name'],
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      // 'Contact time: ${contact['duration'].inMinutes} minutes',
                      'Contact time: ${summary.durationMinutes} minutes',
                      style: TextStyle(color: Colors.grey[700]),
                    ),

                    trailing: Row(
                      mainAxisSize: MainAxisSize.min, // 确保 Row 不会占据所有可用空间
                      children: [
                        // 1. 打电话图标按钮
                        IconButton(
                          icon: const Icon(
                            Icons.call,
                            color: AppTheme.accentColor,
                          ),
                          onPressed: () {
                            debugPrint('Dialing ${summary.phoneNumber}');
                            _makePhoneCall(summary.phoneNumber);
                          },
                        ),
                        // 2. 更多选项菜单
                        PopupMenuButton<String>(
                          onSelected: (String result) {
                            if (result == 'edit') {
                              if (binding != null) {
                                _editBinding(binding);
                              }
                            } else if (result == 'delete') {
                              _deleteBinding(summary.uuid);
                            }
                          },
                          itemBuilder: (BuildContext context) =>
                              <PopupMenuEntry<String>>[
                                const PopupMenuItem<String>(
                                  value: 'edit',
                                  child: Row(
                                    children: [
                                      Icon(Icons.edit, color: Colors.blue),
                                      SizedBox(width: 8),
                                      Text('Edit'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem<String>(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(Icons.delete, color: Colors.red),
                                      SizedBox(width: 8),
                                      Text('Delete'),
                                    ],
                                  ),
                                ),
                              ],
                          icon: const Icon(Icons.more_vert),
                        ),
                      ],
                    ),
                    onTap: () {
                      // 如果列表项本身没有其他导航功能，可以保留这个 onTap，或者移除以避免与打电话按钮冲突
                      // 例如，如果你想点击整个列表项进入联系人详情页，可以保留它
                      // 如果你希望点击列表项只做打电话一件事，那么电话图标就显得重复了，但在UI设计上，独立的图标更清晰
                    },
                  ),
                );
              },
            ),
    );
  }
}
