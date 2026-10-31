import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/app_dependencies.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/ornaments.dart';
import '../../access/widgets/gentle_message.dart';
import '../../photos/models/photo.dart';
import '../../photos/services/photo_picker.dart';
import '../../photos/widgets/photo_widgets.dart';
import '../models/note.dart';
import '../services/note_editor_controller.dart';

/// Writing or editing a diary entry, Threads-style. Returns the saved [Note]
/// when popped after a successful save. Unsaved text and photos are never
/// discarded without asking.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({
    super.key,
    required this.dependencies,
    required this.me,
    this.existing,
    this.existingPhotos = const [],
    this.canPickDay = false,
  });

  final AppDependencies dependencies;

  /// Your display name, shown beside the text like a post.
  final String me;
  final Note? existing;
  final List<NotePhoto> existingPhotos;

  /// Shows the date button so the entry can be about another day. Only Jarvey
  /// (the 'author' account) has it; everyone else's entries are dated the day
  /// they're posted.
  final bool canPickDay;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  late final _editor = NoteEditorController(
    repository: widget.dependencies.notesRepository,
    photos: widget.dependencies.photosRepository,
    existing: widget.existing,
    existingPhotos: widget.existingPhotos,
  );
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? '');
  late String _savedTitle = _title.text;
  late String _savedBody = _body.text;
  late DateTime _date = widget.existing?.entryDate ?? Dates.today();
  late DateTime _savedDate = _date;

  bool get _dirty =>
      _title.text != _savedTitle || _body.text != _savedBody || _date != _savedDate || _editor.photosChanged;

  /// A new entry's text is kept on the phone as you type, so it survives the
  /// app being closed before you post or save a draft.
  static const _unsavedKey = 'compose_unsaved';
  bool get _keepsUnsaved => widget.existing == null;
  Timer? _keepTimer;

  @override
  void initState() {
    super.initState();
    if (_keepsUnsaved) {
      _restoreUnsaved();
      _title.addListener(_keepUnsavedSoon);
      _body.addListener(_keepUnsavedSoon);
    }
  }

  Future<void> _restoreUnsaved() async {
    final raw = await widget.dependencies.localStore.read(_unsavedKey);
    if (raw == null || !mounted || _title.text.isNotEmpty || _body.text.isNotEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _title.text = json['title'] as String? ?? '';
      _body.text = json['body'] as String? ?? '';
    } catch (_) {
      // Unreadable: start fresh.
    }
  }

  void _keepUnsavedSoon() {
    _keepTimer?.cancel();
    _keepTimer = Timer(const Duration(milliseconds: 600), _keepUnsaved);
  }

  Future<void> _keepUnsaved() {
    final empty = _title.text.trim().isEmpty && _body.text.trim().isEmpty;
    return widget.dependencies.localStore.write(
      _unsavedKey,
      empty ? null : jsonEncode({'title': _title.text, 'body': _body.text}),
    );
  }

  Future<void> _forgetUnsaved() async {
    _keepTimer?.cancel();
    if (_keepsUnsaved) await widget.dependencies.localStore.write(_unsavedKey, null);
  }

  @override
  void dispose() {
    _keepTimer?.cancel();
    _editor.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<bool> _save(NoteStatus status) async {
    FocusScope.of(context).unfocus();
    final saved = await _editor.save(
      title: _title.text,
      body: _body.text,
      status: status,
      entryDate: _entryDay,
    );
    if (saved == null || !mounted) return false;
    await _forgetUnsaved();
    if (!mounted) return false;
    _savedTitle = _title.text;
    _savedBody = _body.text;
    _savedDate = _date;
    Navigator.of(context).pop(saved);
    return true;
  }

  /// The day saved with the entry. For someone who can't pick it, it's the
  /// posting day: today, except when editing an entry that's already shared.
  DateTime get _entryDay {
    if (widget.canPickDay) return _date;
    final existing = widget.existing;
    return existing != null && existing.status == NoteStatus.published ? existing.entryDate : Dates.today();
  }

  Future<void> _pickDate() async {
    final today = Dates.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: _date.isAfter(today) ? _date : today,
      helpText: 'Which day is this entry about?',
    );
    if (picked != null && mounted) setState(() => _date = Dates.dateOnly(picked));
  }

  Future<void> _addPhotos(PhotoSource source) async {
    FocusScope.of(context).unfocus();
    try {
      final picked = await widget.dependencies.photoPicker.pick(source, limit: _editor.photosLeft);
      _editor.addPhotos(picked);
    } on AppFailure catch (f) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(f.message)));
    }
  }

  void _loadLatest() {
    final latest = _editor.takeLatest();
    if (latest == null) return;
    _title.text = latest.title;
    _body.text = latest.body;
    _savedTitle = latest.title;
    _savedBody = latest.body;
    setState(() => _date = _savedDate = latest.entryDate);
  }

  /// Cancel with changes: Threads-style sheet. New entries and drafts can be
  /// kept as a draft; edits to a shared entry can only be kept or dropped.
  Future<void> _confirmLeave() async {
    final shared = _editor.status == NoteStatus.published;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!shared)
              ListTile(
                key: const Key('save-draft-sheet-button'),
                title: const Text('Save draft', textAlign: TextAlign.center),
                onTap: () => Navigator.pop(context, 'draft'),
              ),
            ListTile(
              key: const Key('discard-changes-button'),
              title: Text(
                shared ? 'Discard changes' : 'Discard',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.colors.error, fontWeight: FontWeight.w600),
              ),
              onTap: () => Navigator.pop(context, 'discard'),
            ),
            ListTile(
              key: const Key('keep-writing-button'),
              title: const Text('Keep writing', textAlign: TextAlign.center),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'discard') {
      await _forgetUnsaved();
      if (mounted) Navigator.of(context).pop();
    } else if (choice == 'draft') {
      await _save(NoteStatus.draft);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_editor, _title, _body]),
      builder: (context, _) {
        final shared = _editor.status == NoteStatus.published;
        return PopScope(
          canPop: !_dirty && !_editor.isSaving,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && !_editor.isSaving) _confirmLeave();
          },
          child: Scaffold(
            // Shown in a sheet; let the sheet's colour show through.
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              leadingWidth: 88,
              leading: TextButton(
                key: const Key('compose-cancel'),
                onPressed: _editor.isSaving ? null : () => Navigator.of(context).maybePop(),
                child: const Text('Cancel'),
              ),
              title: Text(_editor.isNew ? 'New entry' : 'Edit entry'),
              shape: Border(bottom: BorderSide(color: context.hairline, width: 0.6)),
            ),
            body: SafeArea(
              top: false,
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [ReadableWidth(child: _composer(context))],
                    ),
                  ),
                  _banner(),
                  _bottomBar(shared),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _composer(BuildContext context) {
    final full = _editor.photosLeft <= 0;
    final enabled = !_editor.isSaving;
    final plain = InputDecoration(
      filled: false,
      isDense: true,
      counterText: '',
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      hintStyle: TextStyle(color: context.muted),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Avatar(name: widget.me),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      widget.me,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.titleSmall,
                    ),
                  ),
                  if (widget.canPickDay) ...[
                    const SizedBox(width: 4),
                    TextButton.icon(
                      key: const Key('entry-date-button'),
                      onPressed: enabled ? _pickDate : null,
                      style: TextButton.styleFrom(
                        foregroundColor: context.muted,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.calendar_today_outlined, size: 15),
                      label: Text('${Dates.weekday(_date).substring(0, 3)}, ${Dates.short(_date)}'),
                    ),
                  ],
                ],
              ),
              TextField(
                key: const Key('note-title-field'),
                controller: _title,
                enabled: enabled,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                style: context.text.titleSmall,
                decoration: plain.copyWith(hintText: 'Add a title (optional)'),
              ),
              TextField(
                key: const Key('note-body-field'),
                controller: _body,
                enabled: enabled,
                autofocus: _editor.isNew,
                minLines: 3,
                maxLines: null,
                maxLength: 100000,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                style: context.text.bodyLarge,
                decoration: plain.copyWith(hintText: "What's new?"),
              ),
              if (_editor.photos.isNotEmpty) ...[
                const SizedBox(height: 10),
                EditorPhotoStrip(
                  photos: _editor.photos,
                  load: widget.dependencies.photosRepository.loadPhoto,
                  enabled: enabled,
                  onRemove: _editor.removePhoto,
                ),
              ],
              const SizedBox(height: 6),
              // Shifted left so the icons line up with the text above.
              Transform.translate(
                offset: const Offset(-8, 0),
                child: Row(
                  children: [
                    _ToolButton(
                      key: const Key('add-photo-button'),
                      icon: Icons.photo_library_outlined,
                      tooltip: 'Add photos',
                      onPressed: enabled && !full ? () => _addPhotos(PhotoSource.gallery) : null,
                    ),
                    _ToolButton(
                      key: const Key('add-camera-button'),
                      icon: Icons.photo_camera_outlined,
                      tooltip: 'Take a photo',
                      onPressed: enabled && !full ? () => _addPhotos(PhotoSource.camera) : null,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${_editor.photos.length}/${NoteEditorController.maxPhotos}',
                      key: const Key('photo-count'),
                      style: context.text.bodyMedium?.copyWith(color: context.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _banner() {
    final failure = _editor.failure;
    if (failure == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: ReadableWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GentleMessage(
              key: const Key('editor-message'),
              message: failure is InvalidContent || failure is PhotosNotSaved
                  ? failure.message
                  : '${failure.message} Your text is still here.',
            ),
            if (_editor.conflict != null)
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    key: const Key('conflict-load-latest'),
                    onPressed: _loadLatest,
                    child: const Text('Load latest'),
                  ),
                  TextButton(
                    key: const Key('conflict-keep-mine'),
                    onPressed: _editor.keepMine,
                    child: const Text('Keep mine'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(bool shared) {
    final saving = _editor.isSaving;
    final blocked = saving || _editor.conflict != null;
    final pill = FilledButton.styleFrom(
      minimumSize: const Size(72, 40),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
    final spinner = SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: context.muted),
    );
    return ReadableWidth(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                shared ? 'Shared with you two' : 'Only you two can see posts',
                style: context.text.bodyMedium?.copyWith(color: context.muted),
              ),
            ),
            if (shared)
              FilledButton(
                key: const Key('save-changes-button'),
                style: pill,
                onPressed: blocked ? null : () => _save(NoteStatus.published),
                child: saving ? spinner : const Text('Save'),
              )
            else ...[
              TextButton(
                key: const Key('save-draft-button'),
                onPressed: blocked ? null : () => _save(NoteStatus.draft),
                child: const Text('Save draft'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                key: const Key('publish-button'),
                style: pill,
                onPressed: blocked ? null : () => _save(NoteStatus.published),
                child: saving ? spinner : const Text('Post'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 22, color: onPressed == null ? context.hairline : context.muted),
    );
  }
}
