class ContactBinding {
  final int? id;
  final String uuid;
  final String name;
  final String relationship;
  final String phoneNumber;

  ContactBinding({
    this.id,
    required this.uuid,
    required this.name,
    required this.relationship,
    required this.phoneNumber,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'uuid': uuid,
      'name': name,
      'relationship': relationship,
      'phoneNumber': phoneNumber,
    };
  }

  // **新增**：专门用于更新的 map，不包含 id 和 uuid
  Map<String, dynamic> toUpdateMap() {
    return {
      'name': name,
      'relationship': relationship,
      'phoneNumber': phoneNumber,
    };
  }

  // 工厂构造函数创建Binding对象
  factory ContactBinding.fromMap(Map<String, dynamic> map) {
    return ContactBinding(
      id: map['id'],
      uuid: map['uuid'],
      name: map['name'],
      relationship: map['relationship'],
      phoneNumber: map['phoneNumber'],
    );
  }
/*
  * 该类是否需要添加手机联系人字段
  * Whether the mobile phone contact field needs to be added to this class
  * */
}
