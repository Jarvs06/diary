import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../models/photo.dart';

typedef PhotoLoader = Future<Uint8List> Function(String storagePath);

/// A saved photo, downloaded through the signed-in session.
class RemotePhoto extends StatefulWidget {
  const RemotePhoto({
    super.key,
    required this.storagePath,
    required this.load,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });

  final String storagePath;
  final PhotoLoader load;
  final BoxFit fit;

  /// Decode at this width to save memory for thumbnails.
  final int? cacheWidth;

  @override
  State<RemotePhoto> createState() => _RemotePhotoState();
}

class _RemotePhotoState extends State<RemotePhoto> {
  late Future<Uint8List> _bytes = widget.load(widget.storagePath);

  @override
  void didUpdateWidget(RemotePhoto old) {
    super.didUpdateWidget(old);
    if (old.storagePath != widget.storagePath) _bytes = widget.load(widget.storagePath);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _PhotoPlaceholder(
            icon: Icons.refresh,
            label: 'Tap to retry',
            onTap: () => setState(() => _bytes = widget.load(widget.storagePath)),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) return const _PhotoPlaceholder(loading: true);
        return LocalPhoto(bytes: bytes, fit: widget.fit, cacheWidth: widget.cacheWidth);
      },
    );
  }
}

/// Image bytes already on the phone.
class LocalPhoto extends StatelessWidget {
  const LocalPhoto({super.key, required this.bytes, this.fit = BoxFit.cover, this.cacheWidth});

  final Uint8List bytes;
  final BoxFit fit;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      bytes,
      fit: fit,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const _PhotoPlaceholder(icon: Icons.broken_image_outlined),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder({this.icon, this.label, this.onTap, this.loading = false});

  final IconData? icon;
  final String? label;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: loading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: context.muted),
                    if (label != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(label!, style: context.text.bodySmall?.copyWith(color: context.muted)),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// An entry's photos, Threads-style: one photo spans the width; two or
/// three sit in a row that scrolls sideways. Tapping opens them full screen.
class PhotoCarousel extends StatelessWidget {
  const PhotoCarousel({
    super.key,
    required this.photos,
    required this.load,
    this.loadFull,
    this.height = 240,
    this.padding = EdgeInsets.zero,
  });

  final List<NotePhoto> photos;

  /// Loads what the tiles show (the lighter previews in the feed).
  final PhotoLoader load;

  /// Loads the full photos for the full-screen viewer; [load] if not given.
  final PhotoLoader? loadFull;
  final double height;

  /// Space before the first and after the last photo. The row itself spans
  /// the full width, so photos scroll right to the screen's edges (as on
  /// Threads) while the first one lines up with the text.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) return const SizedBox.shrink();
    Widget tile(int i, {int cacheWidth = 600}) => ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Semantics(
        button: true,
        label: 'Photo ${i + 1} of ${photos.length}',
        child: GestureDetector(
          key: ValueKey('photo-${photos[i].id}'),
          onTap: () => PhotoViewerScreen.open(context, photos: photos, load: loadFull ?? load, initial: i),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.hairline),
            ),
            child: RemotePhoto(storagePath: photos[i].storagePath, load: load, cacheWidth: cacheWidth),
          ),
        ),
      ),
    );

    if (photos.length == 1) {
      return Padding(
        padding: padding,
        child: SizedBox(height: height * 1.2, width: double.infinity, child: tile(0, cacheWidth: 1200)),
      );
    }
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) => SizedBox(width: height * 0.8, child: tile(i)),
      ),
    );
  }
}

/// Full-screen photos: swipe between them, pinch to zoom.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({super.key, required this.photos, required this.load, this.initial = 0});

  final List<NotePhoto> photos;
  final PhotoLoader load;
  final int initial;

  static Future<void> open(
    BuildContext context, {
    required List<NotePhoto> photos,
    required PhotoLoader load,
    int initial = 0,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PhotoViewerScreen(photos: photos, load: load, initial: initial),
    ),
  );

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.photos.length;
    return Scaffold(
      key: const Key('photo-viewer'),
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: count > 1
            ? Text('${_index + 1} of $count', style: const TextStyle(color: Colors.white, fontSize: 16))
            : null,
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: count,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => InteractiveViewer(
          maxScale: 4,
          child: Center(
            child: RemotePhoto(
              storagePath: widget.photos[i].storagePath,
              load: widget.load,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}

/// The composer's sideways row of picked photos, each with a remove button.
class EditorPhotoStrip extends StatelessWidget {
  const EditorPhotoStrip({
    super.key,
    required this.photos,
    required this.load,
    required this.onRemove,
    this.enabled = true,
  });

  final List<EditorPhoto> photos;
  final PhotoLoader load;
  final ValueChanged<String> onRemove;
  final bool enabled;

  static const _height = 180.0;

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: _height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) => _thumb(context, photos[i]),
      ),
    );
  }

  Widget _thumb(BuildContext context, EditorPhoto photo) {
    final picked = photo.picked;
    return SizedBox(
      key: ValueKey('editor-photo-${photo.id}'),
      width: _height * 0.8,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: picked != null
                ? LocalPhoto(bytes: picked.bytes, cacheWidth: 400)
                : RemotePhoto(storagePath: photo.saved!.storagePath, load: load, cacheWidth: 400),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: Material(
              color: Colors.black.withValues(alpha: 0.6),
              shape: const CircleBorder(),
              child: InkWell(
                key: ValueKey('remove-photo-${photo.id}'),
                customBorder: const CircleBorder(),
                onTap: enabled ? () => onRemove(photo.id) : null,
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(Icons.close, size: 16, color: Colors.white, semanticLabel: 'Remove photo'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
