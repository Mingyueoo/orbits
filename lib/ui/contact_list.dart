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
  // We will now display ContactSummary objects instead of raw devices
  List<ContactSummary> contactSummaries = [];
  // The bindingMap and devices list are still useful internally for processing
  // But the UI will directly use contactSummaries
  List<ContactDevice> devices =
      []; // Still needed for _loadDevices and internal processing
  Map<String, ContactBinding?> bindingMap =
      {}; // Still needed for _loadDevices and internal processing

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
      // 旧的代码我需要理解一下
      // If a binding exists, use its details; otherwise, use default/placeholder values
      // result.add(
      //   ContactSummary(
      //     name: binding?.name ?? "Unknown Contact", // Default name if not bound
      //     relationship: binding?.relationship ?? "N/A", // Default relationship
      //     uuid: device.uuid,
      //     rssi: device.rssi,
      //     durationMinutes: device.contactDurationMinutes,
      //     phoneNumber: binding?.phoneNumber ?? "N/A", // Default phone number
      //   ),
      // );
      // *** THIS IS THE KEY CHANGE: Only add to result if a binding exists ***
      if (binding != null) {
        result.add(
          ContactSummary(
            name: binding.name,
            relationship: binding.relationship,
            uuid: device.uuid,
            rssi: device.rssi,
            durationMinutes: device.contactDurationMinutes,
            phoneNumber: binding.phoneNumber,
          ),
        );
      }
    }

    // Sort by contact duration in descending order
    result.sort((a, b) => b.durationMinutes.compareTo(a.durationMinutes));
    return result;
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

  // The original getSortedContacts logic is now part of _createContactSummaries,
  // but if you specifically need a method that only returns sorted bound contacts,
  // you might keep a modified version of this. For displaying all devices (bound or not),
  // _createContactSummaries is more appropriate.
  // The previous implementation was only showing 'bound' contacts.
  // The current display logic in ListView.builder iterates through 'devices'
  // and then checks 'bindingMap'. So the `_createContactSummaries` is more aligned.
  // If the intent was *only* to show bound contacts, then `getSortedContacts` would be used directly.
  // For the purpose of this correction, I'll integrate the logic into _createContactSummaries
  // to ensure all devices are shown, with binding info where available.

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
                // We no longer need to look up in bindingMap here, as summary already contains bound info
                // final boundText = summary.name == "Unknown Contact"
                //     ? "👤 Not bound"
                //     : "👤 ${summary.name} (${summary.relationship})";

                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  color: Colors.white.withOpacity(0.9),
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
                    trailing: IconButton(
                      icon: const Icon(Icons.call, color: AppTheme.accentColor),
                      onPressed: () {
                        debugPrint('Dialing ${summary.phoneNumber}');
                        // 真机调试可用：
                        _makePhoneCall(summary.phoneNumber); // 调用新的私有方法
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}
