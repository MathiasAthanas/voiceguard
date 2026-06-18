class ContactModel {
  final String id;
  final String name;
  final String phoneNumber;
  final String? alternatePhoneNumber;
  final String? email;
  final String? notes;
  final String phoneLabel;
  final bool isFavorite;
  final bool isEnrolled;
  final DateTime? enrolledAt;
  final String? avatarUrl;

  ContactModel({
    required this.id,
    required this.name,
    required this.phoneNumber,
    this.alternatePhoneNumber,
    this.email,
    this.notes,
    this.phoneLabel = 'Mobile',
    this.isFavorite = false,
    this.isEnrolled = false,
    this.enrolledAt,
    this.avatarUrl,
  });

  ContactModel copyWith({
    String? id,
    String? name,
    String? phoneNumber,
    String? alternatePhoneNumber,
    String? email,
    String? notes,
    String? phoneLabel,
    bool? isFavorite,
    bool? isEnrolled,
    DateTime? enrolledAt,
    String? avatarUrl,
  }) {
    return ContactModel(
      id: id ?? this.id,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      alternatePhoneNumber: alternatePhoneNumber ?? this.alternatePhoneNumber,
      email: email ?? this.email,
      notes: notes ?? this.notes,
      phoneLabel: phoneLabel ?? this.phoneLabel,
      isFavorite: isFavorite ?? this.isFavorite,
      isEnrolled: isEnrolled ?? this.isEnrolled,
      enrolledAt: enrolledAt ?? this.enrolledAt,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'phoneNumber': phoneNumber,
      'alternatePhoneNumber': alternatePhoneNumber,
      'email': email,
      'notes': notes,
      'phoneLabel': phoneLabel,
      'isFavorite': isFavorite,
      'isEnrolled': isEnrolled,
      'enrolledAt': enrolledAt?.toIso8601String(),
      'avatarUrl': avatarUrl,
    };
  }

  factory ContactModel.fromMap(Map<String, dynamic> map) {
    return ContactModel(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      phoneNumber: map['phoneNumber'] ?? '',
      alternatePhoneNumber: map['alternatePhoneNumber'],
      email: map['email'],
      notes: map['notes'],
      phoneLabel: map['phoneLabel'] ?? 'Mobile',
      isFavorite: map['isFavorite'] ?? false,
      isEnrolled: map['isEnrolled'] ?? false,
      enrolledAt:
          map['enrolledAt'] != null ? DateTime.parse(map['enrolledAt']) : null,
      avatarUrl: map['avatarUrl'],
    );
  }

  String get initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}
