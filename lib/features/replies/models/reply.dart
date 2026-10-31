/// A reply in the conversation under a note.
class Reply {
  const Reply({
    required this.id,
    required this.noteId,
    required this.authorId,
    required this.body,
    required this.createdAt,
    this.editedAt,
  });

  final String id;
  final String noteId;
  final String authorId;
  final String body;
  final DateTime createdAt;

  /// Set once the author has changed the text.
  final DateTime? editedAt;

  static const columns = 'id, note_id, author_id, body, created_at, edited_at';

  factory Reply.fromJson(Map<String, dynamic> json) => Reply(
    id: json['id'] as String,
    noteId: json['note_id'] as String,
    authorId: json['author_id'] as String,
    body: json['body'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    editedAt: DateTime.tryParse(json['edited_at'] as String? ?? ''),
  );

  Reply copyWith({String? body, DateTime? editedAt}) => Reply(
    id: id,
    noteId: noteId,
    authorId: authorId,
    body: body ?? this.body,
    createdAt: createdAt,
    editedAt: editedAt ?? this.editedAt,
  );
}
