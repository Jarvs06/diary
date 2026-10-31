/// Small, dependency-free date formatting in the device's local time.
abstract final class Dates {
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _fullMonths = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  static const _fullWeekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  /// Diary dates are calendar days, not instants: no time-zone conversion.
  /// "Friday"
  static String weekday(DateTime d) => _fullWeekdays[d.weekday - 1];

  /// "October 31, 2026"
  static String longDay(DateTime d) => '${_fullMonths[d.month - 1]} ${d.day}, ${d.year}';

  /// "2026-10-31", as stored in Postgres `date` columns.
  static String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Parses "2026-10-31" as a local calendar day.
  static DateTime? parseIso(String? value) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(value ?? '');
    if (m == null) return null;
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  /// Feed dates: "Oct 18", or "Oct 18, 2025" for another year.
  static String short(DateTime d, {DateTime? now}) {
    final year = d.year == (now ?? DateTime.now()).year ? '' : ', ${d.year}';
    return '${_months[d.month - 1]} ${d.day}$year';
  }

  /// Today as a calendar day in the device's time zone.
  static DateTime today() => _dateOnly(DateTime.now());

  static DateTime dateOnly(DateTime t) => _dateOnly(t);

  /// "Oct 28, 2026"
  static String day(DateTime t) {
    final l = t.toLocal();
    return '${_months[l.month - 1]} ${l.day}, ${l.year}';
  }

  /// "3:41 PM"
  static String time(DateTime t) {
    final l = t.toLocal();
    final hour = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final minute = l.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${l.hour < 12 ? 'AM' : 'PM'}';
  }

  /// Reply timestamps: "3:41 PM" today, "Yesterday, 3:41 PM", else "Oct 28, 3:41 PM".
  static String stamp(DateTime t, {DateTime? now}) {
    final l = t.toLocal();
    final today = _dateOnly((now ?? DateTime.now()).toLocal());
    final d = _dateOnly(l);
    if (d == today) return time(l);
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday, ${time(l)}';
    final year = l.year == today.year ? '' : ', ${l.year}';
    return '${_months[l.month - 1]} ${l.day}$year, ${time(l)}';
  }

  /// Sidebar: "now", "5m", "3h", "Yesterday", "Mon", "Oct 28", "Oct 28, 2025".
  static String relative(DateTime t, {DateTime? now}) {
    final current = (now ?? DateTime.now()).toLocal();
    final l = t.toLocal();
    final diff = current.difference(l);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    final today = _dateOnly(current);
    final d = _dateOnly(l);
    if (d == today) return '${diff.inHours}h';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    if (today.difference(d).inDays < 7) return _weekdays[l.weekday - 1];
    if (l.year == current.year) return '${_months[l.month - 1]} ${l.day}';
    return day(l);
  }

  static DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);
}
