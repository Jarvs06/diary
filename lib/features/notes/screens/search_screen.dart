import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/ornaments.dart';
import '../models/note.dart';
import '../services/notes_controller.dart';

/// Finds posts (and your drafts) by any word in their title or text.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.notes, required this.onOpen});

  final NotesController notes;
  final void Function(Note note) onOpen;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Every word must appear (in any order, ignoring case), newest day first.
  List<Note> _results(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    return widget.notes.everything.where((n) {
      final text = '${n.title}\n${n.body}'.toLowerCase();
      return words.every(text.contains);
    }).toList()..sort((a, b) => b.entryDate.compareTo(a.entryDate));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        shape: Border(bottom: BorderSide(color: context.hairline, width: 0.6)),
        title: TextField(
          key: const Key('search-field'),
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: context.text.bodyLarge,
          decoration: InputDecoration(
            hintText: 'Search posts',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            suffixIcon: ValueListenableBuilder(
              valueListenable: _query,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: _query.clear),
            ),
          ),
        ),
      ),
      body: ValueListenableBuilder(
        valueListenable: _query,
        builder: (context, value, _) {
          final query = value.text.trim();
          if (query.isEmpty) {
            return const CenteredMessage(icon: Icons.search_rounded, message: 'Find a post by any word in it.');
          }
          final results = _results(query);
          if (results.isEmpty) return CenteredMessage(message: 'No posts with “$query”.');
          return ListView.separated(
            key: const Key('search-results'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: results.length,
            separatorBuilder: (_, _) => const ReadableWidth(child: Divider()),
            itemBuilder: (context, i) => ReadableWidth(child: _result(results[i], query)),
          );
        },
      ),
    );
  }

  Widget _result(Note n, String query) {
    final name = widget.notes.nameOf(n.authorId);
    final muted = context.text.bodyMedium?.copyWith(color: context.muted);
    return ListTile(
      key: ValueKey('search-result-${n.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Avatar(name: name),
      title: Text(
        '$name  ·  ${Dates.short(n.entryDate)}${n.isDraft ? '  ·  Draft' : ''}',
        style: context.text.titleSmall,
      ),
      subtitle: Text.rich(
        _highlight(_snippet(n, query), query),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: muted,
      ),
      onTap: () => widget.onOpen(n),
    );
  }

  /// The text around the first matching word, so the match is visible.
  String _snippet(Note n, String query) {
    final text = (n.hasTitle ? '${n.title.trim()} — ${n.body}' : n.body).replaceAll(RegExp(r'\s+'), ' ').trim();
    final first = query.toLowerCase().split(RegExp(r'\s+')).first;
    final at = text.toLowerCase().indexOf(first);
    if (at <= 40) return text;
    final start = text.lastIndexOf(' ', at - 30);
    return '…${text.substring(start < 0 ? at - 30 : start + 1)}';
  }

  TextSpan _highlight(String text, String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map(RegExp.escape);
    final pattern = RegExp(words.join('|'), caseSensitive: false);
    final strong = TextStyle(color: context.colors.onSurface, fontWeight: FontWeight.w600);
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(0), style: strong));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(children: spans);
  }
}
