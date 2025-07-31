class ContactSummary {
  final String name;
  final String relationship;
  final String uuid;
  final int rssi;
  final int durationMinutes;
  final String phoneNumber; //new field

  ContactSummary({
    required this.name,
    required this.relationship,
    required this.uuid,
    required this.rssi,
    required this.durationMinutes,
    required this.phoneNumber, //new field
  });
}
