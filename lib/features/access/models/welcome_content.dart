/// Text shown on the passcode screen, editable in Supabase.
class WelcomeContent {
  const WelcomeContent({
    required this.recipientName,
    required this.title,
    required this.message,
  });

  final String recipientName;
  final String title;
  final String message;

  /// Shown only if the welcome text cannot be loaded (e.g. offline). Generic on
  /// purpose so nothing personal is bundled in the app.
  static const fallback = WelcomeContent(
    recipientName: '',
    title: 'Hello.',
    message: "There's something I'd like you to read.",
  );

  factory WelcomeContent.fromJson(Map<String, dynamic> json) {
    String text(String key) => (json[key] as String? ?? '').trim();
    final name = text('recipient_name');
    final title = text('welcome_title');
    final message = text('welcome_message');
    return WelcomeContent(
      recipientName: name,
      title: title.isNotEmpty
          ? title
          : (name.isNotEmpty ? 'Hi, $name.' : fallback.title),
      message: message.isNotEmpty ? message : fallback.message,
    );
  }
}
