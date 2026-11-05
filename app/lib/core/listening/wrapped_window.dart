/// A year's Wrapped opens on 1 December, once there's nearly a whole year to show, and
/// stays open afterwards.
bool isWrappedOpen(int year, DateTime now) =>
    year < now.year || (year == now.year && now.month == DateTime.december);
