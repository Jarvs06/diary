import '../features/access/data/access_repository.dart';
import '../features/notes/data/notes_repository.dart';
import '../features/participants/data/participants_repository.dart';
import '../features/photos/data/photos_repository.dart';
import '../features/photos/services/photo_picker.dart';
import '../features/photos/services/photo_saver.dart';
import '../features/replies/data/replies_repository.dart';
import '../features/export/diary_export.dart';
import 'auth/auth_session.dart';
import 'device/device_services.dart';
import 'notifications/activity_check.dart';
import 'notifications/post_notifications.dart';
import 'storage/local_store.dart';
import 'updates/releases.dart';
import 'sync/sync_service.dart';

/// The collaborators the screens need. Built once in main.dart; tests pass
/// fakes instead.
class AppDependencies {
  const AppDependencies({
    required this.accessRepository,
    required this.authSession,
    required this.participantsRepository,
    required this.notesRepository,
    required this.repliesRepository,
    required this.photosRepository,
    required this.photoPicker,
    required this.syncService,
    required this.notifications,
    required this.activity,
    required this.localStore,
    required this.screenLock,
    required this.backgroundRunning,
    required this.releases,
    required this.buildNumber,
    required this.exportSaver,
    required this.photoSaver,
  });

  final AccessRepository accessRepository;
  final AuthSession authSession;
  final ParticipantsRepository participantsRepository;
  final NotesRepository notesRepository;
  final RepliesRepository repliesRepository;
  final PhotosRepository photosRepository;
  final PhotoPicker photoPicker;
  final SyncService syncService;
  final PostNotifications notifications;
  final ActivityChecker activity;
  final LocalStore localStore;
  final ScreenLock screenLock;
  final BackgroundRunning backgroundRunning;
  final ReleasesRepository releases;

  /// This APK's build number (the part after + in pubspec's version).
  final int buildNumber;
  final ExportSaver exportSaver;
  final PhotoSaver photoSaver;
}
