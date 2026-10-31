import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/ornaments.dart';
import '../models/note.dart';
import '../services/notes_controller.dart';

/// A month at a glance: days with entries get a dot, and tapping a day lists
/// that day's entries from both of you.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.notes, required this.onOpen});

  final NotesController notes;
  final void Function(Note note) onOpen;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late DateTime _selected = Dates.today();

  static const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  Map<DateTime, List<Note>> get _byDay {
    final map = <DateTime, List<Note>>{};
    for (final n in widget.notes.feed) {
      map.putIfAbsent(n.entryDate, () => []).add(n);
    }
    return map;
  }

  void _shiftMonth(int by) => setState(() => _month = DateTime(_month.year, _month.month + by));

  @override
  Widget build(BuildContext context) {
    final byDay = _byDay;
    final dayNotes = byDay[_selected] ?? const <Note>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        shape: Border(bottom: BorderSide(color: context.hairline, width: 0.6)),
      ),
      body: ListView(
        key: const Key('calendar'),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ReadableWidth(
            maxWidth: 480,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('previous-month'),
                    tooltip: 'Previous month',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _shiftMonth(-1),
                  ),
                  Expanded(
                    child: Text(
                      '${Dates.longDay(_month).split(' ').first} ${_month.year}',
                      key: const Key('calendar-month'),
                      textAlign: TextAlign.center,
                      style: context.text.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const Key('next-month'),
                    tooltip: 'Next month',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _shiftMonth(1),
                  ),
                ],
              ),
            ),
          ),
          ReadableWidth(maxWidth: 480, child: _grid(byDay)),
          const SizedBox(height: 8),
          const Divider(),
          ReadableWidth(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(Dates.longDay(_selected), style: context.text.titleSmall),
            ),
          ),
          if (dayNotes.isEmpty)
            ReadableWidth(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Text(
                  'No posts on this day.',
                  style: context.text.bodyMedium?.copyWith(color: context.muted),
                ),
              ),
            )
          else
            for (final n in dayNotes)
              ReadableWidth(
                child: ListTile(
                  key: ValueKey('calendar-entry-${n.id}'),
                  leading: Avatar(name: widget.notes.nameOf(n.authorId)),
                  title: Text(
                    n.hasTitle ? n.title : n.body.split('\n').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(widget.notes.nameOf(n.authorId)),
                  onTap: () => widget.onOpen(n),
                ),
              ),
        ],
      ),
    );
  }

  Widget _grid(Map<DateTime, List<Note>> byDay) {
    final first = DateTime(_month.year, _month.month);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = first.weekday - 1; // Monday first
    final today = Dates.today();
    final cells = <Widget>[
      for (final w in _weekdays)
        Center(
          child: Text(w, style: context.text.bodySmall?.copyWith(color: context.muted)),
        ),
      for (var i = 0; i < leading; i++) const SizedBox.shrink(),
      for (var d = 1; d <= daysInMonth; d++) _day(DateTime(_month.year, _month.month, d), byDay, today),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: cells,
      ),
    );
  }

  Widget _day(DateTime day, Map<DateTime, List<Note>> byDay, DateTime today) {
    final selected = day == _selected;
    final hasEntries = byDay.containsKey(day);
    final colors = context.colors;
    return InkWell(
      key: ValueKey('calendar-day-${Dates.iso(day)}'),
      customBorder: const CircleBorder(),
      onTap: () => setState(() => _selected = day),
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? colors.onSurface : null,
          border: day == today && !selected ? Border.all(color: colors.outline) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              style: context.text.bodyMedium?.copyWith(color: selected ? colors.surface : colors.onSurface),
            ),
            const SizedBox(height: 2),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasEntries ? (selected ? colors.surface : colors.primary) : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
