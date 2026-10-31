import '../../../core/utils/dates.dart';

enum NoteStatus {
  draft,
  published;

  static NoteStatus parse(String value) => value == 'published' ? NoteStatus.published : NoteStatus.draft;
}

/// A diary entry written by one of the two participants.
class Note {
  const Note({
    required this.id,
    required this.authorId,
    required this.title,
    required this.body,
    required this.status,
    required this.entryDate,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.lastActivityAt,
    this.publishedAt,
    this.replyCount = 0,
    this.likedBy = const [],
  });

  final String id;
  final String authorId;
  final String title;
  final String body;
  final NoteStatus status;

  /// The day this entry is about (a calendar day, no time of day).
  final DateTime entryDate;

  /// Server-side version, used to detect edits from another device.
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastActivityAt;
  final DateTime? publishedAt;

  /// Replies the signed-in person can see (from the `replies(count)` embed).
  final int replyCount;

  /// Who liked it (at most the two of you), from the `note_likes` embed.
  final List<String> likedBy;

  int get likeCount => likedBy.length;
  bool isLikedBy(String? userId) => userId != null && likedBy.contains(userId);

  static const columns =
      'id, author_id, title, body, status, entry_date, version, created_at, updated_at, published_at, last_activity_at, replies(count), note_likes(user_id)';

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String,
    authorId: json['author_id'] as String,
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    status: NoteStatus.parse(json['status'] as String? ?? 'draft'),
    entryDate:
        Dates.parseIso(json['entry_date'] as String?) ??
        Dates.dateOnly(DateTime.parse(json['created_at'] as String).toLocal()),
    version: (json['version'] as num).toInt(),
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    lastActivityAt: DateTime.parse(json['last_activity_at'] as String),
    publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
    replyCount: _count(json['replies']),
    likedBy: [
      for (final like in json['note_likes'] as List? ?? const [])
        if (like is Map && like['user_id'] is String) like['user_id'] as String,
    ],
  );

  /// The same shape [Note.fromJson] reads; used for the offline copy.
  Map<String, dynamic> toJson() => {
    'id': id,
    'author_id': authorId,
    'title': title,
    'body': body,
    'status': status.name,
    'entry_date': Dates.iso(entryDate),
    'version': version,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'last_activity_at': lastActivityAt.toIso8601String(),
    'published_at': publishedAt?.toIso8601String(),
    'replies': [
      {'count': replyCount},
    ],
    'note_likes': [
      for (final id in likedBy) {'user_id': id},
    ],
  };

  static int _count(Object? embed) {
    if (embed is List && embed.isNotEmpty && embed.first is Map) {
      return ((embed.first as Map)['count'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  /// When it appeared in the feed (drafts: when they were started).
  DateTime get postedAt => publishedAt ?? createdAt;

  bool get isDraft => status == NoteStatus.draft;

  bool get hasTitle => title.trim().isNotEmpty;

  /// The title, or the entry's date when it has none.
  String get displayTitle => hasTitle ? title.trim() : Dates.longDay(entryDate);

  /// Shown in Recents: the first non-empty line, shortened.
  String get preview {
    final line = body.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.length > 120 ? '${line.substring(0, 120)}…' : line;
  }

  /// True when edited meaningfully after it was first written.
  bool get wasEdited => updatedAt.difference(publishedAt ?? createdAt).inMinutes >= 1;

  /// Paragraphs are separated by one or more blank lines. Single line breaks
  /// inside a paragraph are kept as-is.
  List<String> get paragraphs => body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split(RegExp(r'\n[ \t]*\n\s*'))
      .map((p) => p.trimRight().replaceFirst(RegExp(r'^\n+'), ''))
      .where((p) => p.trim().isNotEmpty)
      .toList(growable: false);

  Note copyWith({DateTime? lastActivityAt, int? replyCount, List<String>? likedBy}) => Note(
    id: id,
    authorId: authorId,
    title: title,
    body: body,
    status: status,
    entryDate: entryDate,
    version: version,
    createdAt: createdAt,
    updatedAt: updatedAt,
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    publishedAt: publishedAt,
    replyCount: replyCount ?? this.replyCount,
    likedBy: likedBy ?? this.likedBy,
  );
}
