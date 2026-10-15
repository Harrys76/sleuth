import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// Search-bar autocomplete + paginated photo gallery. Bad path fires
// requests with no debounce and pulls 1.1 MB pages; fixed path debounces
// to 300 ms and pulls 200 KB pages. NetworkMonitor flags
// `request_frequency` (>30 reqs/5 s window), `large_response` (>1 MiB),
// and `slow_request` warning + critical (>1000 ms / >3000 ms).

const _badDebounceMs = 0;
const _fixedDebounceMs = 300;
const _largePayloadBytes = 1100000;
const _smallPayloadBytes = 200000;

// Hard cap on requests per session. Aggressive typing in Bad mode
// otherwise hammers httpbin until the public endpoint rate-limits with
// 429s, after which the Sleuth `slow_request` / `large_response`
// demonstrations silently stop firing because failed responses no longer
// match the threshold shapes.
const _maxSessionRequests = 30;

// `/delay/4` rather than `/delay/3` so `slow_request.critical` (>3000 ms
// strict) clears even when the client-perceived duration loses a few
// hundred ms to RTT scheduling jitter.
const _slowEndpoint = 'https://httpbin.org/delay/4';
const _searchEndpoint = 'https://httpbin.org/get';
// httpbin caps `/bytes/N` at 102,400 bytes, so its pages could never cross
// the 1 MiB `large_response` line. Cloudflare's speed-test endpoint returns
// exactly N bytes as `application/octet-stream`, which the media skip
// leaves alone.
const _payloadEndpoint = 'https://speed.cloudflare.com/__down?bytes=';
const _largeEndpoint = '$_payloadEndpoint$_largePayloadBytes';
const _smallEndpoint = '$_payloadEndpoint$_smallPayloadBytes';

// One tile does not fill a phone screen, so the bad gallery's
// load-on-scroll could never start. After a page loads while the list
// still cannot scroll, the bad gallery loads the next page itself, at most
// this many times per fill.
const _maxAutoFillPages = 3;

class NetworkStressDemo extends StatefulWidget {
  const NetworkStressDemo({super.key, this.fetchBytes});

  /// Replaces the network fetch in tests. Resolves to the body length.
  @visibleForTesting
  final Future<int> Function(String url)? fetchBytes;

  @override
  State<NetworkStressDemo> createState() => _NetworkStressDemoState();
}

class _NetworkStressDemoState extends State<NetworkStressDemo>
    with SingleTickerProviderStateMixin {
  // TabController lives above the DemoScaffold ternary so a Bad/Fixed
  // toggle does not snap the user back to tab 0. The per-tab body
  // widgets own their own controllers + timers and dispose cleanly when
  // the ternary unmounts them.
  late final TabController _tabs;
  final ValueNotifier<int> _requestCount = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _requestCount.dispose();
    super.dispose();
  }

  void _handleToggle(bool isFixed) {
    // Fresh request budget per mode so the operator can demonstrate
    // the Fixed pattern after exhausting the cap on Bad. Per-mode
    // counters would preserve the running comparison, but resetting
    // is simpler and the cap is anti-rate-limit guard, not a metric.
    _requestCount.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Search + Gallery',
      description:
          'Bad: Search fires a request on every keystroke (no debounce). '
          'Gallery loads 1.1 MB pages on its own, filling the screen and '
          'then loading more as you scroll. '
          'NetworkMonitor flags `request_frequency` (more than 30 requests '
          'in 5 s) and `large_response` (more than 1 MiB). Toggle the Slow '
          'API switch to fire `slow_request.critical` (over 3000 ms).\n'
          'Fix: Search debounces to 300 ms, and the gallery loads small '
          '(200 KB) pages from a manual button.\n\n'
          'Type quickly in Search and scroll Gallery. Issue cards appear '
          'in the Sleuth overlay.\n\n'
          'Requires internet. The demo stops at $_maxSessionRequests '
          'requests per session to stay under the public endpoints\' rate '
          'limits.',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _requestCount,
            builder: (_, v, _) => MetricChip(
              label: 'Requests',
              value: '$v',
              unit: ' / $_maxSessionRequests',
            ),
          ),
        ],
      ),
      onToggle: _handleToggle,
      body: _TabbedBody(
        tabs: _tabs,
        bad: true,
        requestCount: _requestCount,
        fetchBytes: widget.fetchBytes ?? _fetchBytes,
      ),
      fixedBody: _TabbedBody(
        tabs: _tabs,
        bad: false,
        requestCount: _requestCount,
        fetchBytes: widget.fetchBytes ?? _fetchBytes,
      ),
    );
  }
}

class _TabbedBody extends StatelessWidget {
  const _TabbedBody({
    required this.tabs,
    required this.bad,
    required this.requestCount,
    required this.fetchBytes,
  });

  final TabController tabs;
  final bool bad;
  final ValueNotifier<int> requestCount;
  final Future<int> Function(String url) fetchBytes;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: tabs,
          tabs: const [
            Tab(icon: Icon(Icons.search), text: 'Search'),
            Tab(icon: Icon(Icons.photo_library), text: 'Gallery'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: tabs,
            children: [
              _SearchTab(
                bad: bad,
                requestCount: requestCount,
                fetchBytes: fetchBytes,
              ),
              _GalleryTab(
                bad: bad,
                requestCount: requestCount,
                fetchBytes: fetchBytes,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Search tab ───────────────────────────────────────────────────────

class _SearchTab extends StatefulWidget {
  const _SearchTab({
    required this.bad,
    required this.requestCount,
    required this.fetchBytes,
  });

  final bool bad;
  final ValueNotifier<int> requestCount;
  final Future<int> Function(String url) fetchBytes;

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final _controller = TextEditingController();
  Timer? _debounce;
  // Monotonic request token. Stale responses (older token than current)
  // are dropped at the UI layer. The detector still sees every issued
  // request — `request_frequency` is intentionally measuring the bad
  // pattern (unbounded keystroke fanout), not perceived debounce.
  int _seq = 0;
  bool _slowApi = false;
  bool _loading = false;
  String? _result;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      // Bump _seq so any in-flight request that returns after the
      // clear fails the seq guard and does not write back into the
      // empty UI.
      _seq++;
      setState(() {
        _result = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    final delay = Duration(
      milliseconds: widget.bad ? _badDebounceMs : _fixedDebounceMs,
    );
    _debounce = Timer(delay, () => _runSearch(value, ++_seq));
  }

  Future<void> _runSearch(String query, int seq) async {
    if (widget.requestCount.value >= _maxSessionRequests) {
      setState(() => _error = 'Session request cap reached. Restart screen.');
      return;
    }
    // Reserve the slot BEFORE the network round-trip so concurrent
    // keystrokes can't all see a counter under the cap and slip past
    // the gate while their fetches are in flight.
    widget.requestCount.value++;
    setState(() => _loading = true);
    // `replace(queryParameters: ...)` percent-encodes reserved chars
    // (`+`, `&`, `=`, `#`, unicode) per RFC 3986 — spaces become `+`,
    // others percent-escaped. httpbin.org parses both forms.
    final url = _slowApi
        ? _slowEndpoint
        : Uri.parse(
            _searchEndpoint,
          ).replace(queryParameters: {'q': query}).toString();
    try {
      final bytes = await widget.fetchBytes(url);
      if (!mounted || seq != _seq) return;
      setState(() {
        _result = '$bytes bytes returned for "$query"';
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = _friendlyError(e);
        _result = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            onChanged: _onChanged,
            onSubmitted: (v) => _runSearch(v, ++_seq),
            decoration: InputDecoration(
              hintText: 'Type to search...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                      },
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Slow API (3 s+ response)'),
            subtitle: const Text(
              'Routes search to /delay/4, which fires slow_request.critical',
              style: TextStyle(fontSize: 11),
            ),
            value: _slowApi,
            onChanged: (v) {
              // Invalidate any in-flight request so a stale response
              // from the prior endpoint mode does not write back under
              // the new mode.
              setState(() {
                _slowApi = v;
                _seq++;
              });
            },
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildResult(context)),
        ],
      ),
    );
  }

  Widget _buildResult(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Searching...'),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    if (_result != null) {
      return Center(child: Text(_result!));
    }
    return const Center(
      child: Text(
        'Type to search',
        style: TextStyle(fontSize: 14, color: Colors.grey),
      ),
    );
  }
}

// ── Gallery tab ──────────────────────────────────────────────────────

class _GalleryTab extends StatefulWidget {
  const _GalleryTab({
    required this.bad,
    required this.requestCount,
    required this.fetchBytes,
  });

  final bool bad;
  final ValueNotifier<int> requestCount;
  final Future<int> Function(String url) fetchBytes;

  @override
  State<_GalleryTab> createState() => _GalleryTabState();
}

class _GalleryTabState extends State<_GalleryTab> {
  final _scroll = ScrollController();
  final List<int> _pages = [];
  bool _loading = false;
  String? _error;
  int _autoFillPages = 0;

  @override
  void initState() {
    super.initState();
    if (widget.bad) {
      _scroll.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_loading) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 100) {
      _loadNextPage();
    }
  }

  Future<void> _loadNextPage() async {
    // Idempotent while a fetch is in flight — pull-to-refresh and the
    // scroll listener can both call this concurrently otherwise, and
    // both completions would append into the freshly-cleared list.
    if (_loading) return;
    if (widget.requestCount.value >= _maxSessionRequests) {
      setState(() => _error = 'Session request cap reached.');
      return;
    }
    // Reserve the slot before the await so concurrent callers respect
    // the cap.
    widget.requestCount.value++;
    setState(() {
      _loading = true;
      _error = null;
    });
    final url = widget.bad ? _largeEndpoint : _smallEndpoint;
    try {
      final bytes = await widget.fetchBytes(url);
      if (!mounted) return;
      setState(() {
        _pages.add(bytes);
        _loading = false;
      });
      if (widget.bad) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _fillScreen());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
        _loading = false;
      });
    }
  }

  // Loads the next page while the list is too short to scroll, so the
  // load-on-scroll listener gets a scrollable list to watch.
  void _fillScreen() {
    if (!mounted || !_scroll.hasClients || _loading || _error != null) return;
    if (_autoFillPages >= _maxAutoFillPages) return;
    if (_scroll.position.maxScrollExtent > 0) return;
    _autoFillPages++;
    _loadNextPage();
  }

  Future<void> _refresh() async {
    setState(() {
      _pages.clear();
      _error = null;
      _autoFillPages = 0;
    });
    await _loadNextPage();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scroll,
        // With its own controller the list is not primary, so a short list
        // on Android's clamping physics could not be pulled to refresh.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: _pages.length + 1,
        itemBuilder: (context, i) {
          if (i < _pages.length) {
            return _PhotoTile(index: i, bytes: _pages[i]);
          }
          if (_error != null) {
            return _ErrorTile(message: _error!, onRetry: _loadNextPage);
          }
          if (_loading) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (widget.bad) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _pages.isEmpty
                    ? 'Pull to load the first page. More pages load on '
                          'their own.'
                    : 'Scrolling near the bottom triggers auto-load.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: FilledButton.icon(
                onPressed: _loadNextPage,
                icon: const Icon(Icons.add),
                label: const Text('Load next page'),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.index, required this.bytes});

  final int index;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hue = (index * 37) % 360;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: DecoratedBox(
            decoration: BoxDecoration(
              color: HSVColor.fromAHSV(1, hue.toDouble(), 0.5, 0.7).toColor(),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const SizedBox(width: 56, height: 56),
          ),
          title: Text('Photo #${index + 1}'),
          subtitle: Text(
            '${(bytes / 1024).toStringAsFixed(1)} KiB',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

class _ErrorTile extends StatelessWidget {
  const _ErrorTile({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry page'),
          ),
        ],
      ),
    );
  }
}

// ── Shared helpers ───────────────────────────────────────────────────

// Drains the response body via `await for`. `drain()` and
// `listen(...).asFuture()` replace the response subscription's `onDone`
// callback, which Sleuth's `SleuthHttpOverrides` proxy relies on to emit
// `RequestRecord`s — without that emission the detector never observes
// the request.
//
// The 10 s timeout wraps the whole request including body drain. A
// server that returns headers and then stalls the body would otherwise
// hang the tab indefinitely because `request.close()` resolves on
// headers, not on completion.
Future<int> _fetchBytes(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    return await () async {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      var bytes = 0;
      await for (final chunk in response) {
        bytes += chunk.length;
      }
      return bytes;
    }().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        client.close(force: true);
        throw TimeoutException('Request timed out');
      },
    );
  } finally {
    client.close(force: true);
  }
}

String _friendlyError(Object e) {
  if (e is TimeoutException) return 'Request timed out (network slow?).';
  if (e is SocketException) return 'Network unavailable.';
  if (e is HttpException) return 'HTTP error: ${e.message}';
  return 'Request failed: $e';
}
