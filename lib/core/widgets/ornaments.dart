import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Bundled images (see assets/icons/).
abstract final class AppAssets {
  static const logo = 'assets/icons/logo.png';
  static const navHome = 'assets/icons/nav_home.png';
  static const navPlus = 'assets/icons/nav_plus.png';
  static const navProfile = 'assets/icons/nav_profile.png';

  /// Profile photos, by display name (lower case).
  static const avatars = {'jarvey': 'assets/avatars/jarvey.jpg', 'janina': 'assets/avatars/janina.jpg'};
}

/// The app's mark: the two speech bubbles.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Image.asset(AppAssets.logo, width: size, height: size, filterQuality: FilterQuality.medium),
    );
  }
}

/// "[logo] Diary", the header wordmark (like Threads' "@threads").
class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key, this.size = 26});

  final double size;

  @override
  Widget build(BuildContext context) {
    final color = context.colors.onSurface;
    final style = TextStyle(fontFamily: AppFonts.logo, fontSize: size, height: 1.1);
    return Semantics(
      header: true,
      label: 'Our Diary',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppLogo(size: size * 1.15),
            SizedBox(width: size * 0.25),
            // Momo Signature has a single weight; an outline in the same
            // colour underneath thickens the strokes.
            Stack(
              children: [
                Text(
                  'Diary',
                  style: style.copyWith(
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = size * 0.06
                      ..strokeJoin = StrokeJoin.round
                      ..color = color,
                  ),
                ),
                Text('Diary', style: style.copyWith(color: color)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A one-colour PNG icon, tinted to match the theme (light and dark).
class AssetIcon extends StatelessWidget {
  const AssetIcon(this.asset, {super.key, this.size = 26, this.color});

  final String asset;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ImageIcon(AssetImage(asset), size: size, color: color ?? context.colors.onSurface);
  }
}

/// A person's profile photo in a circle, or their initial in their own colour
/// when there's no photo for that name.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 36});

  final String name;
  final double size;

  /// Soft tones that read on black. Each name always gets the same one, so
  /// two people with the same initial still look different.
  static const _tones = [
    Color(0xFF8AB4F8), // blue
    Color(0xFFF6AEA9), // rose
    Color(0xFFA8DAB5), // green
    Color(0xFFFDD663), // amber
    Color(0xFFC58AF9), // violet
    Color(0xFF78D9EC), // cyan
  ];

  static Color toneFor(String name) {
    var hash = 0;
    for (final unit in name.trim().toLowerCase().codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _tones[hash % _tones.length];
  }

  @override
  Widget build(BuildContext context) {
    final photo = AppAssets.avatars[name.trim().toLowerCase()];
    if (photo != null) {
      return ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          foregroundDecoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: context.hairline),
          ),
          child: ClipOval(
            child: Image.asset(
              photo,
              key: ValueKey('avatar-photo-${name.trim().toLowerCase()}'),
              fit: BoxFit.cover,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      );
    }
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final tone = toneFor(name);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.16),
          shape: BoxShape.circle,
          border: Border.all(color: tone.withValues(alpha: 0.35)),
        ),
        child: Text(
          initial,
          style: TextStyle(
            fontFamily: AppFonts.heading,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w600,
            fontVariations: AppFonts.weight(600),
            // Pastel tones are too faint as text on the light theme's cream.
            color: Theme.of(context).brightness == Brightness.light
                ? Color.lerp(tone, Colors.black, 0.45)
                : tone,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// Centers content in a column of at most [maxWidth]; the child always gets
/// the column's full width (so rows and dividers reach both edges).
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({super.key, required this.child, this.maxWidth = 620});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}

/// Icon, message and an optional action, centred. Used for empty and error states.
class CenteredMessage extends StatelessWidget {
  const CenteredMessage({super.key, required this.message, this.actionLabel, this.onAction, this.icon});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ReadableWidth(
          maxWidth: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 36, color: context.muted), const SizedBox(height: 16)],
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.text.bodyLarge?.copyWith(color: context.muted),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: 20),
                OutlinedButton(
                  key: const Key('center-action-button'),
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A quick fade used when moving between the passcode and the diary.
class FadeRoute<T> extends PageRouteBuilder<T> {
  FadeRoute({required WidgetBuilder builder})
    : super(
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (context, _, __) => builder(context),
        transitionsBuilder: (context, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      );
}
