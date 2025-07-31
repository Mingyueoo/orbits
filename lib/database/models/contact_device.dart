class ContactDevice {
  final int? id;
  final String uuid;
  final String firstSeen;
  final String lastSeen;
  final int rssi;

  ContactDevice({
    this.id,
    required this.uuid,
    required this.firstSeen,
    required this.lastSeen,
    required this.rssi,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'uuid': uuid,
      'first_seen': firstSeen,
      'last_seen': lastSeen,
      'rssi': rssi,
    };
  }

  factory ContactDevice.fromMap(Map<String, dynamic> map) {
    return ContactDevice(
      id: map['id'],
      uuid: map['uuid'],
      firstSeen: map['first_seen'],
      lastSeen: map['last_seen'],
      rssi: map['rssi'],
    );
  }

  /// 可选：计算累计接触时长（分钟）
  int get contactDurationMinutes {
    final first = DateTime.tryParse(firstSeen);
    final last = DateTime.tryParse(lastSeen);
    if (first != null && last != null) {
      return last.difference(first).inMinutes;
    }
    return 0;
  }
}
