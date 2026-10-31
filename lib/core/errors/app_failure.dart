/// Every failure the user can see, each with a gentle, non-technical message.
///
/// Messages never include server details, status codes or stack traces.
sealed class AppFailure implements Exception {
  const AppFailure();

  String get message;
}

class IncorrectPasscode extends AppFailure {
  const IncorrectPasscode({this.attemptsRemaining});

  final int? attemptsRemaining;

  @override
  String get message {
    final remaining = attemptsRemaining;
    if (remaining != null && remaining > 0 && remaining <= 2) {
      return "That's not quite it. "
          '$remaining ${remaining == 1 ? 'try' : 'tries'} left before a short pause.';
    }
    return "That's not quite it. Take your time and try again.";
  }
}

class TooManyAttempts extends AppFailure {
  const TooManyAttempts(this.retryAfter);

  final Duration retryAfter;

  @override
  String get message =>
      "Let's take a little break. You can try again in ${_humanize(retryAfter)}.";

  static String _humanize(Duration d) {
    if (d.inMinutes < 1) return 'a moment';
    if (d.inMinutes == 1) return 'about a minute';
    if (d.inMinutes < 60) return 'about ${d.inMinutes} minutes';
    final hours = (d.inMinutes / 60).ceil();
    return hours == 1 ? 'about an hour' : 'about $hours hours';
  }
}

class NoConnection extends AppFailure {
  const NoConnection();

  @override
  String get message =>
      "I couldn't reach the internet. Please check your connection and try again.";
}

class ServiceUnavailable extends AppFailure {
  const ServiceUnavailable();

  @override
  String get message =>
      'Something went wrong on my side. Please try again in a little while.';
}

/// No passcodes have been configured on the server yet.
class NotReady extends AppFailure {
  const NotReady();

  @override
  String get message => "This space isn't quite ready yet. Please check back soon.";
}

class SessionExpired extends AppFailure {
  const SessionExpired();

  @override
  String get message => 'For your privacy, you have been signed out. '
      'Please enter your passcode again.';
}

/// The server refused the action (RLS), e.g. editing someone else's note.
class NotAllowed extends AppFailure {
  const NotAllowed();

  @override
  String get message => "That isn't something you can change.";
}

/// The note was removed or is no longer visible (e.g. moved back to drafts).
class NoteNotFound extends AppFailure {
  const NoteNotFound();

  @override
  String get message => "This note isn't available anymore.";
}

/// The content was rejected, e.g. publishing an empty note.
class InvalidContent extends AppFailure {
  const InvalidContent([this.reason = 'Please write something first.']);

  final String reason;

  @override
  String get message => reason;
}

/// Someone saved a newer version of this note from another device.
class EditConflict extends AppFailure {
  const EditConflict(this.latest);

  /// The newer version currently on the server.
  final Object latest;

  @override
  String get message => 'This note was changed on another device since you opened it.';
}

/// The entry was saved but at least one photo change wasn't. The photos that
/// didn't make it are still in the editor, so saving again retries them.
class PhotosNotSaved extends AppFailure {
  const PhotosNotSaved(this.cause);

  final AppFailure cause;

  @override
  String get message => cause is InvalidContent
      ? 'Your entry was saved, but a photo was not. ${cause.message}'
      : "Your entry was saved, but a photo didn't upload. "
          'Check your connection and save again to retry.';
}

class ConfigurationMissing extends AppFailure {
  const ConfigurationMissing();

  @override
  String get message => "This app hasn't been set up completely yet.";
}

class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure();

  @override
  String get message => 'Something unexpected happened. Please try again.';
}
