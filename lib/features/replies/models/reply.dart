/// A reply in the conversation under a note.
class Reply {
  const Reply({
    required this.id,
    required this.noteId,
    required this.authorId,
    required this.body,
    required this.createdAt,
    this.editedAt,
    this.parentId,
    this.imagePath,
    this.likedBy = const [],
  });

  final String id;
  final String noteId;
  final String authorId;

  /// May be empty when the reply has a photo.
  final String body;
  final DateTime createdAt;

  /// Set once the author has changed the text.
  final DateTime? editedAt;

  /// The top-level reply this one answers; null for a top-level reply.
  final String? parentId;

  /// `<reply id>.jpg` in the private `reply-images` bucket, if it has a photo.
  final String? imagePath;

  /// Who liked it, from the `reply_likes` embed.
  final List<String> likedBy;

  bool isLikedBy(String? userId) => userId != null && likedBy.contains(userId);

  static const columns =
      'id, note_id, author_id, body, created_at, edited_at, parent_id, image_path, reply_likes(user_id)';

  factory Reply.fromJson(Map<String, dynamic> json) => Reply(
    id: json['id'] as String,
    noteId: json['note_id'] as String,
    authorId: json['author_id'] as String,
    body: json['body'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    editedAt: DateTime.tryParse(json['edited_at'] as String? ?? ''),
    parentId: json['parent_id'] as String?,
    imagePath: json['image_path'] as String?,
    likedBy: [
      for (final like in json['reply_likes'] as List? ?? const [])
        if (like is Map && like['user_id'] is String) like['user_id'] as String,
    ],
  );

  Reply copyWith({String? body, DateTime? editedAt, List<String>? likedBy}) => Reply(
    id: id,
    noteId: noteId,
    authorId: authorId,
    body: body ?? this.body,
    createdAt: createdAt,
    editedAt: editedAt ?? this.editedAt,
    parentId: parentId,
    imagePath: imagePath,
    likedBy: likedBy ?? this.likedBy,
  );
}
