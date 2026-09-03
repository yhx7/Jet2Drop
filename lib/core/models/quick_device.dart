class QuickDevice {
  const QuickDevice({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.photoEndpoint,
    this.photoToken,
  });

  final String id;
  final String name;
  final DateTime updatedAt;
  final String? photoEndpoint;
  final String? photoToken;

  bool get supportsPhotoTransfer =>
      photoEndpoint != null &&
      photoEndpoint!.isNotEmpty &&
      photoToken != null &&
      photoToken!.isNotEmpty;

  Map<String, Object> toJson() {
    final result = <String, Object>{
      'id': id,
      'name': name,
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
    if (photoEndpoint != null) result['photoEndpoint'] = photoEndpoint!;
    if (photoToken != null) result['photoToken'] = photoToken!;
    return result;
  }

  static QuickDevice fromJson(Map<String, dynamic> json) => QuickDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    updatedAt: DateTime.parse(json['updatedAt'] as String).toLocal(),
    photoEndpoint: json['photoEndpoint'] as String?,
    photoToken: json['photoToken'] as String?,
  );
}
