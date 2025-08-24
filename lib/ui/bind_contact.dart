import 'package:flutter/material.dart';
import 'package:orbits_new/database/dao/binding_dao.dart';
import 'package:orbits_new/database/models/contact_binding.dart';
import 'package:orbits_new/theme/app_theme.dart';

class ContactBindPage extends StatefulWidget {
  final String uuid;
  final ContactBinding? initialBinding;

  const ContactBindPage({super.key, required this.uuid, this.initialBinding});

  @override
  State<ContactBindPage> createState() => _ContactBindPageState();
}

class _ContactBindPageState extends State<ContactBindPage> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController relationController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final BindingDao bindingDao = BindingDao();

  @override
  void initState() {
    super.initState();
    // 如果传入了初始绑定信息，则预填充文本框
    if (widget.initialBinding != null) {
      nameController.text = widget.initialBinding!.name;
      relationController.text = widget.initialBinding!.relationship;
      phoneController.text = widget.initialBinding!.phoneNumber;
    }
  }

  void _submit() async {
    final name = nameController.text.trim();
    final relation = relationController.text.trim();
    final phone = phoneController.text.trim();

    // 检查输入是否为空
    if (name.isEmpty || relation.isEmpty || phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.')),
      );
      return;
    }

    final binding = ContactBinding(
      uuid: widget.uuid,
      name: name,
      relationship: relation,
      phoneNumber: phone,
    );

    // 检查是否存在初始绑定信息来决定是更新还是插入
    if (widget.initialBinding != null) {
      // 如果有初始绑定，说明是编辑模式，执行更新操作
      await bindingDao.updateBinding(binding);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact binding updated successfully!')),
      );
    } else {
      // 否则，说明是新增绑定，执行插入操作
      await bindingDao.insertBinding(binding);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact bound successfully!')),
      );
    }

    // 操作完成后，返回到上一个页面，并传递一个表示成功的布尔值。
    // 这比返回UUID更通用，因为ContactListPage的刷新逻辑通常不区分是新增还是修改。
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    // 根据是否有初始绑定信息来设置 AppBar 标题和按钮文本
    final isEditing = widget.initialBinding != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? "Edit Contact" : "Bind Contact"),
        centerTitle: false,
        backgroundColor: AppTheme.primaryColor.withOpacity(0.9),
        foregroundColor: Colors.white,
      ),

      body: Column(
        children: [
          const Spacer(flex: 1),
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Card(
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "UUID:",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.black.withOpacity(0.6),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.uuid,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: nameController,
                      decoration: InputDecoration(
                        labelText: 'Contact Name',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: relationController,
                      decoration: InputDecoration(
                        labelText: 'Relationship',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: phoneController,
                      decoration: InputDecoration(
                        labelText: 'Phone Number',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 30),
                    Center(
                      child: FilledButton.icon(
                        onPressed: _submit,
                        icon: Icon(isEditing ? Icons.save : Icons.check),
                        label: Text(
                          isEditing ? "Save Changes" : "Confirm Binding",
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(flex: 4),
        ],
      ),
    );
  }
}
