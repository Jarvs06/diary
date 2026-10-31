/// One of the two people using the app.
class Participant {
  const Participant({required this.id, required this.key, required this.displayName});

  final String id;

  /// 'author' or 'janina'.
  final String key;
  final String displayName;

  String get initial =>
      displayName.isEmpty ? '?' : String.fromCharCode(displayName.runes.first).toUpperCase();

  Map<String, dynamic> toJson() => {'id': id, 'participant_key': key, 'display_name': displayName};

  factory Participant.fromJson(Map<String, dynamic> json) => Participant(
        id: json['id'] as String,
        key: json['participant_key'] as String,
        displayName: (json['display_name'] as String).trim(),
      );
}

