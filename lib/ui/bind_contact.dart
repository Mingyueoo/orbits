import 'package:flutter/material.dart';
import 'package:orbits_new/database/dao/binding_dao.dart';
import 'package:orbits_new/database/models/contact_binding.dart';
import 'package:orbits_new/theme/app_theme.dart';

class ContactBindPage extends StatefulWidget {
  final String uuid;
  const ContactBindPage({super.key, required this.uuid});

  @override
  State<ContactBindPage> createState() => _ContactBindPageState();
}

class _ContactBindPageState extends State<ContactBindPage> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController relationController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final BindingDao bindingDao = BindingDao();

  void _submit() async {
    final name = nameController.text.trim();
    final relation = relationController.text.trim();
    final phone = phoneController.text.trim();

    if (name.isEmpty || relation.isEmpty || phone.isEmpty) return;

    final binding = ContactBinding(
      uuid: widget.uuid,
      name: name,
      relationship: relation,
      phoneNumber: phone,
    );

    // await bindingDao.insertBinding(binding);
    // Navigator.pop(context, true);
    // Check if a binding already exists for this UUID
    final existingBinding = await bindingDao.getBindingByUuid(widget.uuid);
    if (existingBinding != null) {
      // If a binding exists, update it
      await bindingDao.updateBinding(binding);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact binding updated successfully!')),
      );
    } else {
      // Otherwise, insert a new binding
      await bindingDao.insertBinding(binding);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact bound successfully!')),
      );
    }
    Navigator.pop(context, widget.uuid); // Crucial: pop with the UUID
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Bind Contact"),
        centerTitle: false,
        backgroundColor: AppTheme.primaryColor.withOpacity(0.9),
        foregroundColor: Colors.white,
      ),

      body: Column(
        children: [
          const Spacer(flex: 1), // 顶部留白，flex值越大，留白越多，Card越靠下
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
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accentColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _submit,
                        icon: const Icon(Icons.check),
                        label: const Text("Confirm Binding"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(flex: 4), // 底部留白，flex值越大，留白越多，Card越靠上
        ],
      ),
    );
  }
}
