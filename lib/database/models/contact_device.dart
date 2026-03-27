class ContactDevice {
  final int? id;
  final String uuid;
  final String firstSeen;
  final String lastSeen;
  final int rssi;
  final String secretKey;
  final int contactDuration;

  ContactDevice({
    this.id,
    required this.uuid,
    required this.firstSeen,
    required this.lastSeen,
    required this.rssi,
    required this.secretKey,
    this.contactDuration = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'uuid': uuid,
      'first_seen': firstSeen,
      'last_seen': lastSeen,
      'rssi': rssi,
      'secret_key': secretKey,
      'contact_duration': contactDuration,
    };
  }

  /// Creates a ContactDevice instance from a Map, handling potential null values safely.
  factory ContactDevice.fromMap(Map<String, dynamic> map) {
    // We use the null-aware operator (??) to provide a safe default value
    // in case any field is null in the database.
    return ContactDevice(
      id: map['id'] as int?,
      uuid: map['uuid'] as String? ?? 'unknown_uuid',
      firstSeen:
          map['first_seen'] as String? ?? DateTime.now().toIso8601String(),
      lastSeen: map['last_seen'] as String? ?? DateTime.now().toIso8601String(),
      rssi: map['rssi'] as int? ?? -100,
      // Use a default out-of-range value
      secretKey: map['secret_key'] as String? ?? '',
      contactDuration: map['contact_duration'] ?? 0,
    );
  }

  /// 计算累计接触时长（分钟）
  int get contactDurationMinutes {
    final first = DateTime.tryParse(firstSeen);
    final last = DateTime.tryParse(lastSeen);
    if (first != null && last != null) {
      final duration = last.difference(first);
      // 如果firstSeen和lastSeen相同（通过二维码添加），返回1分钟作为基础值
      if (duration.inMinutes == 0) {
        return 1; // 至少1分钟的接触时间
      }
      return duration.inMinutes;
    }
    return 0;
  }

  /// 获取更详细的接触时间信息
  String get contactDurationText {
    final first = DateTime.tryParse(firstSeen);
    final last = DateTime.tryParse(lastSeen);
    if (first != null && last != null) {
      final duration = last.difference(first);
      if (duration.inMinutes == 0) {
        return "1分钟"; // 通过二维码添加的设备
      }
      return "${duration.inMinutes}分钟";
    }
    return "0分钟";
  }
}
