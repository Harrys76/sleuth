/// Storage for the overlay UI state (trigger position, card geometry,
/// hidden issues, severity filter).
///
/// Set one on `SleuthConfig.stateStore` to keep that state across app
/// restarts. Sleuth calls [read] once at startup and [write] after a
/// trailing 500 ms debounce once the state changes, with one write in
/// flight at a time; a change still waiting when Sleuth is disposed is
/// written then. Neither call blocks the UI: a [read] that throws or
/// returns unreadable data leaves the defaults in place, a [read] that
/// takes longer than 2 s leaves the defaults in place and turns writes
/// off for the session, and a failing [write] is logged once and
/// otherwise ignored. Release builds never call the store.
///
/// The package ships no persistent store, so it adds no storage
/// dependency. A store backed by a file, `shared_preferences` or
/// secure storage is a few lines:
///
/// ```dart
/// class PrefsStateStore implements SleuthStateStore {
///   @override
///   Future<String?> read() async =>
///       (await SharedPreferences.getInstance()).getString('sleuth_ui');
///
///   @override
///   Future<void> write(String json) async =>
///       (await SharedPreferences.getInstance()).setString('sleuth_ui', json);
/// }
/// ```
abstract class SleuthStateStore {
  /// Const constructor so implementations can be const.
  const SleuthStateStore();

  /// Returns the JSON last passed to [write], or null when nothing has
  /// been stored.
  Future<String?> read();

  /// Stores [json], replacing any previous value.
  Future<void> write(String json);
}

/// A [SleuthStateStore] that keeps the JSON in memory.
///
/// State lasts as long as the store object. Useful in tests and as a
/// reference implementation.
class InMemorySleuthStateStore implements SleuthStateStore {
  /// Creates a store, optionally holding [initial] as the stored JSON.
  InMemorySleuthStateStore([String? initial]) : _json = initial;

  String? _json;

  /// The stored JSON, or null when nothing has been written.
  String? get json => _json;

  /// Number of completed [write] calls.
  int get writeCount => _writeCount;
  int _writeCount = 0;

  @override
  Future<String?> read() async => _json;

  @override
  Future<void> write(String json) async {
    _json = json;
    _writeCount++;
  }
}
