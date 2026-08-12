class QuickDevice {
  const QuickDevice({
    required this.id,
    required this.name,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final DateTime updatedAt;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static QuickDevice fromJson(Map<String, dynamic> json) => QuickDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    updatedAt: DateTime.parse(json['updatedAt'] as String).toLocal(),
  );
}
